#region 依赖
@tool
extends Node2D

signal tool_changed(tool: int)
signal ink_selected(index: int)
signal map_changed
signal editor_control_requested

const SurfaceScript := preload("res://actor/canvas/src/canvas_surface.gd")
const History := preload("res://actor/canvas/src/canvas_history.gd")
const NailScript := preload("res://actor/nail/src/nail.gd")
const YellowHinge := preload("res://ink/yellow/src/hinge.gd")
var _selection_rotation = preload("res://actor/canvas/src/selection_rotation.gd").new()
const YellowAxle := preload("res://ink/yellow/src/axle.gd")
const SelectionMask := preload("res://actor/canvas/src/selection_mask.gd")
const GearCenters := preload("res://actor/canvas/src/gear_centers.gd")
const GearBearings := preload("res://actor/canvas/src/gear_bearings.gd")
const InkPalette := preload("res://ink/general/src/ink_palette.gd")
const InkSelectionIndicator := preload("res://ui/theme/ink_selection_indicator.gd")
const InkPanel := preload("res://actor/canvas/panel/src/ink_panel.gd")
const ToolbarBuilder := preload("res://actor/canvas/toolbar/src/toolbar_builder.gd")
const ExpandWindow := preload("res://actor/canvas/panel/src/expand_canvas_window.gd")
const ShapeMenu := preload("res://actor/canvas/toolbar/src/shape_menu.gd")
const ToolbarActions := preload("res://actor/canvas/toolbar/src/toolbar_actions.gd")
const EditorTheme := preload("res://ui/theme/asset/ink_attack_theme.tres")
const ExpandCanvasIconSource := preload("res://actor/canvas/asset/expand_canvas.png")
const EditorControlIconSource := preload("res://actor/canvas/asset/editor_control.png")
const EXPAND_CANVAS_ICON_REGION := Rect2(228, 128, 116, 116)
const EDITOR_CONTROL_ICON_REGION := Rect2(340, 340, 116, 116)
const PLAY_TOOL_COLUMNS := 2
const TOOLBAR_TEXT_COLOR := Color("414141")
## 工具栏所在的 CanvasLayer：高于 HUD(1) 与右侧色盘(2)，低于 ESC(20)。
const TOOLBAR_LAYER := 3
const EDITOR_TOOL_COLUMNS := 2
const PLAY_TOOL_BUTTON_WIDTH := 32.0
const PLAY_TOOL_BUTTON_HEIGHT := 43.0
const PLAY_TOOL_BUTTON_H_GAP := 10.0
const PLAY_TOOL_BUTTON_V_GAP := 4.0
const PLAY_HAND_BUTTON_SIZE := 52.0
const PLAY_TOOLBAR_Y_OFFSET := 24.0
const PLAY_TOOLBAR_X_OFFSET := 2.0
const EDITOR_TOOL_BUTTON_WIDTH := 44.0
const EDITOR_TOOL_BUTTON_HEIGHT := 60.0
const EDITOR_TOOL_BUTTON_H_GAP := 16.0
const EDITOR_TOOL_BUTTON_V_GAP := 10.0
const EDITOR_HAND_BUTTON_SIZE := 72.0
## 工具栏按行排列；前十个按钮使用数字键 1～0。无限钉子不在工具栏，入口在创造模式
## 右侧「机关部件」栏（它参与机关，和齿轮放一起）。
const TOOL_SHORTCUT_ORDER := [
	"Brush", "Eraser", "Shape", "Bucket", "Redraw", "SelectDelete",
	"Generate", "ReturnToCanvas", "Nail", "ExpandCanvas",
]

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
var _ink_warning_panel: PanelContainer
var _ink_warning_label: Label
var _ink_warning_token := 0
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
	if not Engine.is_editor_hint():
		add_to_group(&"canvas_workbench")
	process_physics_priority = 18 # 世界步进后更新玩家与工作台的距离。
	_workbench_home_transform = workbench.transform
	_lift_workbench_to_screen_layer()
	var rod_pixels: Image = surface.rod_layer.pixels.duplicate() if surface.rod_layer.pixels != null else null
	var rod_anchors: PackedVector2Array = surface.rod_layer.anchor_points.duplicate()
	var rod_rails: Array = surface.rod_layer.rails.duplicate(true)
	var rod_pins: Array = surface.rod_layer.slider_pins.duplicate(true)
	var blue_cells: PackedVector2Array = surface.blue_layer.cells.duplicate()
	surface.canvas_size = canvas_size
	surface.blue_layer.cells = blue_cells
	surface.blue_layer.rebuild()
	# 已保存的独立黄色层不能被首次 Canvas 尺寸同步清空。
	if rod_pixels != null and rod_pixels.get_used_rect().has_area():
		surface.rod_layer.pixels = rod_pixels
		surface.rod_layer.anchor_points = rod_anchors
		surface.rod_layer.rails = rod_rails
		surface.rod_layer.slider_pins = rod_pins
		surface.rod_layer.resize(canvas_size)
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
		_build_selection_popup()
		_bind_buttons()
		surface.selection_move_requested.connect(_move_selection)
		surface.ink_shortage.connect(_show_ink_shortage)
		surface.notice_requested.connect(_show_canvas_notice)
		# 进入正常游戏时始终从“手”开始，不能继承地图保存时的画笔状态。
		_apply_tool(SurfaceScript.Tool.HAND if active else surface.tool)
	_apply_toolbar_text_color(workbench)
	if _side_panel != null:
		_apply_toolbar_text_color(_side_panel)


## 左右画布工具栏统一深灰文字。图标是 ToolIcon 子节点（原图不染色），
## 禁用态只在 tool_icon_feedback 里降透明度，所以这里不碰 icon 颜色。
func _apply_toolbar_text_color(node: Node) -> void:
	if node is Label:
		node.add_theme_color_override("font_color", TOOLBAR_TEXT_COLOR)
	elif node is Button:
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_disabled_color", "font_hover_pressed_color"]:
			node.add_theme_color_override(state, TOOLBAR_TEXT_COLOR)
	for child in node.get_children():
		_apply_toolbar_text_color(child)

#endregion


## 墨水不足时在屏幕顶端提示一次；拖动过程不会逐帧反复弹出。
func _show_ink_shortage(required: int, available: int) -> void:
	if not active:
		return
	if _ink_warning_panel == null:
		var layer := CanvasLayer.new()
		layer.layer = 100
		layer.name = "InkWarningLayer"
		add_child(layer)
		_ink_warning_panel = PanelContainer.new()
		_ink_warning_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_ink_warning_panel.anchor_left = 0.5
		_ink_warning_panel.anchor_right = 0.5
		_ink_warning_panel.offset_left = -270.0
		_ink_warning_panel.offset_top = 26.0
		_ink_warning_panel.offset_right = 270.0
		_ink_warning_panel.offset_bottom = 74.0
		_ink_warning_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var background := StyleBoxFlat.new()
		background.bg_color = Color(0.97, 0.95, 0.83, 0.96)
		background.border_color = Color(0.04, 0.04, 0.03)
		background.set_border_width_all(2)
		_ink_warning_panel.add_theme_stylebox_override("panel", background)
		layer.add_child(_ink_warning_panel)
		_ink_warning_label = Label.new()
		_ink_warning_label.theme = EditorTheme
		_ink_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_ink_warning_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_ink_warning_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ink_warning_label.add_theme_font_size_override("font_size", 20)
		_ink_warning_panel.add_child(_ink_warning_label)
	if required <= SurfaceScript.MIN_PAINT_INK:
		_ink_warning_label.text = "墨水低于 1000 px，无法作画（剩余 %d px）" % available
	else:
		_ink_warning_label.text = "墨水不足：完成绘制需 %d px，剩余 %d px" % [required, available]
	_ink_warning_panel.visible = true
	_ink_warning_token += 1
	var token := _ink_warning_token
	await get_tree().create_timer(2.4).timeout
	if is_instance_valid(_ink_warning_panel) and token == _ink_warning_token:
		_ink_warning_panel.visible = false


func _show_canvas_notice(message: String) -> void:
	_show_ink_shortage(SurfaceScript.MIN_PAINT_INK, 0)
	if _ink_warning_label != null:
		_ink_warning_label.text = message


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
	var state := History.capture(self)
	surface.clear()
	History.commit(self, state)


## 墨水固化成实体（原 E 键）。
func generate(record_undo := true) -> void:
	# 激活白墨即不可撤销；它随后会修改别的实体，旧事务不能跨过这条边界。
	if surface.ink_px_of(preload("res://ink/general/src/ink_palette.gd").WHITE.id) > 0:
		record_undo = false
		surface._undo_steps.clear()
	# 补线会修改已有活动导线，撤销需保存电路；无需逐像素打包已有轮体/地形。
	var state: Dictionary = History.capture(self, false, Rect2(), {}, true) if record_undo else {}
	var nail_state: Dictionary = surface.nail_layer.snapshot()
	# 只在落笔/抬笔时记录黑色；固化前擦掉的黑色不能重新成为轴。
	for index in range(surface.rod_layer.anchor_points.size() - 1, -1, -1):
		if not surface.rod_layer._black(surface.rod_layer.anchor_points[index]):
			surface.rod_layer.anchor_points.remove_at(index)
	var centers: Array = GearCenters.normalize(surface.gear_centers)
	var pending_bearings: Array = surface.draft_bearings.duplicate(true)
	solid.solidify(surface, world, _map_editor_mode)
	surface.rod_layer.solidify(world, nail_state, GearCenters.positions(centers))
	# 固化只把中心转移到刚体；轴承必须来自草稿里明确记录的手动放置。
	GearCenters.attach(surface, world, centers)
	GearBearings.restore(surface, pending_bearings)
	var yellow = surface.yellow_rule()
	if yellow != null:
		yellow.solidify(surface)
	if surface.blue_rule() != null:
		surface.blue_rule().solidify(surface)
	if record_undo:
		History.commit(self, state)
	_apply_nail_visuals(_nails_visible if _map_editor_mode else true)


## 画布范围内的实体重采样回墨水。
## `preserved` 中的刚体保持实体；用于退出编辑器时只保留齿轮/机构。
func return_to_canvas(record_undo := true, keep_yellow_drafts := false,
		preserved: Dictionary = {}) -> void:
	var state: Dictionary = History.capture(self, true) if record_undo else {}
	if keep_yellow_drafts or _map_editor_mode:
		# 黄墨连杆转回蓝图时，保存轴点并移除旧关节；下次固化重新创建。
		for child in world.get_children().duplicate():
			if not child is YellowHinge or child is YellowAxle:
				continue
			if not child.yellow_anchor.is_empty() and preserved.has(child.yellow_anchor.body):
				continue
			var point: Vector2 = surface.to_local(world.to_global(child.yellow_position))
			if not surface._inside(point):
				continue
			if not surface.rod_layer.anchor_points.has(point):
				surface.rod_layer.anchor_points.append(point)
			child.remove_joint()
			world.remove_child(child)
			child.queue_free()
	var yellow = surface.yellow_rule()
	if yellow != null:
		yellow.reclaim(surface, keep_yellow_drafts or _map_editor_mode, preserved)
	if surface.blue_rule() != null:
		surface.blue_rule().reclaim(surface, Rect2i(), preserved)
	solid.rasterize(surface, world, preserved)
	if record_undo:
		History.commit(self, state)


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
		# 出界实体已永久回收，解除形状回指，避免反复编辑地图积累引用环。
		for shape in body.shapes:
			if shape.owner_body == body:
				shape.owner_body = null
		var node = nodes_by_body.get(body)
		if is_instance_valid(node):
			node.queue_free()
		for child in world.get_children():
			if child is NailScript and child.get("body") == body:
				child.queue_free()
	world.sync_world_bodies()
	return removed.size()


## 未固化墨水与已固化实体一起框删，并合并成一个画布撤销步骤。
func _delete_selection(rect: Rect2i, mask: Dictionary = {}) -> void:
	# 同一事务保存蓝图和实体，撤销时各自回到删除前的状态。
	var state := History.capture(self, true, Rect2(surface.to_global(Vector2(rect.position)), Vector2(rect.size)))
	var removed: int = solid.rasterize_rect(surface, world, rect, {}, mask)
	if removed > 0:
		solid.sync_serializable_bodies(world)
	surface.erase_rect(rect, mask)
	surface.rod_layer.erase_rect(rect, mask)
	var yellow = surface.yellow_rule()
	if yellow != null:
		yellow.erase_strokes_in_rect(surface, rect, mask)
	History.commit(self, state)
	_apply_nail_visuals(_nails_visible if _map_editor_mode else true)


## 完整选中的实体直接变换，保持重叠部件、局部像素和连接身份，不经过栅格化。
func whole_bodies_in_selection(rect: Rect2i, mask: Dictionary = {}) -> Dictionary:
	var result := {}
	for body in world.world.bodies:
		if body.tags.has("living") or body.tags.has("map_monster"):
			continue
		var box: Rect2 = body.aabb
		var corners := [box.position, Vector2(box.end.x - 0.001, box.position.y),
			box.end - Vector2.ONE * 0.001, Vector2(box.position.x, box.end.y - 0.001)]
		var complete := true
		for corner in corners:
			var at := Vector2i(surface.to_local(corner).floor())
			if not rect.has_point(at) or not SelectionMask.contains(mask, at):
				complete = false
				break
		if complete:
			result[body] = true
	return result


func transform_whole_bodies(bodies: Dictionary, offset: Vector2, angle := 0.0, pivot := Vector2.ZERO) -> void:
	var world_pivot: Vector2 = surface.to_global(pivot)
	var shift: Vector2 = surface.to_global(offset) - surface.global_position
	for body in bodies:
		body.position = world_pivot + (body.position - world_pivot).rotated(angle) + shift
		body.rotation += angle
		body.update_aabb()
		var node = GearCenters.node_for_body(world, body)
		if node != null:
			node.position = body.position
			node.rotation = body.rotation
	for child in world.get_children():
		if child is YellowAxle and not child.yellow_anchor.is_empty():
			if bodies.has(child.yellow_anchor.body) and child.fixed_to_world:
				child.remove_joint()
				child.black_position = world_pivot + (child.black_position - world_pivot).rotated(angle) + shift
			child._process(0.0)
		elif child.has_method("sync_pose"):
			child.sync_pose()


## 框选拖动：固化像素先回收到画布，再与普通/黄色图层一起搬移。
func _move_selection(rect: Rect2i, offset: Vector2i, mask: Dictionary = {}) -> void:
	if offset == Vector2i.ZERO:
		return
	var bounds := Rect2(surface.to_global(Vector2(rect.position)), Vector2(rect.size))
	var state := History.capture(self, true, bounds)
	var whole := whole_bodies_in_selection(rect, mask)
	var moved_physical: Dictionary = {}
	var moved_centers: Array = []
	var moved_bearings: Array = []
	var removed: int = solid.rasterize_rect(surface, world, rect, moved_physical, mask, whole,
		moved_centers, moved_bearings)
	transform_whole_bodies(whole, Vector2(offset))
	var moved_black: bool = surface.move_rect(rect, offset, mask, true)
	var blue = surface.blue_rule()
	var moved_blue: bool = blue.move_selection_drafts(surface, rect, offset, mask) if blue != null else false
	var moved_yellow: bool = surface.rod_layer.move_rect(rect, offset, mask)
	var yellow = surface.yellow_rule()
	var moved_spring: bool = yellow.move_drafts_in_rect(surface, rect, offset, mask) if yellow != null else false
	if removed > 0:
		solid.spawn_moved_pixels(surface, world, moved_physical, offset, _map_editor_mode)
		for record in moved_centers:
			record["position"] = GearCenters.position_of(record) + Vector2(offset)
		GearCenters.attach(surface, world, moved_centers)
		for record in moved_bearings:
			record["position"] = Vector2(record.get("position", Vector2.ZERO)) + Vector2(offset)
			var support_point := Vector2(record.get("support_position", Vector2.ZERO))
			var support_at := Vector2i(support_point.floor())
			if bool(record.get("fixed_to_world", false)) or (rect.has_point(support_at) and SelectionMask.contains(mask, support_at)):
				record["support_position"] = support_point + Vector2(offset)
		GearBearings.restore(surface, moved_bearings)
		solid.sync_serializable_bodies(world)
	if removed > 0 or moved_black or moved_blue or moved_yellow or moved_spring or not whole.is_empty():
		History.commit(self, state)
	_apply_nail_visuals(_nails_visible if _map_editor_mode else true)

func bake_png(path: String) -> Error:
	return solid.preview_image(surface, world).save_png(ProjectSettings.globalize_path(path))


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


## 一次调整四侧；负值缩小并裁切边缘内容，保留部分的世界坐标不变。
func expand_canvas_sides(left: int, right: int, top: int, bottom: int) -> bool:
	if left == 0 and right == 0 and top == 0 and bottom == 0:
		return false
	var content_offset := Vector2i(left, top)
	var new_size := canvas_size + Vector2i(left + right, top + bottom)
	if new_size.x < 1 or new_size.y < 1:
		return false
	var shrinking := left < 0 or right < 0 or top < 0 or bottom < 0
	var state := History.capture(self, shrinking)
	if shrinking:
		var old_bounds := Rect2i(Vector2i.ZERO, canvas_size)
		var kept := old_bounds.intersection(Rect2i(-content_offset, new_size))
		var removed: Array[Rect2i] = []
		if not kept.has_area():
			removed.append(old_bounds)
		else:
			removed.append(Rect2i(0, 0, canvas_size.x, kept.position.y))
			removed.append(Rect2i(0, kept.end.y, canvas_size.x, canvas_size.y - kept.end.y))
			removed.append(Rect2i(0, kept.position.y, kept.position.x, kept.size.y))
			removed.append(Rect2i(kept.end.x, kept.position.y, canvas_size.x - kept.end.x, kept.size.y))
		var changed_bodies := false
		for rect in removed:
			if not rect.has_area():
				continue
			changed_bodies = solid.rasterize_rect(surface, world, rect) > 0 or changed_bodies
			surface.erase_rect(rect)
		if changed_bodies:
			solid.sync_serializable_bodies(world)
		var yellow = surface.yellow_rule()
		if yellow != null:
			yellow.crop_to_surface(surface, kept)
	if not surface.resize_preserving_content(new_size, content_offset):
		return false
	_syncing_preserved_resize = true
	canvas_size = new_size
	_syncing_preserved_resize = false
	position -= Vector2(content_offset)
	History.commit(self, state)
	map_changed.emit()
	return true


#endregion


#region 工作台布局
#画布和工具栏都是世界物件，不绑玩家；HUD 才留在 CanvasLayer 跟随屏幕。
## 固定工具栏时，WorkbenchUI 原点所在的视口逻辑坐标。
## 控件自身向左偏移 222 px、向下偏移 56 px，所以默认值会让可见区域从 (16, 16) 开始。
@export var screen_toolbar_origin := Vector2(238, -40)

var _workbench_nearby := true
@export var toolbar_transition_seconds := 0.22
var _workbench_hidden := false
var _workbench_home_transform := Transform2D.IDENTITY
var _screen_fixed := false
var _map_editor_mode := false
var _syncing_preserved_resize := false
var _nails_visible := true


## 工具栏原本是世界物件，会被 HUD 的 CanvasLayer 压住（血条正好在上方）。
## 把它搬进一个高于 HUD(1) 和右侧色盘(2) 的 CanvasLayer，坐标也随之变成屏幕坐标：
## 所有写 workbench 变换的地方都用 `screen_transform`，不再乘逆视口矩阵。
func _lift_workbench_to_screen_layer() -> void:
	if Engine.is_editor_hint():
		return
	var layer := CanvasLayer.new()
	layer.name = "ToolbarLayer"
	layer.layer = TOOLBAR_LAYER
	add_child(layer)
	workbench.reparent(layer, false)


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
var _selected_ink_label: Label


#右侧面板由色表生成：加一种墨水这里不用改。构建逻辑见 `panel/src/ink_panel.gd`。
func _build_side_panel() -> void:
	var built: Dictionary = InkPanel.build(self, buttons.theme,
		brush_panel.get_node("PenSlider") as HSlider, {
			"select_ink": select_ink,
			"pen_changed": _on_pen_slider_changed,
			"brush_max": brush_size_max,
		})
	_side_panel = built.panel
	_ink_buttons = built.buttons
	_side_brush_slider = built.slider
	_selected_ink_label = built.label
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
		_ink_buttons[i].get_node("InkSelectionIndicator").set_selected(i == index)
	if is_instance_valid(_selected_ink_label):
		_selected_ink_label.text = "当前：%s" % InkPalette.ink_name(index)
	ink_selected.emit(index)


func _place_side_panel() -> void:
	if _side_panel == null:
		return
	var layout := get_node_or_null("SidePanelLayer")
	if layout != null:
		layout.update_layout()
#endregion


## 工具栏固定在视口左侧，不受相机移动、旋转或缩放影响。
func set_screen_fixed(on: bool) -> void:
	_screen_fixed = on
	if on:
		_update_screen_fixed_position()
	else:
		# _workbench_home_transform 是世界坐标；搬进 CanvasLayer 后要换成屏幕坐标才等价。
		workbench.transform = get_viewport().get_canvas_transform() * _workbench_home_transform
	set_process(on and active and not Engine.is_editor_hint())
	_refresh_workbench_visibility()


## 两种模式都显示完整工具栏；地图编辑模式额外显示钉子与扩展画布。
func set_map_editor_mode(on: bool) -> void:
	_map_editor_mode = on
	surface.map_editor_mode = on
	# 地图编辑器的任何入口都必须先让 Player 退出画面；不能只依赖 Creative.active，
	# 否则从模板/独立场景打开编辑器时会残留墨水瓶。
	var level := get_parent()
	var level_player := level.get_node_or_null("Player") if level != null else null
	if level_player != null:
		if on:
			level_player.visible = false
			var hidden: Color = level_player.modulate
			hidden.a = 0.0
			level_player.modulate = hidden
		else:
			level_player.visible = true
			level_player.modulate = Color.WHITE
	if not on and surface.tool in [SurfaceScript.Tool.GEAR, SurfaceScript.Tool.GEAR_8,
			SurfaceScript.Tool.INFINITE_NAIL]:
		_apply_tool(SurfaceScript.Tool.HAND)
	tool_grid.get_node("Brush").visible = true
	tool_grid.get_node("Eraser").visible = true
	tool_grid.get_node("Shape").visible = true
	tool_grid.get_node("Bucket").visible = true
	tool_grid.get_node("Nail").visible = on
	tool_grid.get_node("ExpandCanvas").visible = on
	hand_button.visible = true
	hand_button.tooltip_text = (
		"操纵（F）\n左键选中并拖动；右键删除怪物、文本、对话、图片、传送门或墨泉；滚轮缩放怪物、文本或图片"
		if on else "操纵（F）\n从绘图工具切换回墨水小瓶的手"
	)
	_apply_workbench_column_layout()
	_place_side_panel()
	if on and _expand_canvas_window == null:
		_build_expand_canvas_window()
	if not on and _expand_canvas_window != null:
		_expand_canvas_window.hide()
	var nail_visibility_button: Button = resize_panel.get_node("Grid/NailVisibility")
	nail_visibility_button.set_pressed_no_signal(_nails_visible)
	_update_nail_visibility_tooltip(_nails_visible)
	_apply_nail_visuals(_nails_visible if on else true)
	set_screen_fixed(on)


func _prepare_workbench_structure() -> void:
	ToolbarBuilder.prepare_structure(tool_grid, hand_button, buttons,
		ExpandCanvasIconSource, EXPAND_CANVAS_ICON_REGION,
		EditorControlIconSource, EDITOR_CONTROL_ICON_REGION)


func _atlas_icon(source: Texture2D, region: Rect2) -> AtlasTexture:
	return ToolbarBuilder.atlas_icon(source, region)


func _add_tool_button_contents(button: Button, caption_text: String) -> void:
	ToolbarBuilder.add_button_contents(button, caption_text)


func _apply_tool_button_metrics(button: Button, width: float, height: float,
		caption_height: float, font_size: int) -> void:
	ToolbarBuilder.apply_button_metrics(button, width, height, caption_height, font_size,
		_map_editor_mode)


## 两种模式均按 PPT 使用两列；操纵按钮独占最下方一行。
func _apply_workbench_column_layout() -> void:
	ToolbarBuilder.apply_column_layout(tool_grid, hand_button, buttons, toggle_button,
		_map_editor_mode, {
			"columns": EDITOR_TOOL_COLUMNS if _map_editor_mode else PLAY_TOOL_COLUMNS,
			"button_width": EDITOR_TOOL_BUTTON_WIDTH if _map_editor_mode else PLAY_TOOL_BUTTON_WIDTH,
			"button_height": EDITOR_TOOL_BUTTON_HEIGHT if _map_editor_mode else PLAY_TOOL_BUTTON_HEIGHT,
			"h_gap": EDITOR_TOOL_BUTTON_H_GAP if _map_editor_mode else PLAY_TOOL_BUTTON_H_GAP,
			"v_gap": EDITOR_TOOL_BUTTON_V_GAP if _map_editor_mode else PLAY_TOOL_BUTTON_V_GAP,
			"hand_size": EDITOR_HAND_BUTTON_SIZE if _map_editor_mode else PLAY_HAND_BUTTON_SIZE,
			"caption_height": 14.0 if _map_editor_mode else 12.0,
			"toolbar_x_offset": PLAY_TOOLBAR_X_OFFSET,
			"toolbar_y_offset": PLAY_TOOLBAR_Y_OFFSET,
		})


func _update_screen_fixed_position() -> void:
	if not is_inside_tree():
		return
	var screen_transform := Transform2D.IDENTITY
	screen_transform.origin = screen_toolbar_origin
	workbench.transform = screen_transform


func _process(_delta: float) -> void:
	if _screen_fixed:
		_update_screen_fixed_position()


func _physics_process(_delta: float) -> void:
	_refresh_workbench_visibility()


func _refresh_workbench_visibility() -> void:
	if not active:
		_set_workbench_visible(false)
		return
	if not Engine.is_editor_hint() and not _map_editor_mode and _side_panel == null:
		return # 动态色盘装配完成后再参与归属交接。
	var creative := get_parent().get_node_or_null("Creative")
	if not _map_editor_mode and creative != null and creative.get("active") == true:
		_set_workbench_visible(false, false)
		return
	# 单独预览或编辑地图时，工具栏保持可见。
	if _screen_fixed or Engine.is_editor_hint():
		_set_workbench_visible(true)
		if not Engine.is_editor_hint():
			surface.set_process_input(active)
		return
	if player == null:
		var owner_canvas := _choose_play_toolbar_owner()
		var taken := owner_canvas != null and owner_canvas != self
		_set_workbench_visible(owner_canvas == self, not taken)
		surface.set_process_input(active and owner_canvas == self)
		return
	var distance := _distance_from_player_to_canvas()
	var was_nearby := _workbench_nearby
	if _workbench_nearby:
		_workbench_nearby = distance <= maxf(toolbar_hide_distance, toolbar_show_distance)
	else:
		_workbench_nearby = distance <= minf(toolbar_show_distance, toolbar_hide_distance)
	var owner_canvas := _choose_play_toolbar_owner()
	# 只有"被别的画布抢走"时才立刻收起（否则两块工具栏会同时在场）；
	# 玩家单纯走远、没人接手时必须走淡出，离开是渐隐的。
	var taken := owner_canvas != null and owner_canvas != self
	_set_workbench_visible(_workbench_nearby and not taken, not taken)
	surface.set_process_input(active and owner_canvas == self)
	if was_nearby and not _workbench_nearby and not _map_editor_mode:
		_restore_hand_on_departure()


## 邻近画布共用一套视觉；绘制和点击工具栏时保持归属。
func _choose_play_toolbar_owner() -> Node:
	var level := get_parent()
	# 临时归属放在视口，避免把 WeakRef 写入编辑器保存的地图。
	var viewport := get_viewport()
	var owners: Dictionary = viewport.get_meta(&"play_toolbar_owners", {})
	var level_id := level.get_instance_id()
	if not owners.has(level_id):
		owners[level_id] = null
		viewport.set_meta(&"play_toolbar_owners", owners)
		level.tree_exiting.connect(func(): owners.erase(level_id), CONNECT_ONE_SHOT)
	var reference: WeakRef = owners[level_id]
	var previous: Node = reference.get_ref() if reference != null else null
	var locked: bool = previous != null and previous._toolbar_interacting()
	var candidates: Array = []
	for item in get_tree().get_nodes_in_group(&"canvas_workbench"):
		if item.get_parent() != level or not item.active or not item.is_visible_in_tree() \
		or item._map_editor_mode or item._screen_fixed or item._side_brush_slider == null:
			continue
		if item.player == null or (item == previous and locked) or item._distance_from_player_to_canvas() <= (item.toolbar_hide_distance if item == previous else item.toolbar_show_distance):
			candidates.append(item)
	var chosen: Node = null
	var best_score := INF
	var hovered_canvas: Node = null
	var mouse := get_viewport().get_mouse_position()
	for item in candidates:
		var local: Vector2 = item.get_global_transform_with_canvas().affine_inverse() * mouse
		if Rect2(Vector2.ZERO, Vector2(item.canvas_size)).has_point(local):
			hovered_canvas = item
		var score: float = item._toolbar_player_score()
		if score < best_score:
			best_score = score
			chosen = item
	if candidates.has(previous):
		var hovered := get_viewport().gui_get_hovered_control()
		var on_toolbar: bool = hovered != null and (previous.buttons.is_ancestor_of(hovered) \
			or previous._side_panel != null and previous._side_panel.is_ancestor_of(hovered) or hovered == previous.toggle_button)
		if locked or on_toolbar:
			chosen = previous
		elif hovered_canvas != null:
			chosen = hovered_canvas
		elif previous._toolbar_player_score() <= best_score + 40.0:
			chosen = previous
	elif hovered_canvas != null:
		chosen = hovered_canvas
	if chosen != previous and chosen != null:
		# 空档仍记住正在淡出的实例，下一块画布可接续其位置和透明度。
		owners[level_id] = weakref(chosen)
		if previous != null and chosen != null and not previous._map_editor_mode and not previous._screen_fixed:
			chosen._inherit_play_toolbar(previous)
	return chosen


func _toolbar_interacting() -> bool:
	return surface._painting or surface._shaping or surface._selecting or surface._selection_dragging \
		or surface._rod_drawing or surface._rail_drawing or surface.blue_layer.drawing \
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)


func _toolbar_player_score() -> float:
	if player == null:
		return 0.0
	var body = player.get("body")
	var player_position: Vector2 = get_parent().to_global(body.com_world()) if body != null else player.global_position
	return _distance_from_player_to_canvas() + global_position.distance_to(player_position) * 0.05


func _inherit_play_toolbar(previous: Node) -> void:
	var previous_layout := previous.get_node_or_null("SidePanelLayer")
	var layout := get_node_or_null("SidePanelLayer")
	if previous_layout != null and layout != null:
		layout.adopt_positions(previous_layout)
	_workbench_hidden = previous._workbench_hidden
	select_ink(previous.surface.selected_ink)
	set_brush_size(previous.surface.brush_size)
	_side_brush_slider.set_value_no_signal(previous.surface.brush_size)
	set_tool(previous.surface.tool)
	for pair in [[previous.buttons, buttons], [previous.toggle_button, toggle_button], [previous._side_panel, _side_panel]]:
		if pair[0] == null or pair[1] == null:
			continue
		pair[1].scale = pair[0].scale
		pair[1].modulate.a = pair[0].modulate.a
		var tween: Tween = pair[0].get_meta(&"toolbar_tween") if pair[0].has_meta(&"toolbar_tween") else null
		if tween != null:
			tween.kill()
		previous._set_toolbar_input(pair[0], false)
		pair[0].set_meta(&"toolbar_wanted", false)
		pair[0].hide()
	previous.surface.set_process_input(false)


func is_player_near_workbench() -> bool:
	return active and visible and not _map_editor_mode \
		and not _screen_fixed and _workbench_nearby


func _restore_hand_on_departure() -> void:
	# 相邻画布重叠时，离开其中一块不能打断另一块的绘制。
	var canvases := get_tree().get_nodes_in_group(&"canvas_workbench")
	for canvas in canvases:
		if canvas != self and canvas.get_parent() == get_parent() and canvas.active \
				and not canvas._map_editor_mode and canvas.visible \
				and canvas._distance_from_player_to_canvas() <= maxf(canvas.toolbar_show_distance, canvas.toolbar_hide_distance):
			return
	for canvas in canvases:
		if canvas.get_parent() == get_parent() and canvas.active and not canvas._map_editor_mode:
			canvas._temporary_eraser = false
			canvas.activate_hand_tool()


func _set_toolbar_input(control: Control, enabled: bool) -> void:
	if not enabled and not control.has_meta(&"toolbar_mouse_filter"):
		control.set_meta(&"toolbar_mouse_filter", control.mouse_filter)
	if enabled and control.has_meta(&"toolbar_mouse_filter"):
		control.mouse_filter = int(control.get_meta(&"toolbar_mouse_filter"))
		control.remove_meta(&"toolbar_mouse_filter")
	elif not enabled:
		control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if control is Button:
		if not enabled and not control.has_meta(&"toolbar_disabled"):
			control.set_meta(&"toolbar_disabled", control.disabled)
		if enabled and control.has_meta(&"toolbar_disabled"):
			control.disabled = bool(control.get_meta(&"toolbar_disabled"))
			control.remove_meta(&"toolbar_disabled")
		elif not enabled:
			control.disabled = true
	for child in control.get_children():
		if child is Control:
			_set_toolbar_input(child, enabled)


func _animate_toolbar(control: Control, show: bool) -> void:
	if control.has_meta(&"toolbar_wanted") and bool(control.get_meta(&"toolbar_wanted")) == show:
		return
	var first := not control.has_meta(&"toolbar_wanted")
	control.set_meta(&"toolbar_wanted", show)
	var old_tween: Tween = control.get_meta(&"toolbar_tween") if control.has_meta(&"toolbar_tween") else null
	if old_tween != null:
		old_tween.kill()
	_set_toolbar_input(control, show)
	control.pivot_offset = Vector2(control.size.x * 0.5, 0.0)
	if first or not active or _map_editor_mode or toolbar_transition_seconds <= 0.0:
		control.visible = show
		control.scale = Vector2.ONE if show else Vector2.ONE * 0.96
		control.modulate.a = 1.0 if show else 0.0
		return
	control.visible = true
	var tween := create_tween().set_parallel(true)
	control.set_meta(&"toolbar_tween", tween)
	tween.tween_property(control, "scale", Vector2.ONE if show else Vector2.ONE * 0.96,
		toolbar_transition_seconds).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(control, "modulate:a", 1.0 if show else 0.0, toolbar_transition_seconds)
	if not show:
		tween.chain().tween_callback(func(): control.visible = bool(control.get_meta(&"toolbar_wanted", false)))


func _set_workbench_visible(nearby: bool, owned := true) -> void:
	#⚠️ 隐藏按钮自己不受"手动隐藏"控制 —— 不然藏起来就再也点不回来了。
	_animate_toolbar(toggle_button, active and nearby)
	var show_buttons: bool = active and nearby and not _workbench_hidden
	brush_panel.visible = false
	resize_panel.visible = false
	_animate_toolbar(buttons, show_buttons)
	# 右侧色盘也要看归属：旁边更近的画布接手时，这块的色盘必须跟着走，
	# 否则两块画布的色盘会同时在场，看起来就是"右边多了一块一直在动的工具栏"。
	if _side_panel != null:
		_animate_toolbar(_side_panel, active and nearby and owned and not _map_editor_mode)


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
	for button in tool_grid.get_children() + [hand_button]:
		if button is Button:
			preload("res://ui/theme/src/button_appearance.gd").uniform(button, true)
			var feedback := Node.new()
			feedback.name = "IconFeedback"
			feedback.set_script(preload("res://actor/canvas/src/tool_icon_feedback.gd"))
			button.add_child(feedback)
	hand_button.pressed.connect(_on_hand_pressed)
	tool_grid.get_node("Brush").pressed.connect(set_tool.bind(SurfaceScript.Tool.BRUSH))
	tool_grid.get_node("Eraser").pressed.connect(set_tool.bind(SurfaceScript.Tool.ERASER))
	tool_grid.get_node("Shape").pressed.connect(_open_shape_popup)
	tool_grid.get_node("Nail").pressed.connect(set_tool.bind(SurfaceScript.Tool.NAIL))
	tool_grid.get_node("Bucket").pressed.connect(set_tool.bind(SurfaceScript.Tool.BUCKET))
	tool_grid.get_node("SelectDelete").pressed.connect(set_tool.bind(SurfaceScript.Tool.SELECT_DELETE))
	tool_grid.get_node("SelectDelete").gui_input.connect(_on_selection_button_input)
	tool_grid.get_node("Redraw").pressed.connect(clear_canvas)
	tool_grid.get_node("Generate").pressed.connect(generate)
	tool_grid.get_node("ReturnToCanvas").pressed.connect(return_to_canvas)
	tool_grid.get_node("ExpandCanvas").pressed.connect(_open_expand_canvas_window)
	resize_panel.get_node("Grid/NailVisibility").toggled.connect(_on_nail_visibility_toggled)
	toggle_button.pressed.connect(_toggle_workbench)
	brush_panel.get_node("PenSlider").value_changed.connect(_on_pen_slider_changed)


func _on_hand_pressed() -> void:
	set_tool(SurfaceScript.Tool.HAND)
	if _map_editor_mode:
		editor_control_requested.emit()


func _build_expand_canvas_window() -> void:
	# 窗口结构与尺寸预览在 `panel/src/expand_canvas_window.gd`；这里只接回调与状态。
	var built: Dictionary = ExpandWindow.build(self, EditorTheme,
		_update_expand_size_preview, _confirm_expand_canvas)
	_expand_canvas_window = built.window
	_expand_inputs = built.inputs
	_expand_size_preview = built.preview
	_update_expand_size_preview()


func _open_expand_canvas_window() -> void:
	if not _map_editor_mode or _expand_canvas_window == null:
		return
	ExpandWindow.reset(_expand_inputs)
	_update_expand_size_preview()
	_expand_canvas_window.popup_centered()


func _update_expand_size_preview() -> void:
	ExpandWindow.refresh_preview(_expand_size_preview, _expand_inputs, canvas_size)


func _confirm_expand_canvas() -> void:
	var delta := ExpandWindow.amounts(_expand_inputs)
	if delta == Vector4i.ZERO:
		return
	if expand_canvas_sides(delta.x, delta.y, delta.z, delta.w):
		_expand_canvas_window.hide()
## 隐藏 / 显示工具栏本体。按钮自己一直露着，好点回来。
func _toggle_workbench() -> void:
	_workbench_hidden = not _workbench_hidden
	toggle_button.text = "显示" if _workbench_hidden else "隐藏"
	_refresh_workbench_visibility()


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
var _selection_popup: PopupMenu
var _temporary_eraser := false


## 构建形状选择弹出菜单（矩形 / 圆形 / 直线）。
func _build_shape_popup() -> void:
	_shape_popup = ShapeMenu.build_shapes(self, _on_shape_picked, _on_shape_popup_hide)


## 左键沿用矩形框选；右键选择矩形或圆形，不占用额外工具栏位置。
func _build_selection_popup() -> void:
	_selection_popup = ShapeMenu.build_selection(self, _on_selection_picked)


func _on_selection_button_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		ShapeMenu.popup_at(_selection_popup, self)
		get_viewport().set_input_as_handled()


func _on_selection_picked(id: int) -> void:
	_apply_tool(id)


## 点击形状按钮时在鼠标位置弹出三个选项。
func _open_shape_popup() -> void:
	if _shape_popup == null:
		return
	# 打开菜单不代表已选择新形状，保留当前实际工具的选中状态。
	_apply_tool(surface.tool)
	ShapeMenu.popup_at(_shape_popup, self)


## 选中某个形状后切换工具并更新按钮提示。
func _on_shape_picked(id: int) -> void:
	if id not in [SurfaceScript.Tool.RECT, SurfaceScript.Tool.CIRCLE, SurfaceScript.Tool.LINE]:
		return
	_shape_tool = id
	_apply_tool(id)
	_update_shape_tooltip(id)


## 菜单关闭（未选择）时，按当前实际工具刷新按钮高亮，避免 Shape 按钮卡在 pressed。
func _on_shape_popup_hide() -> void:
	_apply_tool(surface.tool)


func _update_shape_tooltip(tool: int) -> void:
	tool_grid.get_node("Shape").tooltip_text = ToolbarActions.shape_tooltip(tool)


func _apply_tool(tool: int) -> void:
	if tool in [SurfaceScript.Tool.GEAR, SurfaceScript.Tool.GEAR_8, SurfaceScript.Tool.INFINITE_NAIL] \
			and not _map_editor_mode:
		return
	surface.tool = tool
	ToolbarActions.highlight(tool_grid, hand_button, tool)
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
@export var capture_path: String = "res://test/canvas_capture.snapshot"
## 大地图整图；存下来当参考图（没有节点读它）。
@export_file("*.png") var baked_map_path: String = "res://map/asset/baked_map.png"
## 开发用的 F5/F9 存读；创造模式接管 F5 时会被关掉，避免两套保存同时跑。
var dev_save_enabled := true


func _activate_tool_shortcut(keycode: int) -> bool:
	if keycode != KEY_0 and (keycode < KEY_1 or keycode > KEY_9):
		return false
	var index := 9 if keycode == KEY_0 else keycode - KEY_1
	if index < 0 or index >= TOOL_SHORTCUT_ORDER.size():
		return false
	var button := tool_grid.get_node(TOOL_SHORTCUT_ORDER[index]) as Button
	if not button.visible or button.disabled:
		return false
	button.get_node("IconFeedback").pulse()
	button.pressed.emit()
	return true


func _try_delete_selection_at(point: Vector2i) -> bool:
	if not surface.has_selection() or not surface._selection_contains(point):
		return false
	_delete_selection(surface.selection_rect(), surface.selection_mask())
	surface.clear_selected_area()
	return true


func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	var blueprints := get_node_or_null("/root/Blueprints")
	if blueprints != null and blueprints.blocks_world_event(event):
		return
	if not _map_editor_mode and (not _workbench_nearby or _choose_play_toolbar_owner() != self):
		return
	# 框选工具下，在选区内按右键直接删除；工具栏上的右键仍由弹出菜单处理。
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT \
	and event.pressed and surface.tool in [SurfaceScript.Tool.SELECT_DELETE, SurfaceScript.Tool.SELECT_CIRCLE]:
		if get_viewport().gui_get_hovered_control() == null \
		and _try_delete_selection_at(Vector2i(surface._mouse_point().floor())):
			get_viewport().set_input_as_handled()
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
		# 输入尺寸、文字或选择弹出菜单时，数字留给当前控件。
		var focus := get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit \
		or (_shape_popup != null and _shape_popup.visible) \
		or (_selection_popup != null and _selection_popup.visible) \
		or (_expand_canvas_window != null and _expand_canvas_window.visible):
			return
		if event.keycode == KEY_R and not event.ctrl_pressed and not event.alt_pressed and not event.meta_pressed \
		and surface.tool in [SurfaceScript.Tool.SELECT_DELETE, SurfaceScript.Tool.SELECT_CIRCLE] and surface.has_selection():
			_selection_rotation.apply(self)
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_BACKSPACE and surface.tool in [
			SurfaceScript.Tool.SELECT_DELETE, SurfaceScript.Tool.SELECT_CIRCLE] \
		and surface.has_selection():
			_delete_selection(surface.selection_rect(), surface.selection_mask())
			surface.clear_selected_area()
			get_viewport().set_input_as_handled()
			return
		if not _map_editor_mode and event.ctrl_pressed and event.keycode == KEY_Z:
			surface.undo_last_edit()
			get_viewport().set_input_as_handled()
			return
		if not _map_editor_mode and event.ctrl_pressed and event.keycode == KEY_Y:
			surface.redo_last_edit()
			get_viewport().set_input_as_handled()
			return
		if not event.ctrl_pressed and not event.alt_pressed and not event.meta_pressed \
		and not event.shift_pressed and _activate_tool_shortcut(event.keycode):
			get_viewport().set_input_as_handled()
			return
		# 地图扩展保留为快捷键，界面不再占一排方向按钮。
		if _map_editor_mode and event.ctrl_pressed:
			var expanded := true
			match event.keycode:
				KEY_LEFT:
					expand_canvas(Vector2i.LEFT)
				KEY_RIGHT:
					expand_canvas(Vector2i.RIGHT)
				KEY_UP:
					expand_canvas(Vector2i.UP)
				KEY_DOWN:
					expand_canvas(Vector2i.DOWN)
				_:
					expanded = false
			if expanded:
				get_viewport().set_input_as_handled()
				return
		match event.keycode:
			KEY_F:
				hand_button.get_node("IconFeedback").pulse()
				_on_hand_pressed()
			KEY_E:
				tool_grid.get_node("Generate/IconFeedback").pulse()
				generate()
	#保存/读取走输入动作，别和上面的裸键 match 串成一个分支。
	if dev_save_enabled and event.is_action_pressed("canvas_save"):
		surface.save_ink(capture_path)
		surface.save_png(baked_map_path)
	elif dev_save_enabled and event.is_action_pressed("canvas_load"):
		surface.load_ink(capture_path)
#endregion
