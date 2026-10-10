#region 依赖
@tool
extends Node2D

signal tool_changed(tool: int)
signal map_changed
signal editor_control_requested

const SurfaceScript := preload("res://actor/canvas/src/canvas_surface.gd")
const NailScript := preload("res://actor/nail/src/nail.gd")
const InkPalette := preload("res://Ink/src/ink_palette.gd")
const EditorTheme := preload("res://ui/theme/asset/ink_attack_theme.tres")
const ExpandCanvasIconSource := preload("res://actor/canvas/asset/expand_canvas.png")
const EditorControlIconSource := preload("res://actor/canvas/asset/editor_control.png")
const EXPAND_CANVAS_ICON_REGION := Rect2(228, 128, 116, 116)
const EDITOR_CONTROL_ICON_REGION := Rect2(340, 340, 116, 116)
const PLAY_TOOL_COLUMNS := 2
const EDITOR_TOOL_COLUMNS := 2
const PLAY_TOOL_BUTTON_WIDTH := 32.0
const PLAY_TOOL_BUTTON_HEIGHT := 43.0
const PLAY_TOOL_BUTTON_H_GAP := 10.0
const PLAY_TOOL_BUTTON_V_GAP := 4.0
const PLAY_HAND_BUTTON_SIZE := 52.0
const EDITOR_TOOL_BUTTON_WIDTH := 44.0
const EDITOR_TOOL_BUTTON_HEIGHT := 60.0
const EDITOR_TOOL_BUTTON_H_GAP := 16.0
const EDITOR_TOOL_BUTTON_V_GAP := 10.0
const EDITOR_HAND_BUTTON_SIZE := 72.0

@onready var surface = $CanvasSurface
@onready var solid = $CanvasSolid
@onready var world = $".."
@onready var player = get_node_or_null(player_path)
@onready var buttons = $WorkbenchUI/Buttons
@onready var tool_grid = $WorkbenchUI/Buttons/Grid
@onready var brush_panel = $WorkbenchUI/BrushPanel
@onready var resize_panel = $WorkbenchUI/ResizePanel
@onready var workbench: Node2D = $WorkbenchUI
@onready var toggle_button: Button = $WorkbenchUI/Toggle
@onready var hand_button: Button = $WorkbenchUI/Buttons/Grid/Hand
@onready var canvas_frame: TextureRect = $CanvasFrame

var _expand_canvas_window: Window
var _expand_inputs: Dictionary = {}
var _expand_size_preview: Label
#endregion


#region 画布范围
## 画布宽高，单位 px；同时决定编辑器可见范围和墨水贴图分辨率。
@export var canvas_size := Vector2i(256, 256):
	set(value):
		canvas_size = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
		if is_node_ready():
			if not _syncing_preserved_resize:
				surface.canvas_size = canvas_size
			_place_controls()

## 地图编辑器每次向一个方向增加的逻辑像素数。
@export_range(16, 2048, 16) var canvas_expand_step := 256

## 用玩家身体到画布边缘的世界距离控制右侧工具栏。当前小人约 107 px 高；
## 进入距离稍短、离开距离约两个身位，形成迟滞，避免在边界反复闪烁。
@export var player_path: NodePath = ^"../Player"
@export_range(0.0, 1024.0, 1.0) var toolbar_show_distance := 190.0
@export_range(0.0, 1024.0, 1.0) var toolbar_hide_distance := 214.0


func _ready() -> void:
	process_physics_priority = 18       # 世界步进(10)之后、相机(20)之前：跟随时读到的才是这一帧的位姿
	_workbench_home = workbench.position
	_workbench_home_transform = workbench.transform
	surface.canvas_size = canvas_size
	_place_controls()
	_prepare_workbench_structure()
	tool_grid.get_node("Nail").visible = false
	tool_grid.get_node("ExpandCanvas").visible = false
	_apply_workbench_column_layout()
	set_brush_size(int(brush_panel.get_node("PenSlider").value))
	surface.set_process_input(active)
	set_process_input(active)
	set_physics_process(active and not Engine.is_editor_hint())
	set_process(false)
	_refresh_workbench_visibility()
	if not Engine.is_editor_hint():
		_build_side_panel()
		_build_shape_popup()
		_bind_buttons()
		surface.selection_delete_requested.connect(_delete_selection)
		# 进入正常游戏时始终从“手”开始，不能继承地图保存时的画笔状态。
		_apply_tool(SurfaceScript.Tool.HAND if active else surface.tool)
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
			set_process(value and _screen_fixed and not Engine.is_editor_hint())
			_refresh_workbench_visibility()
			#谁激活谁说了算：手的状态跟着当前这块画布的当前工具。
			if value:
				_apply_tool(surface.tool)


## 清空画布墨水。
func clear_canvas() -> void:
	surface.clear()


## 墨水固化成实体（原 E 键）。
func generate() -> void:
	solid.solidify(surface, world, _map_editor_mode)
	var yellow = surface.yellow_rule()
	if yellow != null:
		yellow.solidify(surface)
	_apply_nail_visuals(_nails_visible if _map_editor_mode else true)


## 画布范围内的实体重采样回墨水。
func return_to_canvas() -> void:
	var yellow = surface.yellow_rule()
	if yellow != null:
		yellow.reclaim(surface)
	solid.rasterize(surface, world)


## 地图编辑模式清理已经整体掉出画布的固化墨水。
## 原始 InkItem 由节点组识别；破坏产生的碎片没有节点，用 null 占位识别。
## 静态地形、生物以及仍有任意部分碰到画布的实体都保留。
func clear_solidified_bodies_outside_canvas() -> int:
	if world == null or world.get("world") == null:
		return 0
	var physics = world.get("world")
	world.realign_body_nodes()
	var nodes_by_body: Dictionary = {}
	for index in mini(world._body_nodes.size(), physics.bodies.size()):
		var node = world._body_nodes[index]
		if is_instance_valid(node):
			nodes_by_body[physics.bodies[index]] = node
	var canvas_rect := Rect2(surface.global_position, Vector2(surface.canvas_size))
	var removed: Array = []
	for body in physics.bodies:
		if body == null or body.is_static or body.tags.has("living"):
			continue
		var node = nodes_by_body.get(body)
		var is_solidified_ink: bool = node == null or node.is_in_group("ink_item")
		if is_solidified_ink and not body.aabb.intersects(canvas_rect):
			removed.append(body)
	if removed.is_empty():
		return 0
	for body in removed:
		physics.remove_body(body)
		var node = nodes_by_body.get(body)
		if is_instance_valid(node):
			node.queue_free()
		for child in world.get_children():
			if child is NailScript and child.get("body") == body:
				child.queue_free()
	world.sync_world_bodies()
	return removed.size()


## 未固化墨水与已固化实体一起框删，并合并成一个画布撤销步骤。
func _delete_selection(rect: Rect2i) -> void:
	# 固化实体必须先写回可编辑画布，再建立撤销快照。旧顺序在框内只有
	# 固化像素时会得到“空 -> 空”的快照，既不触发自动保存，也无法撤销。
	var removed: int = solid.rasterize_rect(surface, world, rect)
	if removed > 0:
		solid.sync_serializable_bodies(world)
	surface._begin_undo_step()
	surface.erase_rect(rect)
	surface._commit_undo_step()
	_apply_nail_visuals(_nails_visible if _map_editor_mode else true)


## 保底 PNG：把世界里所有实心像素采样进画布 → 存一张透明 PNG → 把画布还原成空的。
## 不删刚体（`keep_bodies`）——存图不能顺手把关卡拆了。
## ⚠️ 固化过的关卡画布是空的，所以图必须从世界采样，直接存画布只会得到一张空图。
## ⚠️ 采样是临时的、存完就清画布：调用前画布上的墨必须已经固化过（F5 里就是先 generate 再 bake）。
func bake_png(path: String) -> Error:
	solid.rasterize(surface, world, true)
	var error: Error = surface.save_png(path)
	surface.clear(false)          # 采样是临时的：存完把画布还给"空的"，别让存档里多一层图
	return error


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


## 从地图编辑器返回游戏时，强制恢复手工具并重新启用抓取。
func activate_hand_tool() -> void:
	set_tool(SurfaceScript.Tool.HAND)


## 直接按 px 设定笔触直径。
func set_brush_size(px: int) -> void:
	surface.brush_size = px
	brush_panel.get_node("PenSlider").tooltip_text = "笔触大小：%d px" % px
	if _side_brush_slider != null:
		_side_brush_slider.tooltip_text = "笔触大小：%d px" % px


## 免墨水：创造模式里画图不该花瓶子里的墨（"重绘"也就不会再凭空生墨）。
func set_ink_free(on: bool) -> void:
	surface.ink_free = on


## 在指定方向扩展画布，保留已有像素和钉子；向左/上扩展时同步移动节点，
## 因此旧内容在世界中的位置保持不变。
func expand_canvas(direction: Vector2i, amount := -1) -> bool:
	if direction not in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		push_error("Canvas: 扩展方向必须是上、下、左、右")
		return false
	var step := canvas_expand_step if amount <= 0 else amount
	step = maxi(step, 1)
	match direction:
		Vector2i.LEFT:
			return expand_canvas_sides(step, 0, 0, 0)
		Vector2i.RIGHT:
			return expand_canvas_sides(0, step, 0, 0)
		Vector2i.UP:
			return expand_canvas_sides(0, 0, step, 0)
		Vector2i.DOWN:
			return expand_canvas_sides(0, 0, 0, step)
	return false


## 一次扩展四侧。左、上扩展会平移旧内容与画布节点，确保旧内容的世界坐标不变。
func expand_canvas_sides(left: int, right: int, top: int, bottom: int) -> bool:
	left = maxi(left, 0)
	right = maxi(right, 0)
	top = maxi(top, 0)
	bottom = maxi(bottom, 0)
	if left + right + top + bottom == 0:
		return false
	var content_offset := Vector2i(left, top)
	var new_size := canvas_size + Vector2i(left + right, top + bottom)
	if not surface.resize_preserving_content(new_size, content_offset):
		return false
	_syncing_preserved_resize = true
	canvas_size = new_size
	_syncing_preserved_resize = false
	position -= Vector2(content_offset)
	map_changed.emit()
	return true


func expand_left() -> void:
	expand_canvas(Vector2i.LEFT)


func expand_right() -> void:
	expand_canvas(Vector2i.RIGHT)


func expand_up() -> void:
	expand_canvas(Vector2i.UP)


func expand_down() -> void:
	expand_canvas(Vector2i.DOWN)
#endregion


#region 工作台布局
#画布和工具栏都是世界物件，不绑玩家；HUD 才留在 CanvasLayer 跟随屏幕。
## 跟随时工具栏原点相对玩家质心的偏移（画布局部坐标）。
## 工具栏本体在 WorkbenchUI 里是往左下方铺的（x -222..-86、y 56..428），
## 所以这里给的是"让那一摞按钮落在玩家右手边"的量。
@export var follow_offset := Vector2(246, -106)
## 固定工具栏时，WorkbenchUI 原点所在的视口逻辑坐标。
## 控件自身向左偏移 222 px、向下偏移 56 px，所以默认值会让可见区域从 (16, 16) 开始。
@export var screen_toolbar_origin := Vector2(238, -40)

var _workbench_nearby := true
var _workbench_hidden := false
var _workbench_home := Vector2.ZERO
var _workbench_home_transform := Transform2D.IDENTITY
var _follow_player := false
var _screen_fixed := false
var _map_editor_mode := false
var _syncing_preserved_resize := false
var _nails_visible := true


func _place_controls() -> void:
	canvas_frame.position = Vector2(-14, -14)
	canvas_frame.size = Vector2(canvas_size) + Vector2(28, 28)
	_place_side_panel()


#region 右侧面板：墨水选择 + 笔刷粗细
## 右侧面板离画布右边缘多远。
@export var side_panel_gap := 14.0
## 笔刷粗细条最大直径（步长 1，任意直径都铺得准，见 canvas_surface）。
@export_range(1, 65, 1) var brush_size_max := 33

var _side_panel: Control = null
var _ink_buttons: Array[Button] = []
var _side_brush_slider: VSlider = null


#右侧面板由色表生成：加一种墨水这里不用改。
func _build_side_panel() -> void:
	var panel := VBoxContainer.new()
	panel.name = "SidePanel"
	panel.z_index = 100
	panel.theme = buttons.theme
	panel.add_theme_constant_override("separation", 4)
	add_child(panel)
	_side_panel = panel
	var title := Label.new()
	title.text = "色盘"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 12)
	panel.add_child(title)
	var controls := HBoxContainer.new()
	controls.name = "Controls"
	controls.add_theme_constant_override("separation", 8)
	panel.add_child(controls)
	var colors := VBoxContainer.new()
	colors.name = "Colors"
	colors.add_theme_constant_override("separation", 10)
	controls.add_child(colors)
	for i in InkPalette.ink_count():
		var color: Color = InkPalette.color_at(i)
		var style := StyleBoxFlat.new()
		style.bg_color = color
		style.corner_radius_top_left = 17
		style.corner_radius_top_right = 17
		style.corner_radius_bottom_left = 17
		style.corner_radius_bottom_right = 17
		style.border_width_left = 1
		style.border_width_top = 1
		style.border_width_right = 1
		style.border_width_bottom = 1
		style.border_color = Color(0.035, 0.031, 0.024, 1.0)
		var button := Button.new()
		button.name = "Ink%dButton" % i
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(34.0, 34.0)
		button.tooltip_text = "%s（材质 %d）" % [
			InkPalette.ink_name(i), InkPalette.material_id_of(InkPalette.ink_at(i))]
		button.add_theme_color_override(
			"font_color", Color.WHITE if color.get_luminance() < 0.5 else Color.BLACK)
		button.add_theme_stylebox_override("normal", style)
		button.add_theme_stylebox_override("hover", style)
		button.add_theme_stylebox_override("pressed", style)
		button.add_theme_stylebox_override("focus", style)
		button.pressed.connect(select_ink.bind(i))
		colors.add_child(button)
		_ink_buttons.append(button)
	var source_pen := brush_panel.get_node("PenSlider") as HSlider
	source_pen.min_value = 1.0
	source_pen.max_value = float(brush_size_max)
	source_pen.step = 1.0
	source_pen.tick_count = brush_size_max
	source_pen.value = clampf(source_pen.value, 1.0, float(brush_size_max))
	_side_brush_slider = VSlider.new()
	_side_brush_slider.name = "BrushSizeSlider"
	_side_brush_slider.custom_minimum_size = Vector2(18.0, 166.0)
	_side_brush_slider.min_value = source_pen.min_value
	_side_brush_slider.max_value = source_pen.max_value
	_side_brush_slider.step = source_pen.step
	_side_brush_slider.tick_count = source_pen.tick_count
	_side_brush_slider.value = source_pen.value
	_side_brush_slider.tooltip_text = source_pen.tooltip_text
	_side_brush_slider.theme = buttons.theme
	_side_brush_slider.value_changed.connect(_on_pen_slider_changed)
	controls.add_child(_side_brush_slider)
	set_brush_size(int(round(_side_brush_slider.value)))
	select_ink(surface.selected_ink)
	_place_side_panel()
	_refresh_workbench_visibility()


## 选中一种墨水（色表下标）；画笔用它，账也记到它头上。
func select_ink(index: int) -> void:
	if index < 0 or index >= InkPalette.ink_count():
		return
	surface.selected_ink = index
	for i in _ink_buttons.size():
		_ink_buttons[i].set_pressed_no_signal(i == index)


func _place_side_panel() -> void:
	if _side_panel == null:
		return
	if _follow_player:
		#创造模式工具栏跟着人飞：面板贴在工具栏右边。
		_side_panel.position = workbench.position + Vector2(160.0, 56.0)
	else:
		_side_panel.position = Vector2(float(canvas_size.x) + side_panel_gap, -22.0)
#endregion


## 把工具栏挂到玩家身上（创造模式全图飞行时够得着）；关掉就回到场景里摆的位置。
func set_follow_player(on: bool) -> void:
	if on:
		set_screen_fixed(false)
	_follow_player = on
	if on:
		_update_follow_position()
	else:
		workbench.position = _workbench_home
	_refresh_workbench_visibility()


## 工具栏固定在视口左侧，不受相机移动、旋转或缩放影响。
func set_screen_fixed(on: bool) -> void:
	_screen_fixed = on
	if on:
		_follow_player = false
		_update_screen_fixed_position()
	else:
		workbench.transform = _workbench_home_transform
	set_process(on and active and not Engine.is_editor_hint())
	_refresh_workbench_visibility()


## 两种模式都显示完整工具栏；地图编辑模式额外显示钉子与扩展画布。
func set_map_editor_mode(on: bool) -> void:
	_map_editor_mode = on
	tool_grid.get_node("Brush").visible = true
	tool_grid.get_node("Eraser").visible = true
	tool_grid.get_node("Shape").visible = true
	tool_grid.get_node("Bucket").visible = true
	tool_grid.get_node("Nail").visible = on
	tool_grid.get_node("ExpandCanvas").visible = on
	hand_button.visible = true
	hand_button.tooltip_text = (
		"操纵（F）\n移动出生点、画布、复活点、文本、对话触发点和怪物；滚轮缩放怪物或文本"
		if on else "操纵（F）\n从绘图工具切换回墨水小瓶的手"
	)
	_apply_workbench_column_layout()
	if on and _expand_canvas_window == null:
		_build_expand_canvas_window()
	if not on and _expand_canvas_window != null:
		_expand_canvas_window.hide()
	var player_visibility_button: Button = resize_panel.get_node("Grid/PlayerVisibility")
	player_visibility_button.set_pressed_no_signal(player != null and player.visible)
	_update_player_visibility_tooltip(player_visibility_button.button_pressed)
	var nail_visibility_button: Button = resize_panel.get_node("Grid/NailVisibility")
	nail_visibility_button.set_pressed_no_signal(_nails_visible)
	_update_nail_visibility_tooltip(_nails_visible)
	_apply_nail_visuals(_nails_visible if on else true)
	set_screen_fixed(on)
	_refresh_workbench_visibility()


func _prepare_workbench_structure() -> void:
	var order := [
		"Brush", "Eraser", "Shape", "Bucket", "Redraw", "SelectDelete",
		"Generate", "ReturnToCanvas", "Nail", "ExpandCanvas",
	]
	var captions := {
		"Brush": "画笔", "Eraser": "橡皮", "Shape": "形状", "Bucket": "填充",
		"Redraw": "清空", "SelectDelete": "框删", "Generate": "固化",
		"ReturnToCanvas": "墨化", "Nail": "钉子", "ExpandCanvas": "扩展",
	}
	for index in order.size():
		var button := tool_grid.get_node_or_null(NodePath(order[index])) as Button
		if button != null:
			if button.name == &"ExpandCanvas":
				button.icon = _atlas_icon(ExpandCanvasIconSource, EXPAND_CANVAS_ICON_REGION)
			_add_tool_button_contents(button, str(captions[order[index]]))
			tool_grid.move_child(button, index)
	hand_button.reparent(buttons)
	hand_button.icon = _atlas_icon(EditorControlIconSource, EDITOR_CONTROL_ICON_REGION)
	hand_button.text = ""
	hand_button.expand_icon = true
	hand_button.add_theme_constant_override("icon_max_width", 92)


func _atlas_icon(source: Texture2D, region: Rect2) -> AtlasTexture:
	var icon := AtlasTexture.new()
	icon.atlas = source
	icon.region = region
	return icon


func _add_tool_button_contents(button: Button, caption_text: String) -> void:
	var icon_texture := button.icon
	button.icon = null
	button.text = ""
	button.expand_icon = false
	var icon_view := TextureRect.new()
	icon_view.name = "ToolIcon"
	icon_view.texture = icon_texture
	icon_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon_view.offset_left = 8.0
	icon_view.offset_top = 6.0
	icon_view.offset_right = -8.0
	icon_view.offset_bottom = -28.0
	button.add_child(icon_view)
	var caption := Label.new()
	caption.name = "Caption"
	caption.text = caption_text
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.anchor_left = 0.0
	caption.anchor_top = 1.0
	caption.anchor_right = 1.0
	caption.anchor_bottom = 1.0
	caption.offset_top = -28.0
	caption.offset_bottom = -2.0
	caption.add_theme_font_size_override("font_size", 16)
	button.add_child(caption)


func _apply_tool_button_metrics(button: Button, width: float, height: float,
		caption_height: float, font_size: int) -> void:
	button.custom_minimum_size = Vector2(width, height)
	var icon_view := button.get_node("ToolIcon") as TextureRect
	icon_view.offset_left = 4.0 if _map_editor_mode else 3.0
	icon_view.offset_top = 3.0 if _map_editor_mode else 2.0
	icon_view.offset_right = -4.0 if _map_editor_mode else -3.0
	icon_view.offset_bottom = -caption_height
	var caption := button.get_node("Caption") as Label
	caption.offset_top = -caption_height
	caption.offset_bottom = 0.0
	caption.add_theme_font_size_override("font_size", font_size)


## 两种模式均按 PPT 使用两列；操纵按钮独占最下方一行。
func _apply_workbench_column_layout() -> void:
	var columns: int = EDITOR_TOOL_COLUMNS if _map_editor_mode else PLAY_TOOL_COLUMNS
	var button_width := EDITOR_TOOL_BUTTON_WIDTH if _map_editor_mode else PLAY_TOOL_BUTTON_WIDTH
	var button_height := EDITOR_TOOL_BUTTON_HEIGHT if _map_editor_mode else PLAY_TOOL_BUTTON_HEIGHT
	var h_gap := EDITOR_TOOL_BUTTON_H_GAP if _map_editor_mode else PLAY_TOOL_BUTTON_H_GAP
	var v_gap := EDITOR_TOOL_BUTTON_V_GAP if _map_editor_mode else PLAY_TOOL_BUTTON_V_GAP
	var hand_size := EDITOR_HAND_BUTTON_SIZE if _map_editor_mode else PLAY_HAND_BUTTON_SIZE
	var caption_height := 14.0 if _map_editor_mode else 12.0
	var width := columns * button_width + (columns - 1) * h_gap
	tool_grid.columns = columns
	tool_grid.add_theme_constant_override("h_separation", int(h_gap))
	tool_grid.add_theme_constant_override("v_separation", int(v_gap))
	tool_grid.offset_right = width
	var visible_count := 0
	for child in tool_grid.get_children():
		if child is Control and child.visible:
			_apply_tool_button_metrics(child as Button, button_width, button_height,
				caption_height, 10 if _map_editor_mode else 8)
			visible_count += 1
	var rows := ceili(float(visible_count) / float(columns))
	var grid_height := rows * button_height + maxi(rows - 1, 0) * v_gap
	tool_grid.offset_bottom = grid_height
	var hand_gap := 12.0 if _map_editor_mode else 8.0
	hand_button.custom_minimum_size = Vector2.ONE * hand_size
	hand_button.add_theme_constant_override("icon_max_width", 58 if _map_editor_mode else 42)
	hand_button.position = Vector2((width - hand_size) * 0.5, grid_height + hand_gap)
	hand_button.size = Vector2.ONE * hand_size
	if _map_editor_mode:
		buttons.offset_left = -186.0
		buttons.offset_top = 116.0
		toggle_button.offset_left = -186.0
		toggle_button.offset_top = 56.0
		toggle_button.offset_bottom = 84.0
		toggle_button.add_theme_font_size_override("font_size", 16)
	else:
		buttons.offset_left = -42.0
		buttons.offset_top = 160.0
		toggle_button.offset_left = -22.0
		toggle_button.offset_top = 136.0
		toggle_button.offset_bottom = 154.0
		toggle_button.add_theme_font_size_override("font_size", 10)
	buttons.offset_right = buttons.offset_left + width
	buttons.offset_bottom = buttons.offset_top + grid_height + hand_size + hand_gap
	toggle_button.offset_right = toggle_button.offset_left + (width if _map_editor_mode else 36.0)


## 工具栏贴到玩家身体旁边。
func _update_follow_position() -> void:
	if player == null:
		return
	var body = player.get("body")
	var center: Vector2 = body.com_world() if body != null else player.global_position
	workbench.position = to_local(center + follow_offset)
	_place_side_panel()


func _update_screen_fixed_position() -> void:
	if not is_inside_tree():
		return
	var screen_transform := Transform2D.IDENTITY
	screen_transform.origin = screen_toolbar_origin
	workbench.global_transform = get_viewport().get_canvas_transform().affine_inverse() * screen_transform


func _process(_delta: float) -> void:
	if _screen_fixed:
		_update_screen_fixed_position()


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
	if player == null or _follow_player or _screen_fixed:
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
	brush_panel.visible = false
	resize_panel.visible = false
	#右侧面板是另一套布局，不跟着左边那个"隐藏"按钮走。
	if _side_panel != null:
		_side_panel.visible = active and nearby and not _map_editor_mode


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
	hand_button.pressed.connect(_on_hand_pressed)
	tool_grid.get_node("Brush").pressed.connect(set_tool.bind(SurfaceScript.Tool.BRUSH))
	tool_grid.get_node("Eraser").pressed.connect(set_tool.bind(SurfaceScript.Tool.ERASER))
	tool_grid.get_node("Shape").pressed.connect(_open_shape_popup)
	tool_grid.get_node("Nail").pressed.connect(set_tool.bind(SurfaceScript.Tool.NAIL))
	tool_grid.get_node("Bucket").pressed.connect(set_tool.bind(SurfaceScript.Tool.BUCKET))
	tool_grid.get_node("SelectDelete").pressed.connect(set_tool.bind(SurfaceScript.Tool.SELECT_DELETE))
	tool_grid.get_node("Redraw").pressed.connect(clear_canvas)
	tool_grid.get_node("Generate").pressed.connect(generate)
	tool_grid.get_node("ReturnToCanvas").pressed.connect(return_to_canvas)
	tool_grid.get_node("ExpandCanvas").pressed.connect(_open_expand_canvas_window)
	resize_panel.get_node("Grid/PlayerVisibility").toggled.connect(_on_player_visibility_toggled)
	resize_panel.get_node("Grid/NailVisibility").toggled.connect(_on_nail_visibility_toggled)
	toggle_button.pressed.connect(_toggle_workbench)
	brush_panel.get_node("PenSlider").value_changed.connect(_on_pen_slider_changed)


func _on_hand_pressed() -> void:
	set_tool(SurfaceScript.Tool.HAND)
	if _map_editor_mode:
		editor_control_requested.emit()


func _build_expand_canvas_window() -> void:
	_expand_canvas_window = Window.new()
	_expand_canvas_window.name = "ExpandCanvasWindow"
	_expand_canvas_window.title = "扩展画布"
	_expand_canvas_window.size = Vector2i(420, 390)
	_expand_canvas_window.min_size = Vector2i(380, 350)
	_expand_canvas_window.visible = false
	_expand_canvas_window.transient = true
	_expand_canvas_window.theme = EditorTheme
	_expand_canvas_window.close_requested.connect(_expand_canvas_window.hide)
	add_child(_expand_canvas_window)
	_expand_canvas_window.hide()

	var margin := MarginContainer.new()
	margin.name = "Content"
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_bottom", 24)
	_expand_canvas_window.add_child(margin)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 16)
	margin.add_child(column)

	var explanation := Label.new()
	explanation.text = "输入四侧需要增加的像素。原有地图内容的世界位置不会改变。"
	explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(explanation)

	_expand_size_preview = Label.new()
	_expand_size_preview.name = "SizePreview"
	column.add_child(_expand_size_preview)

	var input_grid := GridContainer.new()
	input_grid.name = "Inputs"
	input_grid.columns = 2
	input_grid.add_theme_constant_override("h_separation", 24)
	input_grid.add_theme_constant_override("v_separation", 10)
	column.add_child(input_grid)
	for side in ["Left", "Right", "Top", "Bottom"]:
		var label := Label.new()
		label.text = {"Left": "左侧", "Right": "右侧", "Top": "上侧", "Bottom": "下侧"}[side]
		input_grid.add_child(label)
		var amount := SpinBox.new()
		amount.name = side + "Amount"
		amount.custom_minimum_size = Vector2(210, 42)
		amount.min_value = 0
		amount.max_value = 8192
		amount.step = 16
		amount.value = 0
		amount.suffix = " px"
		amount.value_changed.connect(_update_expand_size_preview.unbind(1))
		input_grid.add_child(amount)
		_expand_inputs[side] = amount

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 12)
	column.add_child(actions)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.pressed.connect(_expand_canvas_window.hide)
	actions.add_child(cancel)
	var confirm := Button.new()
	confirm.text = "确认扩展"
	confirm.pressed.connect(_confirm_expand_canvas)
	actions.add_child(confirm)
	_update_expand_size_preview()


func _open_expand_canvas_window() -> void:
	if not _map_editor_mode or _expand_canvas_window == null:
		return
	for input: SpinBox in _expand_inputs.values():
		input.value = 0
	_update_expand_size_preview()
	_expand_canvas_window.popup_centered()


func _update_expand_size_preview() -> void:
	if _expand_size_preview == null:
		return
	var left := int((_expand_inputs.get("Left") as SpinBox).value)
	var right := int((_expand_inputs.get("Right") as SpinBox).value)
	var top := int((_expand_inputs.get("Top") as SpinBox).value)
	var bottom := int((_expand_inputs.get("Bottom") as SpinBox).value)
	_expand_size_preview.text = "当前：%d × %d px    扩展后：%d × %d px" % [
		canvas_size.x, canvas_size.y,
		canvas_size.x + left + right, canvas_size.y + top + bottom,
	]


func _confirm_expand_canvas() -> void:
	var left := int((_expand_inputs["Left"] as SpinBox).value)
	var right := int((_expand_inputs["Right"] as SpinBox).value)
	var top := int((_expand_inputs["Top"] as SpinBox).value)
	var bottom := int((_expand_inputs["Bottom"] as SpinBox).value)
	if left + right + top + bottom == 0:
		return
	if expand_canvas_sides(left, right, top, bottom):
		_expand_canvas_window.hide()


## 隐藏 / 显示工具栏本体。按钮自己一直露着，好点回来。
func _toggle_workbench() -> void:
	_workbench_hidden = not _workbench_hidden
	toggle_button.text = "显示" if _workbench_hidden else "隐藏"
	_refresh_workbench_visibility()


func _on_player_visibility_toggled(show_player: bool) -> void:
	if not _map_editor_mode or player == null:
		return
	player.visible = show_player
	_update_player_visibility_tooltip(show_player)


func _update_player_visibility_tooltip(show_player: bool) -> void:
	var button: Button = resize_panel.get_node("Grid/PlayerVisibility")
	button.tooltip_text = "隐藏小人" if show_player else "显示小人"


func _on_nail_visibility_toggled(show_nails: bool) -> void:
	if not _map_editor_mode:
		return
	_nails_visible = show_nails
	_apply_nail_visuals(show_nails)
	_update_nail_visibility_tooltip(show_nails)


func _apply_nail_visuals(show_nails: bool) -> void:
	NailScript.visuals_visible = show_nails
	NailScript.map_editor_active = _map_editor_mode
	surface.nail_layer.visible = show_nails
	if not is_inside_tree():
		return
	for nail in get_tree().get_nodes_in_group(NailScript.VISUAL_GROUP):
		if nail.has_method("refresh_visibility"):
			nail.refresh_visibility()


func _update_nail_visibility_tooltip(show_nails: bool) -> void:
	var button: Button = resize_panel.get_node("Grid/NailVisibility")
	button.tooltip_text = "隐藏钉子外观" if show_nails else "显示钉子外观"


var _shape_tool: int = SurfaceScript.Tool.RECT
var _shape_popup: PopupMenu
var _temporary_eraser := false


## 构建形状选择弹出菜单（矩形 / 圆形 / 直线）。
func _build_shape_popup() -> void:
	_shape_popup = PopupMenu.new()
	_shape_popup.name = "ShapePopup"
	_shape_popup.add_item("矩形", SurfaceScript.Tool.RECT)
	_shape_popup.add_item("圆形", SurfaceScript.Tool.CIRCLE)
	_shape_popup.add_item("直线", SurfaceScript.Tool.LINE)
	_shape_popup.id_pressed.connect(_on_shape_picked)
	_shape_popup.popup_hide.connect(_on_shape_popup_hide)
	add_child(_shape_popup)


## 点击形状按钮时在鼠标位置弹出三个选项。
func _open_shape_popup() -> void:
	if _shape_popup == null:
		return
	# 按钮在 Node2D 父级下 global_rect 不准，直接用鼠标视口坐标。
	_shape_popup.position = Vector2i(get_viewport().get_mouse_position())
	_shape_popup.reset_size()
	_shape_popup.popup()


## 选中某个形状后切换工具并更新按钮提示。
func _on_shape_picked(id: int) -> void:
	_shape_tool = id
	_apply_tool(id)
	_update_shape_tooltip(id)


## 菜单关闭（未选择）时，按当前实际工具刷新按钮高亮，避免 Shape 按钮卡在 pressed。
func _on_shape_popup_hide() -> void:
	_apply_tool(surface.tool)


func _update_shape_tooltip(tool: int) -> void:
	var shape_name := "矩形"
	if tool == SurfaceScript.Tool.CIRCLE:
		shape_name = "圆形"
	elif tool == SurfaceScript.Tool.LINE:
		shape_name = "直线"
	tool_grid.get_node("Shape").tooltip_text = "自选形状：%s（5/6/9）\n点击按钮选择形状" % shape_name


func _apply_tool(tool: int) -> void:
	surface.tool = tool
	hand_button.set_pressed_no_signal(tool == SurfaceScript.Tool.HAND)
	tool_grid.get_node("Brush").set_pressed_no_signal(tool == SurfaceScript.Tool.BRUSH)
	tool_grid.get_node("Eraser").set_pressed_no_signal(tool == SurfaceScript.Tool.ERASER)
	tool_grid.get_node("Shape").set_pressed_no_signal(
		tool == SurfaceScript.Tool.RECT or tool == SurfaceScript.Tool.CIRCLE \
		or tool == SurfaceScript.Tool.LINE
	)
	tool_grid.get_node("Nail").set_pressed_no_signal(tool == SurfaceScript.Tool.NAIL)
	tool_grid.get_node("Bucket").set_pressed_no_signal(tool == SurfaceScript.Tool.BUCKET)
	tool_grid.get_node("SelectDelete").set_pressed_no_signal(tool == SurfaceScript.Tool.SELECT_DELETE)
	_sync_hand_enabled(tool)
	if tool in [SurfaceScript.Tool.RECT, SurfaceScript.Tool.CIRCLE, SurfaceScript.Tool.LINE]:
		_update_shape_tooltip(tool)
	tool_changed.emit(tool)


#滑块带格子（step = 2），值域就是奇数直径 1..17。
func _on_pen_slider_changed(value: float) -> void:
	set_brush_size(int(round(value)))
#endregion


#region 复现文件与调试输入
## 开发复现文件留在 test，保存内容仍是未固化墨水。
@export var capture_path: String = "res://test/canvas_capture.tres"
## 大地图整图；存下来当参考图（没有节点读它）。
@export_file("*.png") var baked_map_path: String = "res://map/asset/baked_map.png"
## 开发用的 F5/F9 存读；创造模式接管 F5 时会被关掉，避免两套保存同时跑。
var dev_save_enabled := true


func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	#绘图工具下，右键只充当临时橡皮：按住切换，松开恢复，不改变长期工具选择。
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed and get_viewport().gui_get_hovered_control() != null:
			return
		if event.pressed and not _temporary_eraser and surface.tool == SurfaceScript.Tool.BRUSH:
			_temporary_eraser = true
			_apply_tool(SurfaceScript.Tool.ERASER)
		elif not event.pressed and _temporary_eraser:
			_temporary_eraser = false
			_apply_tool(SurfaceScript.Tool.BRUSH)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		# 地图扩展保留为快捷键，界面不再占一排方向按钮。
		if _map_editor_mode and event.ctrl_pressed:
			var expanded := true
			match event.keycode:
				KEY_LEFT:
					expand_left()
				KEY_RIGHT:
					expand_right()
				KEY_UP:
					expand_up()
				KEY_DOWN:
					expand_down()
				_:
					expanded = false
			if expanded:
				get_viewport().set_input_as_handled()
				return
		match event.keycode:
			KEY_F:
				_on_hand_pressed()
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
			KEY_8:
				set_tool(SurfaceScript.Tool.SELECT_DELETE)
			KEY_9:
				set_tool(SurfaceScript.Tool.LINE)
			KEY_E:
				generate()
	#保存/读取走输入动作，别和上面的裸键 match 串成一个分支。
	if dev_save_enabled and event.is_action_pressed("canvas_save"):
		surface.save_ink(capture_path)
		surface.save_png(baked_map_path)
	elif dev_save_enabled and event.is_action_pressed("canvas_load"):
		surface.load_ink(capture_path)
#endregion
