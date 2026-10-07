#region 依赖
@tool
extends Node2D

const SurfaceScript := preload("res://actor/canvas/src/canvas_surface.gd")

@onready var surface = $CanvasSurface
@onready var solid = $CanvasSolid
@onready var world = $".."
@onready var buttons = $Buttons
@onready var brush_panel = $BrushPanel
#endregion


#region 画布范围
## 画布宽高，单位 px；同时决定编辑器可见范围和墨水贴图分辨率。
@export var canvas_size := Vector2i(256, 256):
	set(value):
		canvas_size = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
		if is_node_ready():
			surface.canvas_size = canvas_size
			_place_brush_panel()


func _ready() -> void:
	surface.canvas_size = canvas_size
	_place_brush_panel()
	set_brush_size(int(brush_panel.get_node("PenSlider").value))
	surface.set_process_input(active)
	set_process_input(active)
	buttons.visible = active
	brush_panel.visible = active
	if not Engine.is_editor_hint():
		_bind_buttons()
#endregion


#region 功能接口
## 关掉后整块画布不响应任何输入、按钮也不显示；创造模式用它切换小画布/大地图。
@export var active := true:
	set(value):
		active = value
		if is_node_ready():
			surface.set_process_input(value)
			set_process_input(value)
			buttons.visible = value
			brush_panel.visible = value


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
	surface.tool = tool


## 直接按 px 设定笔触直径。
func set_brush_size(px: int) -> void:
	surface.brush_size = px
	brush_panel.get_node("PenValue").text = "%d px" % px


## 免墨水：创造模式里画图不该花瓶子里的墨（"重绘"也就不会再凭空生墨）。
func set_ink_free(on: bool) -> void:
	surface.ink_free = on
#endregion


#region 笔触面板
#面板贴在画布右侧，画布尺寸变了就跟着挪。
func _place_brush_panel() -> void:
	brush_panel.position = Vector2(canvas_size.x + 12, 0)
#endregion


#region 按钮
func _bind_buttons() -> void:
	buttons.get_node("Hand").pressed.connect(set_tool.bind(SurfaceScript.Tool.HAND))
	buttons.get_node("Brush").pressed.connect(set_tool.bind(SurfaceScript.Tool.BRUSH))
	buttons.get_node("Rect").pressed.connect(set_tool.bind(SurfaceScript.Tool.RECT))
	buttons.get_node("Circle").pressed.connect(set_tool.bind(SurfaceScript.Tool.CIRCLE))
	buttons.get_node("Eraser").pressed.connect(set_tool.bind(SurfaceScript.Tool.ERASER))
	buttons.get_node("Nail").pressed.connect(set_tool.bind(SurfaceScript.Tool.NAIL))
	buttons.get_node("Redraw").pressed.connect(clear_canvas)
	buttons.get_node("Generate").pressed.connect(generate)
	buttons.get_node("ReturnToCanvas").pressed.connect(return_to_canvas)
	brush_panel.get_node("PenSlider").value_changed.connect(_on_pen_slider_changed)


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
			KEY_E:
				generate()
	#保存/读取走输入动作，别和上面的裸键 match 串成一个分支。
	if dev_save_enabled and event.is_action_pressed("canvas_save"):
		surface.save_ink(capture_path)
		surface.save_png(baked_map_path)
	elif dev_save_enabled and event.is_action_pressed("canvas_load"):
		surface.load_ink(capture_path)
#endregion
