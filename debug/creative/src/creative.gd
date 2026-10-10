#创造模式（= 地图编辑模式）：F2 进/出。
#进去后本体没有碰撞、没有重力，WASD 直接改位置（上帝手感，不走惯性）；
#数字键 1/2/3/4 切画布工具；F5 先把画布固化，再把世界里的墨水物品导出成地图场景。

#region 依赖
extends Node

signal map_saved(path: String)

const HEALTH_UI_GROUP := &"health_ui"
const MONSTER_CONTAINER_NAME := &"Monsters"
const MONSTER_MODE_NONE := -1
const MONSTER_MODE_DELETE := -2
const MONSTER_MODE_ADJUST := -3
const MONSTER_SCALE_STEP := 0.1
const MONSTER_MIN_SCALE := 0.35
const MONSTER_MAX_SCALE := 2.5
const MapMonsterScript := preload("res://actor/monster/src/map_monster.gd")
const MONSTER_SCENES: Array[PackedScene] = [
	preload("res://actor/monster/shield_side.tscn"),
	preload("res://actor/monster/little_soldier.tscn"),
	preload("res://actor/monster/bomb_side.tscn"),
]
const MONSTER_KINDS := [
	MapMonsterScript.Kind.SHIELD_SIDE,
	MapMonsterScript.Kind.LITTLE_SOLDIER,
	MapMonsterScript.Kind.BOMB_SIDE,
]
const MONSTER_NAMES := ["大盾侧面", "小兵", "炸弹狂侧面"]
const MONSTER_NODE_NAMES := ["ShieldSide", "LittleSoldier", "BombSide"]
const EDITOR_THEME := preload("res://ui/theme/asset/ink_attack_theme.tres")
const MAX_EDIT_HISTORY := 128

@export var player_path: NodePath = ^"../Player"
## 普通模式的小画布；创造模式里让位给大地图。
@export var canvas_path: NodePath = ^"../SmallCanvas"
## 创造模式的大画布（铺满全图）；平时隐藏。
@export var map_canvas_path: NodePath = ^"../MapCanvas"
@export_file("*.tscn") var map_path: String = "res://map/asset/map.tscn"
## 保底 PNG：存关卡的同时存一张整图（黑=空、颜色=材质 id），现在只当参考图，没有节点读它。
@export_file("*.png") var baked_map_path: String = "res://map/asset/baked_map.png"
## 上帝位移速度，单位 px/s。
@export var fly_speed := 600.0
## 按住 Shift 的倍率。
@export var fast_multiplier := 3.0
#endregion


#region 状态
var active := false
var _player = null
var _body = null
var _canvas = null
var _map_canvas = null
var _saved_layer := 1
var _saved_mask := 0xFFFFFFFF
var _saved_gravity := 1.0
var _saved_player_visible := true
var _saved_health_ui_visibility := {}
var _monster_container: Node2D = null
var _monster_palette: CanvasLayer = null
var _monster_buttons: Array[Button] = []
var _delete_monster_button: Button = null
var _adjust_monster_button: Button = null
var _reset_monster_scale_button: Button = null
var _monster_status_label: Label = null
var _monster_mode := MONSTER_MODE_NONE
var _selected_monster: Node2D = null
var _dragging_monster := false
var _drag_offset := Vector2.ZERO
var _drag_start_position := Vector2.ZERO
var _drag_start_scale := Vector2.ONE
var _save_directory_dialog: FileDialog = null
var _syncing_canvas_tool := false
var _edit_history: Array[Dictionary] = []
var _next_monster_id := 1
#endregion


#region 生命周期
func _ready() -> void:
	process_physics_priority = 15      # 世界步进(10)之后、相机(20)之前
	set_physics_process(false)
	_player = get_node_or_null(player_path)
	_canvas = get_node_or_null(canvas_path)
	_map_canvas = get_node_or_null(map_canvas_path)
	if _map_canvas != null:
		_map_canvas.dev_save_enabled = false   # 大地图的 F5 只走导出
		if _map_canvas.has_signal("tool_changed"):
			_map_canvas.tool_changed.connect(_on_canvas_tool_changed)
		var surface: Node = _map_canvas.get_node_or_null("CanvasSurface")
		if surface != null and surface.has_signal("edit_committed"):
			surface.edit_committed.connect(_on_canvas_edit_committed)
	# 部分导入地图没有预置 Monsters；本节点的 _ready 仍处在父场景装配子节点阶段，
	# 此时 add_child 会失败。等一帧装配完成后再创建，放置函数本身也会在需要时重试。
	call_deferred("_prepare_monster_container")
	_build_monster_palette()
	_build_save_directory_dialog()
	_show_canvas(_map_canvas, false)


## 放置放在普通输入阶段处理，优先于地图画布的绘制/物件输入；
## 旧地图中某些旧节点会提前消费 unhandled 输入，导致看起来选择了大盾却无法落下。
func _input(event: InputEvent) -> void:
	if _handle_editor_input(event):
		get_viewport().set_input_as_handled()


## 保留 unhandled 入口，供直接运行旧关卡和自动测试使用。
func _unhandled_input(event: InputEvent) -> void:
	if _handle_editor_input(event):
		get_viewport().set_input_as_handled()


func _handle_editor_input(event: InputEvent) -> bool:
	if event.is_action_pressed("creative"):
		toggle()
		return true
	elif active and event is InputEventKey and event.pressed and not event.echo \
	and event.ctrl_pressed and event.keycode == KEY_Z:
		undo_last_edit()
		return true
	elif active and event.is_action_pressed("canvas_save"):
		export_map()
		return true
	elif active and _monster_mode == MONSTER_MODE_ADJUST \
	and event is InputEventMouseButton:
		return _handle_monster_adjust_button(event as InputEventMouseButton)
	elif active and _monster_mode == MONSTER_MODE_ADJUST \
	and event is InputEventMouseMotion:
		return _handle_monster_adjust_motion(event as InputEventMouseMotion)
	elif active and _monster_mode != MONSTER_MODE_NONE \
	and event is InputEventMouseButton \
	and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if get_viewport().gui_get_hovered_control() != null:
			return false
		var world_position: Vector2 = \
			get_viewport().get_canvas_transform().affine_inverse() * event.position
		if _monster_mode == MONSTER_MODE_DELETE:
			remove_monster_at(world_position)
		else:
			place_monster(_monster_mode, world_position)
		return true
	return false


func _event_world_position(event: InputEventMouse) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * event.position


func _handle_monster_adjust_button(event: InputEventMouseButton) -> bool:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not event.pressed or not is_instance_valid(_selected_monster):
			return false
		if get_viewport().gui_get_hovered_control() != null:
			return false
		var direction := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
		_resize_selected_monster(direction * MONSTER_SCALE_STEP)
		return true
	if event.button_index != MOUSE_BUTTON_LEFT:
		return false
	if event.pressed:
		if get_viewport().gui_get_hovered_control() != null:
			return false
		var monster := _find_monster_at(_event_world_position(event))
		_set_selected_monster(monster)
		if monster == null:
			return true
		_dragging_monster = true
		_drag_offset = monster.global_position - _event_world_position(event)
		_drag_start_position = monster.global_position
		_drag_start_scale = monster.scale
		return true
	if not _dragging_monster:
		return false
	_dragging_monster = false
	_record_monster_transform(_selected_monster, _drag_start_position, _drag_start_scale)
	return true


func _handle_monster_adjust_motion(event: InputEventMouseMotion) -> bool:
	if not _dragging_monster or not is_instance_valid(_selected_monster):
		return false
	_selected_monster.global_position = _event_world_position(event) + _drag_offset
	_update_monster_status()
	return true
#endregion


#region 开关
func toggle() -> void:
	set_active(not active)


func set_active(value: bool) -> void:
	if value == active:
		return
	active = value
	if active:
		_enter()
	else:
		_exit()


func _enter() -> void:
	if _player == null:
		push_error("Creative: 找不到 Player")
		return
	_body = _player.get("body")
	if _body == null:
		push_error("Creative: Player 还没烘焙出 body")
		return
	_saved_layer = _body.collision_layer
	_saved_mask = _body.collision_mask
	_saved_gravity = _body.gravity_scale
	_saved_player_visible = _player.visible
	_player.visible = false             # 保留物理体作为相机/飞行锚点，只隐藏角色视觉
	_hide_health_ui()
	_body.collision_layer = 0          # 不在任何层：碰不到任何东西
	_body.collision_mask = 0
	_body.gravity_scale = 0.0
	_body.linear_velocity = Vector2.ZERO
	_body.angular_velocity = 0.0
	_show_canvas(_canvas, false)
	_show_canvas(_map_canvas, true)
	# 地图编辑器有独立的屏幕固定工具栏和四向扩展按钮。
	if _map_canvas != null:
		_map_canvas.set_map_editor_mode(true)
	if _monster_palette != null:
		_monster_palette.visible = true
	_set_ink_free(true)
	if _player != null:
		var health = _player.get_node_or_null("InkHealth")
		if health != null:
			health.damage_enabled = false   # 创造模式不许掉血
	set_physics_process(true)
	print("CREATIVE on")


func _exit() -> void:
	set_physics_process(false)
	if _body != null:
		_body.collision_layer = _saved_layer
		_body.collision_mask = _saved_mask
		_body.gravity_scale = _saved_gravity
		_body.linear_velocity = Vector2.ZERO
		_body.angular_velocity = 0.0
		_body.awake = true
		_body.sleep_timer = 0.0
	_show_canvas(_map_canvas, false)
	_show_canvas(_canvas, true)
	if _map_canvas != null:
		_map_canvas.set_map_editor_mode(false)
	_monster_mode = MONSTER_MODE_NONE
	_set_selected_monster(null)
	_update_monster_buttons()
	if _monster_palette != null:
		_monster_palette.visible = false
	_set_ink_free(false)
	if _player != null:
		_player.visible = _saved_player_visible
		var health = _player.get_node_or_null("InkHealth")
		if health != null:
			health.damage_enabled = true
	_restore_health_ui()
	print("CREATIVE off")


#切换哪块画布在工作：可见 + 收不收输入。
func _show_canvas(canvas, on: bool) -> void:
	if canvas == null:
		return
	canvas.visible = on
	canvas.active = on


#创造模式画图不花墨水：两张画布都免账，免得切回去时账目错位。
func _set_ink_free(free: bool) -> void:
	for canvas in [_canvas, _map_canvas]:
		if canvas != null:
			canvas.set_ink_free(free)


## 地图编辑只隐藏血条、瓶身填充和墨水文字，右上角退出按钮仍可用。
func _hide_health_ui() -> void:
	_saved_health_ui_visibility.clear()
	for item in get_tree().get_nodes_in_group(HEALTH_UI_GROUP):
		if item is CanvasItem:
			_saved_health_ui_visibility[item] = item.visible
			item.visible = false


func _restore_health_ui() -> void:
	for item in _saved_health_ui_visibility:
		if is_instance_valid(item):
			item.visible = bool(_saved_health_ui_visibility[item])
	_saved_health_ui_visibility.clear()
#endregion


#region 小怪放置
func _build_monster_palette() -> void:
	if _monster_palette != null:
		return
	var layer := CanvasLayer.new()
	layer.name = "MonsterPalette"
	layer.layer = 10
	layer.visible = false
	add_child(layer)
	_monster_palette = layer

	var root := Control.new()
	root.name = "Root"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -224.0
	panel.offset_top = 16.0
	panel.offset_right = -16.0
	# 三种小怪 + 调整/删除/停止/提示，给完整按钮列保留足够高度。
	panel.offset_bottom = 590.0
	panel.theme = EDITOR_THEME
	panel.theme_type_variation = &"OverlayPanel"
	root.add_child(panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)
	var column := VBoxContainer.new()
	column.name = "VBox"
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	var title := Label.new()
	title.text = "小怪放置"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.theme_type_variation = &"TitleLabel"
	column.add_child(title)
	for index in MONSTER_NAMES.size():
		var button := Button.new()
		button.name = MONSTER_NODE_NAMES[index] + "Button"
		button.text = MONSTER_NAMES[index]
		button.tooltip_text = "选择后在地图上单击放置%s" % MONSTER_NAMES[index]
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(176.0, 38.0)
		button.pressed.connect(select_monster_tool.bind(MONSTER_KINDS[index]))
		column.add_child(button)
		_monster_buttons.append(button)

	_adjust_monster_button = Button.new()
	_adjust_monster_button.name = "AdjustMonsterButton"
	_adjust_monster_button.text = "调整小怪"
	_adjust_monster_button.tooltip_text = "单击选中，拖动调整位置；滚轮调整大小"
	_adjust_monster_button.toggle_mode = true
	_adjust_monster_button.focus_mode = Control.FOCUS_NONE
	_adjust_monster_button.custom_minimum_size = Vector2(176.0, 38.0)
	_adjust_monster_button.pressed.connect(select_monster_tool.bind(MONSTER_MODE_ADJUST))
	column.add_child(_adjust_monster_button)

	_reset_monster_scale_button = Button.new()
	_reset_monster_scale_button.name = "ResetMonsterScaleButton"
	_reset_monster_scale_button.text = "恢复原始大小"
	_reset_monster_scale_button.tooltip_text = "恢复当前选中小怪的原始大小"
	_reset_monster_scale_button.focus_mode = Control.FOCUS_NONE
	_reset_monster_scale_button.custom_minimum_size = Vector2(176.0, 34.0)
	_reset_monster_scale_button.pressed.connect(_reset_selected_monster_scale)
	column.add_child(_reset_monster_scale_button)

	_delete_monster_button = Button.new()
	_delete_monster_button.name = "DeleteMonsterButton"
	_delete_monster_button.text = "删除小怪"
	_delete_monster_button.tooltip_text = "选择后单击地图中的小怪进行删除"
	_delete_monster_button.toggle_mode = true
	_delete_monster_button.focus_mode = Control.FOCUS_NONE
	_delete_monster_button.custom_minimum_size = Vector2(176.0, 38.0)
	_delete_monster_button.pressed.connect(select_monster_tool.bind(MONSTER_MODE_DELETE))
	column.add_child(_delete_monster_button)

	var stop_button := Button.new()
	stop_button.name = "StopMonsterToolButton"
	stop_button.text = "停止放置"
	stop_button.focus_mode = Control.FOCUS_NONE
	stop_button.custom_minimum_size = Vector2(176.0, 34.0)
	stop_button.pressed.connect(select_monster_tool.bind(MONSTER_MODE_NONE))
	column.add_child(stop_button)

	_monster_status_label = Label.new()
	_monster_status_label.name = "MonsterStatus"
	_monster_status_label.text = "未选中小怪"
	_monster_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_monster_status_label)

	var hint := Label.new()
	hint.text = "放置：左键单击\n调整：拖动位置，滚轮缩放\nCtrl+Z 撤销绘图或小怪操作"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(hint)


func select_monster_tool(mode: int) -> void:
	if mode != MONSTER_MODE_NONE and mode != MONSTER_MODE_DELETE and mode != MONSTER_MODE_ADJUST \
	and not MONSTER_KINDS.has(mode):
		mode = MONSTER_MODE_NONE
	elif mode == _monster_mode:
		mode = MONSTER_MODE_NONE
	_monster_mode = mode
	if mode != MONSTER_MODE_NONE and _map_canvas != null:
		# 普通手不在画布上落笔；放怪期间用它避免一次单击同时画墨。
		_syncing_canvas_tool = true
		_map_canvas.set_tool(0)
		_syncing_canvas_tool = false
	if mode != MONSTER_MODE_ADJUST:
		_set_selected_monster(null)
	_update_monster_buttons()


func _update_monster_buttons() -> void:
	for index in _monster_buttons.size():
		_monster_buttons[index].set_pressed_no_signal(_monster_mode == MONSTER_KINDS[index])
	if _delete_monster_button != null:
		_delete_monster_button.set_pressed_no_signal(_monster_mode == MONSTER_MODE_DELETE)
	if _adjust_monster_button != null:
		_adjust_monster_button.set_pressed_no_signal(_monster_mode == MONSTER_MODE_ADJUST)
	if _reset_monster_scale_button != null:
		_reset_monster_scale_button.disabled = not is_instance_valid(_selected_monster)


func _on_canvas_tool_changed(_tool: int) -> void:
	if _syncing_canvas_tool or _monster_mode == MONSTER_MODE_NONE:
		return
	_monster_mode = MONSTER_MODE_NONE
	_update_monster_buttons()


func place_monster(
	kind: int,
	world_position: Vector2,
	record_undo := true,
	monster_id := "",
	monster_scale := Vector2.ONE
) -> Node2D:
	var scene_index := MONSTER_KINDS.find(kind)
	if scene_index < 0:
		return null
	var container := _ensure_monster_container()
	if container == null:
		return null
	var monster := MONSTER_SCENES[scene_index].instantiate() as Node2D
	if monster == null:
		return null
	monster.name = MONSTER_NODE_NAMES[scene_index]
	container.add_child(monster, true)
	monster.global_position = world_position
	monster.scale = monster_scale
	if monster_id.is_empty():
		monster_id = _new_monster_id()
	monster.set("editor_id", monster_id)
	var scene_root := _level_root()
	if scene_root != null:
		monster.owner = scene_root
	if record_undo:
		_record_edit({"type": &"monster_place", "id": monster_id})
	return monster


func remove_monster_at(world_position: Vector2) -> bool:
	var container := _ensure_monster_container()
	if container == null:
		return false
	var nearest := _find_monster_at(world_position)
	if nearest == null:
		return false
	var removed := {
		"type": &"monster_delete",
		"id": str(nearest.get("editor_id")),
		"kind": int(nearest.get("kind")),
		"position": nearest.global_position,
		"scale": nearest.scale,
	}
	if nearest == _selected_monster:
		_set_selected_monster(null)
	container.remove_child(nearest)
	nearest.queue_free()
	_record_edit(removed)
	return true


func _find_monster_at(world_position: Vector2) -> Node2D:
	var container := _ensure_monster_container()
	if container == null:
		return null
	var nearest: Node2D = null
	var nearest_distance := INF
	for child in container.get_children():
		if not child is Node2D or not child.is_in_group(MapMonsterScript.GROUP):
			continue
		var radius: float = float(child.get("editor_pick_radius")) * maxf(child.scale.x, child.scale.y)
		var distance: float = child.global_position.distance_to(world_position)
		if distance <= radius and distance < nearest_distance:
			nearest = child
			nearest_distance = distance
	return nearest


func _set_selected_monster(monster: Node2D) -> void:
	_selected_monster = monster if is_instance_valid(monster) else null
	_dragging_monster = false
	_update_monster_buttons()
	_update_monster_status()


func _update_monster_status() -> void:
	if _monster_status_label == null:
		return
	if not is_instance_valid(_selected_monster):
		_monster_status_label.text = "未选中小怪"
		return
	_monster_status_label.text = "%s  大小 ×%.1f" % [
		str(_selected_monster.get("display_name")), _selected_monster.scale.x
	]


func _resize_selected_monster(amount: float) -> void:
	if not is_instance_valid(_selected_monster):
		return
	var old_position := _selected_monster.global_position
	var old_scale := _selected_monster.scale
	var next_scale := clampf(old_scale.x + amount, MONSTER_MIN_SCALE, MONSTER_MAX_SCALE)
	_selected_monster.scale = Vector2.ONE * next_scale
	_record_monster_transform(_selected_monster, old_position, old_scale)


func _reset_selected_monster_scale() -> void:
	if not is_instance_valid(_selected_monster):
		return
	var old_position := _selected_monster.global_position
	var old_scale := _selected_monster.scale
	_selected_monster.scale = Vector2.ONE
	_record_monster_transform(_selected_monster, old_position, old_scale)


func _record_monster_transform(monster: Node2D, old_position: Vector2, old_scale: Vector2) -> void:
	if not is_instance_valid(monster):
		return
	if monster.global_position.is_equal_approx(old_position) and monster.scale.is_equal_approx(old_scale):
		return
	_record_edit({
		"type": &"monster_transform",
		"id": str(monster.get("editor_id")),
		"old_position": old_position,
		"old_scale": old_scale,
		"new_position": monster.global_position,
		"new_scale": monster.scale,
	})
	_update_monster_status()


func monster_count() -> int:
	var container := _ensure_monster_container()
	return container.get_child_count() if container != null else 0


func _on_canvas_edit_committed() -> void:
	if active:
		_record_edit({"type": &"canvas"})


func _record_edit(edit: Dictionary) -> void:
	_edit_history.append(edit)
	if _edit_history.size() > MAX_EDIT_HISTORY:
		_edit_history.pop_front()


## 按绘图与小怪编辑发生的实际顺序撤销，供 Ctrl+Z 和自动测试调用。
func undo_last_edit() -> bool:
	if _edit_history.is_empty():
		return false
	var edit: Dictionary = _edit_history.pop_back()
	match edit.get("type", &""):
		&"canvas":
			var surface: Node = _map_canvas.get_node_or_null("CanvasSurface") if _map_canvas != null else null
			return surface != null and surface.undo_last_edit()
		&"monster_place":
			return _remove_monster_by_id(str(edit.get("id", "")))
		&"monster_delete":
			return place_monster(
				int(edit.get("kind", -1)),
				edit.get("position", Vector2.ZERO),
				false,
				str(edit.get("id", "")),
				edit.get("scale", Vector2.ONE)
			) != null
		&"monster_transform":
			return _apply_monster_transform(
				str(edit.get("id", "")),
				edit.get("old_position", Vector2.ZERO),
				edit.get("old_scale", Vector2.ONE)
			)
	return false


func _remove_monster_by_id(monster_id: String) -> bool:
	var container := _ensure_monster_container()
	if container == null or monster_id.is_empty():
		return false
	for child in container.get_children():
		if str(child.get("editor_id")) != monster_id:
			continue
		container.remove_child(child)
		child.queue_free()
		return true
	return false


func _apply_monster_transform(monster_id: String, position: Vector2, scale: Vector2) -> bool:
	var container := _ensure_monster_container()
	if container == null or monster_id.is_empty():
		return false
	for child in container.get_children():
		if not child is Node2D or str(child.get("editor_id")) != monster_id:
			continue
		child.global_position = position
		child.scale = scale
		_update_monster_status()
		return true
	return false


func _new_monster_id() -> String:
	var result := "monster-%d-%d" % [Time.get_ticks_usec(), _next_monster_id]
	_next_monster_id += 1
	return result


func _assign_missing_monster_ids() -> void:
	var container := _ensure_monster_container()
	if container == null:
		return
	for child in container.get_children():
		if child.is_in_group(MapMonsterScript.GROUP) and str(child.get("editor_id")).is_empty():
			child.set("editor_id", _new_monster_id())


func _prepare_monster_container() -> void:
	_monster_container = _ensure_monster_container()
	_assign_missing_monster_ids()


func _ensure_monster_container() -> Node2D:
	if is_instance_valid(_monster_container):
		return _monster_container
	var scene_root := _level_root()
	if scene_root == null:
		return null
	var existing := scene_root.get_node_or_null(NodePath(MONSTER_CONTAINER_NAME)) as Node2D
	if existing != null:
		_monster_container = existing
		return existing
	var container := Node2D.new()
	container.name = MONSTER_CONTAINER_NAME
	scene_root.add_child(container)
	# add_child 在父节点仍在装配时会被 Godot 拒绝。绝不能缓存这个游离节点，
	# 否则后续放置会“成功”却不在地图树中显示或保存。
	if container.get_parent() != scene_root:
		container.queue_free()
		return null
	container.owner = scene_root
	_monster_container = container
	return container
#endregion


#region 上帝位移
func _physics_process(delta: float) -> void:
	if _map_canvas != null:
		_map_canvas.clear_solidified_bodies_outside_canvas()
	if _body == null:
		return
	var direction := Input.get_vector("fly_left", "fly_right", "fly_up", "fly_down")
	if direction != Vector2.ZERO and Input.is_key_pressed(KEY_SHIFT):
		direction *= fast_multiplier
	#⚠️ 直接**设速度**而不是瞬移位置。起步/停止仍然是瞬时的（没有惯性手感），
	#   但位移交给物理积分 —— 挂在本体上的手臂关节才有连续的锚点可跟。
	#   瞬移会把锚点一下子拉开，求解器为了追上会把轻手臂抽到几万 px/s（实测 331 子步/帧）。
	_body.linear_velocity = direction * fly_speed
	_body.angular_velocity = 0.0
	_body.awake = true
	_body.sleep_timer = 0.0
#endregion


#region 导出地图
## 把**整个关卡**存成一个场景：PixelWorld + 玩家 + 画布 + 全部墨水 + 地形/HUD 都在里面。
## 存出来的是和 main.tscn **平级**的关卡 —— 能单独打开、也能当主场景跑。
func export_map() -> Error:
	_request_map_save_directory()
	return OK


## F5 先询问目录，避免所有地图都悄悄覆盖默认的 map.tscn。
## 使用资源目录选择器，保证导出的场景可以继续引用项目内的角色、画布和物理资源，
## 并能被关卡选择页的 res://map 扫描到。
func _build_save_directory_dialog() -> void:
	if _save_directory_dialog != null:
		return
	var dialog := FileDialog.new()
	dialog.name = "SaveMapDirectoryDialog"
	dialog.title = "选择地图保存文件夹"
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access = FileDialog.ACCESS_RESOURCES
	dialog.current_dir = map_path.get_base_dir()
	dialog.dir_selected.connect(_save_map_in_directory)
	add_child(dialog)
	_save_directory_dialog = dialog


func _request_map_save_directory() -> void:
	if _save_directory_dialog == null:
		_build_save_directory_dialog()
	if _save_directory_dialog == null:
		push_error("Creative: 无法打开地图保存目录选择器")
		return
	_save_directory_dialog.current_dir = map_path.get_base_dir()
	_save_directory_dialog.popup_centered_ratio(0.72)


func _save_map_in_directory(directory: String) -> void:
	var stamp := Time.get_datetime_string_from_system().replace("T", "_").replace(":", "-")
	var scene_path := directory.path_join("map_%s.tscn" % stamp)
	var preview_path := directory.path_join("map_%s.png" % stamp)
	map_path = scene_path
	baked_map_path = preview_path
	var error := export_map_to(scene_path)
	if error == OK:
		print("MAP saved after choosing folder: %s" % ProjectSettings.globalize_path(scene_path))


## 保存入口始终写出可直接运行的 `.tscn`。prepare_canvas=false 仅供自动测试或只打包当前状态使用。
func export_map_to(save_path: String, prepare_canvas := true) -> Error:
	var scene := _level_root()
	if scene == null:
		push_error("Creative: 找不到关卡根")
		return ERR_DOES_NOT_EXIST
	save_path = _normalize_scene_path(save_path)
	if save_path.is_empty():
		push_error("Creative: 场景保存路径为空")
		return ERR_INVALID_PARAMETER
	if prepare_canvas and _map_canvas != null:
		_map_canvas.generate()       # 先把画布上剩的墨水固化，一个像素都不丢
		var bake_error: Error = _map_canvas.bake_png(baked_map_path)
		if bake_error != OK:
			push_error("Map preview save failed: %s (%d)" % [baked_map_path, bake_error])
			return bake_error
	_sync_node_transforms(scene)
	var packed := PackedScene.new()
	var error := _pack_as_playable_scene(packed, scene)
	if error == OK:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(save_path).get_base_dir())
		error = ResourceSaver.save(packed, save_path)
	if error == OK:
		print("MAP scene saved: %s" % ProjectSettings.globalize_path(save_path))
		map_saved.emit(save_path)
	else:
		push_error("Map scene save failed: %s (%d)" % [save_path, error])
	return error


func _normalize_scene_path(path: String) -> String:
	path = path.strip_edges()
	if path.is_empty():
		return ""
	if path.get_extension().to_lower() == "tscn":
		return path
	if path.get_extension().is_empty():
		return path + ".tscn"
	return path.get_basename() + ".tscn"


## 编辑中角色、普通画布和工具栏的状态不应被写进关卡。
## 打包瞬间恢复正常游玩布局，pack 完成后立刻回到编辑布局。
func _pack_as_playable_scene(packed: PackedScene, scene: Node) -> Error:
	var player_visible: bool = _player.visible if _player != null else true
	var small_visible: bool = _canvas.visible if _canvas != null else false
	var small_active: bool = _canvas.active if _canvas != null else false
	var map_visible: bool = _map_canvas.visible if _map_canvas != null else false
	var map_active: bool = _map_canvas.active if _map_canvas != null else false
	if _map_canvas != null:
		_map_canvas.set_map_editor_mode(false)
	if _player != null:
		_player.visible = _saved_player_visible
	_show_canvas(_canvas, true)
	_show_canvas(_map_canvas, false)
	var error: Error = packed.pack(scene)
	if _canvas != null:
		_canvas.visible = small_visible
		_canvas.active = small_active
	if _map_canvas != null:
		_map_canvas.visible = map_visible
		_map_canvas.active = map_active
	if _player != null:
		_player.visible = player_visible
	if _map_canvas != null and active:
		_map_canvas.set_map_editor_mode(true)
	return error


## 要存的关卡根 = 装着画布的那个节点。
## ⚠️ 别用 `get_tree().current_scene`：主场景是 `root/root.tscn` 的 Root 容器，
##    关卡和 UI 都是它 `_ready()` 里运行时 add_child 挂上去的（owner 为空），
##    `PackedScene.pack()` 只收 owner 指回根的节点 —— 存出来会是一个 314 字节的空壳。
##    直接跑关卡场景（F6）时，画布的父节点正好就是关卡根，这条规则两种情况都对。
func _level_root() -> Node:
	if _map_canvas != null:
		return _map_canvas.get_parent()
	return get_tree().current_scene


## 把每个像素刚体的 PBody 位形写回它的节点。
## ⚠️ 节点自己不跟物理走（每帧跟的是视觉精灵），不写回去就会把玩家存回出生点。
func _sync_node_transforms(root: Node) -> void:
	for node in root.find_children("*", "", true, false):
		if not node.has_method("bake"):
			continue
		var body = node.get("body")
		if body == null:
			continue
		node.position = body.position
		node.rotation = body.rotation
#endregion
