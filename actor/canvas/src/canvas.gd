#region 依赖
@tool
extends Node2D

const SurfaceScript := preload("res://actor/canvas/src/canvas_surface.gd")

@onready var surface = $CanvasSurface
@onready var solid = $CanvasSolid
@onready var world = $".."
@onready var player = get_node_or_null(player_path)
@onready var buttons = $WorkbenchUI/Buttons
@onready var tool_grid = $WorkbenchUI/Buttons/Grid
@onready var brush_panel = $WorkbenchUI/BrushPanel
@onready var workbench: Node2D = $WorkbenchUI
@onready var toggle_button: Button = $WorkbenchUI/Toggle
@onready var canvas_frame: TextureRect = $CanvasFrame
#endregion


#region 画布范围
## 画布宽高，单位 px；同时决定编辑器可见范围和墨水贴图分辨率。
@export var canvas_size := Vector2i(256, 256):
	set(value):
		canvas_size = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
		if is_node_ready():
			surface.canvas_size = canvas_size
			_place_controls()

## 用玩家身体到画布边缘的世界距离控制右侧工具栏。当前小人约 107 px 高；
## 进入距离稍短、离开距离约两个身位，形成迟滞，避免在边界反复闪烁。
@export var player_path: NodePath = ^"../Player"
@export_range(0.0, 1024.0, 1.0) var toolbar_show_distance := 190.0
@export_range(0.0, 1024.0, 1.0) var toolbar_hide_distance := 214.0


func _ready() -> void:
	process_physics_priority = 18       # 世界步进(10)之后、相机(20)之前：跟随时读到的才是这一帧的位姿
	_workbench_home = workbench.position
	surface.canvas_size = canvas_size
	_place_controls()
	set_brush_size(int(brush_panel.get_node("PenSlider").value))
	surface.set_process_input(active)
	set_process_input(active)
	set_physics_process(active and not Engine.is_editor_hint())
	_refresh_workbench_visibility()
	if not Engine.is_editor_hint():
		_bind_buttons()
		_apply_tool(surface.tool)
#endregion


#region 功能接口
## 关掉后整块画布不响应任何输入、按钮也不显示；创造模式用它切换小画布/大地图。
@export var active := true:
	set(value):
		active = value
		if is_node_ready():
			surface.set_process_input(value)
			set_process_input(value)
			set_physics_process(value and not Engine.is_editor_hint())
			_refresh_workbench_visibility()
			#谁激活谁说了算：手的状态跟着当前这块画布的当前工具。
			if value:
				_apply_tool(surface.tool)


## 清空画布墨水。
func clear_canvas() -> void:
	surface.clear()


## 墨水固化成实体（原 E 键）。
func generate() -> void:
	solid.solidify(surface, world)


## 画布范围内的实体重采样回墨水。
func return_to_canvas() -> void:
	solid.rasterize(surface, world)


## 切换画笔/橡皮擦/普通手。
func set_tool(tool: int) -> void:
	_temporary_eraser = false
	_apply_tool(tool)


## 非"手"工具 = 玩家的手失能：不跟鼠标、不能抓握、看不见。
## 胶水放画布这边（谁的工具谁负责），hand.gd 不认识画布。
@export var hand_path: NodePath = ^"Arm/Hand/HandControl"

func _sync_hand_enabled(tool: int) -> void:
	#只有当前活着的这块画布说了算：没激活的画布不许动玩家的手。
	if not active or player == null:
		return
	var hand := player.get_node_or_null(hand_path)
	if hand != null and hand.has_method("set_enabled"):
		hand.set_enabled(tool == SurfaceScript.Tool.HAND)


## 直接按 px 设定笔触直径。
func set_brush_size(px: int) -> void:
	surface.brush_size = px
	brush_panel.get_node("PenSlider").tooltip_text = "笔触大小：%d px" % px


## 免墨水：创造模式里画图不该花瓶子里的墨（"重绘"也就不会再凭空生墨）。
func set_ink_free(on: bool) -> void:
	surface.ink_free = on
#endregion


#region 工作台布局
#画布和工具栏都是世界物件，不绑玩家；HUD 才留在 CanvasLayer 跟随屏幕。
## 跟随时工具栏原点相对玩家质心的偏移（画布局部坐标）。
## 工具栏本体在 WorkbenchUI 里是往左下方铺的（x -222..-86、y 56..428），
## 所以这里给的是"让那一摞按钮落在玩家右手边"的量。
@export var follow_offset := Vector2(246, -106)

var _workbench_nearby := true
var _workbench_hidden := false
var _workbench_home := Vector2.ZERO
var _follow_player := false


func _place_controls() -> void:
	canvas_frame.position = Vector2(-14, -14)
	canvas_frame.size = Vector2(canvas_size) + Vector2(28, 28)


## 把工具栏挂到玩家身上（创造模式全图飞行时够得着）；关掉就回到场景里摆的位置。
func set_follow_player(on: bool) -> void:
	_follow_player = on
	if on:
		_update_follow_position()
	else:
		workbench.position = _workbench_home
	_refresh_workbench_visibility()


## 工具栏贴到玩家身体旁边。
func _update_follow_position() -> void:
	if player == null:
		return
	var body = player.get("body")
	var center: Vector2 = body.com_world() if body != null else player.global_position
	workbench.position = to_local(center + follow_offset)


func _physics_process(_delta: float) -> void:
	if _follow_player:
		_update_follow_position()
	_refresh_workbench_visibility()


func _refresh_workbench_visibility() -> void:
	if not active:
		_set_workbench_visible(false)
		return
	# 单独预览 Canvas 场景时没有玩家，工具栏保持可见，便于编辑与测试；
	# 跟着人走时也不存在"离画布太远"这回事。
	if player == null or _follow_player:
		_set_workbench_visible(true)
		return
	var distance := _distance_from_player_to_canvas()
	if _workbench_nearby:
		_workbench_nearby = distance <= maxf(toolbar_hide_distance, toolbar_show_distance)
	else:
		_workbench_nearby = distance <= minf(toolbar_show_distance, toolbar_hide_distance)
	_set_workbench_visible(_workbench_nearby)


func _set_workbench_visible(nearby: bool) -> void:
	#⚠️ 隐藏按钮自己不受"手动隐藏"控制 —— 不然藏起来就再也点不回来了。
	toggle_button.visible = active and nearby
	buttons.visible = active and nearby and not _workbench_hidden
	brush_panel.visible = active and nearby and not _workbench_hidden


func _distance_from_player_to_canvas() -> float:
	var canvas_rect := Rect2(surface.global_position, Vector2(surface.canvas_size))
	var player_rect := Rect2(player.global_position, Vector2.ONE)
	var player_body = player.get("body")
	if player_body != null:
		player_rect = player_body.aabb
	var gap_x := maxf(maxf(canvas_rect.position.x - player_rect.end.x,
		player_rect.position.x - canvas_rect.end.x), 0.0)
	var gap_y := maxf(maxf(canvas_rect.position.y - player_rect.end.y,
		player_rect.position.y - canvas_rect.end.y), 0.0)
	return Vector2(gap_x, gap_y).length()
#endregion


#region 按钮
func _bind_buttons() -> void:
	tool_grid.get_node("Hand").pressed.connect(set_tool.bind(SurfaceScript.Tool.HAND))
	tool_grid.get_node("Brush").pressed.connect(set_tool.bind(SurfaceScript.Tool.BRUSH))
	tool_grid.get_node("Eraser").pressed.connect(set_tool.bind(SurfaceScript.Tool.ERASER))
	tool_grid.get_node("Shape").pressed.connect(_select_shape_tool)
	tool_grid.get_node("Nail").pressed.connect(set_tool.bind(SurfaceScript.Tool.NAIL))
	tool_grid.get_node("Bucket").pressed.connect(set_tool.bind(SurfaceScript.Tool.BUCKET))
	tool_grid.get_node("Redraw").pressed.connect(clear_canvas)
	tool_grid.get_node("Generate").pressed.connect(generate)
	tool_grid.get_node("ReturnToCanvas").pressed.connect(return_to_canvas)
	toggle_button.pressed.connect(_toggle_workbench)
	brush_panel.get_node("PenSlider").value_changed.connect(_on_pen_slider_changed)


## 隐藏 / 显示工具栏本体。按钮自己一直露着，好点回来。
func _toggle_workbench() -> void:
	_workbench_hidden = not _workbench_hidden
	toggle_button.text = "显示" if _workbench_hidden else "隐藏"
	_refresh_workbench_visibility()


var _shape_tool: int = SurfaceScript.Tool.RECT
var _temporary_eraser := false


func _select_shape_tool() -> void:
	if surface.tool == SurfaceScript.Tool.RECT:
		_shape_tool = SurfaceScript.Tool.CIRCLE
	elif surface.tool == SurfaceScript.Tool.CIRCLE:
		_shape_tool = SurfaceScript.Tool.RECT
	_apply_tool(_shape_tool)
	var shape_name := "圆形" if _shape_tool == SurfaceScript.Tool.CIRCLE else "矩形"
	tool_grid.get_node("Shape").tooltip_text = "自选形状：%s（5/6）\n再次点击切换形状" % shape_name


func _apply_tool(tool: int) -> void:
	surface.tool = tool
	tool_grid.get_node("Hand").set_pressed_no_signal(tool == SurfaceScript.Tool.HAND)
	tool_grid.get_node("Brush").set_pressed_no_signal(tool == SurfaceScript.Tool.BRUSH)
	tool_grid.get_node("Eraser").set_pressed_no_signal(tool == SurfaceScript.Tool.ERASER)
	tool_grid.get_node("Shape").set_pressed_no_signal(
		tool == SurfaceScript.Tool.RECT or tool == SurfaceScript.Tool.CIRCLE
	)
	tool_grid.get_node("Nail").set_pressed_no_signal(tool == SurfaceScript.Tool.NAIL)
	tool_grid.get_node("Bucket").set_pressed_no_signal(tool == SurfaceScript.Tool.BUCKET)
	_sync_hand_enabled(tool)


#滑块带格子（step = 2），值域就是奇数直径 1..17。
func _on_pen_slider_changed(value: float) -> void:
	set_brush_size(int(round(value)))
#endregion


#region 复现文件与调试输入
## 开发复现文件留在 test，保存内容仍是未固化墨水。
@export var capture_path: String = "res://test/canvas_capture.tres"
## 大地图预览图；保存后可由 BakedMap 在编辑器中加载和拖动。
@export_file("*.png") var baked_map_path: String = "res://map/asset/baked_map.png"
## 开发用的 F5/F9 存读；创造模式接管 F5 时会被关掉，避免两套保存同时跑。
var dev_save_enabled := true


func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	#绘图工具下，右键只充当临时橡皮：按住切换，松开恢复，不改变长期工具选择。
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed and not _temporary_eraser and surface.tool == SurfaceScript.Tool.BRUSH:
			_temporary_eraser = true
			_apply_tool(SurfaceScript.Tool.ERASER)
		elif not event.pressed and _temporary_eraser:
			_temporary_eraser = false
			_apply_tool(SurfaceScript.Tool.BRUSH)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				set_tool(SurfaceScript.Tool.HAND)
			KEY_2:
				set_tool(SurfaceScript.Tool.BRUSH)
			KEY_3:
				set_tool(SurfaceScript.Tool.ERASER)
			KEY_4:
				set_tool(SurfaceScript.Tool.NAIL)
			KEY_5:
				set_tool(SurfaceScript.Tool.RECT)
			KEY_6:
				set_tool(SurfaceScript.Tool.CIRCLE)
			KEY_7:
				set_tool(SurfaceScript.Tool.BUCKET)
			KEY_E:
				generate()
	#保存/读取走输入动作，别和上面的裸键 match 串成一个分支。
	if dev_save_enabled and event.is_action_pressed("canvas_save"):
		surface.save_ink(capture_path)
		surface.save_png(baked_map_path)
	elif dev_save_enabled and event.is_action_pressed("canvas_load"):
		surface.load_ink(capture_path)
#endregion
