#创造模式（= 地图编辑模式）：F2 进/出。
#进去后本体没有碰撞、没有重力，WASD 直接改位置（上帝手感，不走惯性）；
#数字键 1/2/3/4 切画布工具；F5 先把画布固化，再把世界里的墨水物品导出成地图场景。

#region 依赖
extends Node

signal map_saved(path: String)

const HEALTH_UI_GROUP := &"health_ui"
const MONSTER_CONTAINER_NAME := &"Monsters"
const PLAYER_SPAWN_NAME := &"PlayerSpawn"
const MONSTER_MODE_NONE := -1
const MONSTER_MODE_DELETE := -2
const MONSTER_MODE_ADJUST := -3
const DIALOGUE_MODE_PLACE := -4
const DIALOGUE_MODE_DELETE := -5
const TEXT_MODE_PLACE := -6
const TEXT_MODE_DELETE := -7
const MONSTER_SCALE_STEP := 0.1
const MONSTER_MIN_SCALE := 0.35
const MONSTER_MAX_SCALE := 2.5
const MapMonsterScript := preload("res://actor/monster/src/map_monster.gd")
const DialogueTriggerScript := preload("res://debug/creative/src/dialogue_trigger.gd")
const MapTextScript := preload("res://ui/map_text/map_text_label.gd")
const MAP_TEXT_FONT_PATH := "res://ui/map_text/asset/Muyao-Softbrush.ttf"
const MONSTER_SCENES: Array[PackedScene] = [
	preload("res://actor/monster/bomb_side.tscn"),
]
const MONSTER_KINDS := [
	MapMonsterScript.Kind.BOMB_SIDE,
]
const MONSTER_NAMES := ["炸弹狂侧面"]
const MONSTER_NODE_NAMES := ["BombSide"]
const EDITOR_THEME := preload("res://ui/theme/asset/ink_attack_theme.tres")
const MAX_EDIT_HISTORY := 128

@export var player_path: NodePath = ^"../Player"
## 普通模式的小画布；创造模式里让位给大地图。
@export var canvas_path: NodePath = ^"../SmallCanvas"
## 创造模式的大画布（铺满全图）；平时隐藏。
@export var map_canvas_path: NodePath = ^"../MapCanvas"
@export_file("*.tscn") var map_path: String = "res://map/1（终极版）.tscn"
## 保底 PNG：存关卡的同时存一张整图（黑=空、颜色=材质 id），现在只当参考图，没有节点读它。
@export_file("*.png") var baked_map_path: String = "res://map/asset/baked_map.png"
## 自动保存的未固化画布像素；路径存放在关卡本体，避免实例子节点属性被场景打包忽略。
@export_file("*.snapshot", "*.png", "*.res", "*.tres") var edit_snapshot_path := ""
## F2 退出编辑器时覆盖保存当前地图；自动测试可关闭它来避免重复打包超大地图。
@export var auto_save_on_exit := true
## 每次完成绘图、小怪编辑或撤销后，覆盖保存当前地图。
@export var auto_save_edits := true
@export_range(0.05, 2.0, 0.05) var auto_save_delay := 0.3
## 掉出画布的固化实体无需每个物理帧扫描；低频批处理可显著降低大地图开销。
@export_range(0.1, 2.0, 0.05) var outside_cleanup_interval := 0.35
## 上帝位移速度，单位 px/s。
@export var fly_speed := 600.0
## 按住 Shift 的倍率。
@export var fast_multiplier := 3.0
#endregion


#region 状态
var active := false
var _player = null
var _body = null
var _spawn_point: Marker2D = null
var _canvas = null
var _map_canvas = null
var _saved_layer := 1
var _saved_mask := 0xFFFFFFFF
var _saved_gravity := 1.0
var _saved_player_visible := true
var _saved_health_ui_visibility := {}
var _monster_container: Node2D = null
var _monster_palette: CanvasLayer = null
var _monster_palette_panel: PanelContainer = null
var _monster_palette_toggle: Button = null
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
var _map_save_window: PopupPanel = null
var _save_name_input: LineEdit = null
var _save_directory_input: LineEdit = null
var _save_preview: TextureRect = null
var _skip_restore_on_enter := false
var _auto_save_revision := 0
var _syncing_canvas_tool := false
var _edit_history: Array[Dictionary] = []
var _next_monster_id := 1
var _dialogue_container: Node2D = null
var _place_dialogue_button: Button = null
var _delete_dialogue_button: Button = null
var _dialogue_window: Window = null
var _dialogue_lines_box: VBoxContainer = null
var _dialogue_input_status: Label = null
var _pending_dialogue_position := Vector2.ZERO
var _next_dialogue_id := 1
var _text_container: Node2D = null
var _place_text_button: Button = null
var _delete_text_button: Button = null
var _text_window: Window = null
var _text_input: TextEdit = null
var _text_input_status: Label = null
var _pending_text_position := Vector2.ZERO
var _next_text_id := 1
var _editor_ui_ready := false
var _edit_snapshot_loaded := false
var _map_text_font: Font = null
var _outside_cleanup_elapsed := 0.0
var _map_reload_in_progress := false
#endregion


#region 生命周期
func _ready() -> void:
	process_physics_priority = 15      # 世界步进(10)之后、相机(20)之前
	set_physics_process(false)
	_player = get_node_or_null(player_path)
	_canvas = get_node_or_null(canvas_path)
	_map_canvas = get_node_or_null(map_canvas_path)
	_bind_paths_to_current_level()
	if _map_canvas != null:
		_map_canvas.dev_save_enabled = false   # 大地图的 F5 只走导出
		if _map_canvas.has_signal("tool_changed"):
			_map_canvas.tool_changed.connect(_on_canvas_tool_changed)
		var surface: Node = _map_canvas.get_node_or_null("CanvasSurface")
		if surface != null and surface.has_signal("edit_committed"):
			surface.edit_committed.connect(_on_canvas_edit_committed)
		if _map_canvas.has_signal("map_changed"):
			_map_canvas.map_changed.connect(_on_map_changed)
	# 游戏启动时不读取十几 MB 的编辑快照，也不创建地图编辑专用窗口和字体。
	# 这些资源只在首次进入地图编辑器时按需初始化。
	_show_canvas(_map_canvas, false)


## 当前正在运行的关卡文件才是编辑器的基底。
## 部分导入地图没有覆写 Creative.map_path，若沿用默认值，F2 会错误重载为默认第一关。
## 快照也按关卡文件名隔离，避免 A 地图读到 B 地图尚未固化的画布内容。
func _bind_paths_to_current_level() -> void:
	var level := _level_root()
	if level == null:
		return
	var current_path := str(level.scene_file_path)
	if current_path.is_empty() or current_path.get_extension().to_lower() != "tscn":
		return
	map_path = current_path
	baked_map_path = current_path.get_basename() + ".png"
	var native_snapshot := current_path.get_basename() + ".edit.snapshot"
	var png_snapshot := current_path.get_basename() + ".edit.png"
	var legacy_snapshot := current_path.get_basename() + ".edit.res"
	if FileAccess.file_exists(native_snapshot):
		edit_snapshot_path = native_snapshot
	elif FileAccess.file_exists(png_snapshot):
		edit_snapshot_path = png_snapshot
	elif FileAccess.file_exists(legacy_snapshot):
		edit_snapshot_path = legacy_snapshot
	else:
		edit_snapshot_path = ""


## 放置放在普通输入阶段处理，优先于地图画布的绘制/物件输入；
## 旧地图中某些旧节点会提前消费 unhandled 输入，导致看起来选择了大盾却无法落下。
func _input(event: InputEvent) -> void:
	# F2 进入编辑器时可能在本次输入处理中立刻替换整个关卡。
	# 先保留当前 Viewport，避免旧 Creative 节点脱离场景树后 get_viewport() 返回 null。
	var viewport := get_viewport()
	if _handle_editor_input(event):
		if is_instance_valid(viewport):
			viewport.set_input_as_handled()


## 保留 unhandled 入口，供直接运行旧关卡和自动测试使用。
func _unhandled_input(event: InputEvent) -> void:
	var viewport := get_viewport()
	if _handle_editor_input(event):
		if is_instance_valid(viewport):
			viewport.set_input_as_handled()


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
		elif _monster_mode == DIALOGUE_MODE_PLACE:
			_open_dialogue_input(world_position)
		elif _monster_mode == DIALOGUE_MODE_DELETE:
			remove_dialogue_trigger_at(world_position)
		elif _monster_mode == TEXT_MODE_PLACE:
			_open_text_input(world_position)
		elif _monster_mode == TEXT_MODE_DELETE:
			remove_map_text_at(world_position)
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
	# 从游玩态进编辑器时，运行中的破坏/碎片不能带进来。通过 Root 换成上次
	# F2 退出时覆盖保存的关卡实例，再由新实例进入编辑态。
	if not _skip_restore_on_enter and _reload_saved_map_for_editor():
		return
	_skip_restore_on_enter = false
	_ensure_editor_resources()
	_load_edit_snapshot_if_needed()
	if _player == null:
		push_error("Creative: 找不到 Player")
		return
	_body = _player.get("body")
	if _body == null:
		push_error("Creative: Player 还没烘焙出 body")
		return
	# 编辑模式也从正式出生点开始，避免沿用游玩时被推走/摔落后的位置。
	_reset_player_to_spawn()
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
	var canvas := get_node_or_null(canvas_path)
	_show_canvas(_canvas, false)
	_show_canvas(_map_canvas, true)
	# 地图编辑器有独立的屏幕固定工具栏和四向扩展按钮。
	if _map_canvas != null:
		_map_canvas.set_map_editor_mode(true)
	if _monster_palette != null:
		_monster_palette.visible = true
	_refresh_dialogue_trigger_visuals()
	_set_ink_free(true)
	if _player != null:
		var health = _player.get_node_or_null("InkHealth")
		if health != null:
			health.damage_enabled = false   # 创造模式不许掉血
	set_physics_process(true)
	print("CREATIVE on")


## 将游戏态完全不需要的编辑器 UI、容器和大字体延迟到第一次 F2。
func _ensure_editor_resources() -> void:
	if _editor_ui_ready:
		return
	_prepare_monster_container()
	_build_monster_palette()
	_build_dialogue_input_window()
	_build_text_input_window()
	_build_save_directory_dialog()
	_build_map_save_window()
	_ensure_spawn_point()
	_editor_ui_ready = true


func _load_edit_snapshot_if_needed() -> void:
	if _edit_snapshot_loaded or edit_snapshot_path.is_empty() or _map_canvas == null:
		return
	var surface: Node = _map_canvas.get_node_or_null("CanvasSurface")
	if surface == null or not surface.has_method("load_ink"):
		return
	if surface.load_ink(edit_snapshot_path) == OK:
		surface.saved_ink_path = edit_snapshot_path
		_edit_snapshot_loaded = true


func _exit() -> void:
	set_physics_process(false)
	_cancel_dialogue_input()
	_cancel_text_input()
	if _body != null:
		_body.collision_layer = _saved_layer
		_body.collision_mask = _saved_mask
		_body.gravity_scale = _saved_gravity
		_body.linear_velocity = Vector2.ZERO
		_body.angular_velocity = 0.0
		_body.awake = true
		_body.sleep_timer = 0.0
	_reset_player_to_spawn()
	# 玩家复位后再覆盖地图，编辑器中的飞行位置绝不能成为下一次出生位置。
	if auto_save_on_exit:
		_save_current_map_overwrite()
	_show_canvas(_map_canvas, false)
	_show_canvas(_canvas, true)
	if _map_canvas != null:
		_map_canvas.set_map_editor_mode(false)
	if _canvas != null and _canvas.has_method("activate_hand_tool"):
		_canvas.activate_hand_tool()
	_monster_mode = MONSTER_MODE_NONE
	_set_selected_monster(null)
	_update_monster_buttons()
	if _monster_palette != null:
		_monster_palette.visible = false
	_refresh_dialogue_trigger_visuals()
	_set_ink_free(false)
	if _player != null:
		_player.visible = _saved_player_visible
		var health = _player.get_node_or_null("InkHealth")
		if health != null:
			health.damage_enabled = true
	_restore_health_ui()
	print("CREATIVE off")


## 旧地图没有出生点时补建一个持久化标记；已有标记也始终校准到
## 游玩模式可绘画画布的中心。
func _ensure_spawn_point() -> Marker2D:
	if is_instance_valid(_spawn_point):
		_center_spawn_on_play_canvas(_spawn_point)
		return _spawn_point
	var level := _level_root()
	if level == null:
		return null
	_spawn_point = level.get_node_or_null(NodePath(String(PLAYER_SPAWN_NAME))) as Marker2D
	if _spawn_point != null:
		_center_spawn_on_play_canvas(_spawn_point)
		return _spawn_point
	_spawn_point = Marker2D.new()
	_spawn_point.name = PLAYER_SPAWN_NAME
	level.add_child(_spawn_point)
	_center_spawn_on_play_canvas(_spawn_point)
	_spawn_point.owner = level
	return _spawn_point


func _center_spawn_on_play_canvas(spawn: Marker2D) -> void:
	if spawn == null:
		return
	if _canvas != null:
		var canvas_center: Vector2 = _canvas.to_global(Vector2(_canvas.canvas_size) * 0.5)
		var player_body = _body if _body != null else (_player.get("body") if _player != null else null)
		var local_bounds := Rect2()
		var has_bounds := false
		if player_body != null:
			for shape in player_body.shapes:
				var shape_rect := Rect2(shape.local_aabb())
				local_bounds = local_bounds.merge(shape_rect) if has_bounds else shape_rect
				has_bounds = true
		spawn.global_position = canvas_center - (local_bounds.get_center() if has_bounds else Vector2.ZERO)
	else:
		spawn.global_position = _player.global_position if _player != null else Vector2.ZERO
	spawn.global_rotation = 0.0


func _reset_player_to_spawn() -> void:
	var spawn := _ensure_spawn_point()
	if spawn == null or _player == null or _body == null:
		return
	_player.global_position = spawn.global_position
	_player.global_rotation = spawn.global_rotation
	_body.position = spawn.global_position
	_body.rotation = spawn.global_rotation
	_body.linear_velocity = Vector2.ZERO
	_body.angular_velocity = 0.0
	_body.control_force = Vector2.ZERO
	_body.control_torque = 0.0
	_body.refresh_com()
	_body.update_aabb()
	var hand: Node = _player.get_node_or_null(^"Arm/Hand/HandControl")
	if hand != null and hand.has_method("reset_after_player_teleport"):
		hand.reset_after_player_teleport()


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

	var palette_toggle := Button.new()
	palette_toggle.name = "PaletteToggle"
	palette_toggle.anchor_left = 1.0
	palette_toggle.anchor_right = 1.0
	palette_toggle.offset_left = -424.0
	# 避开右上角现有的日志、ESC 等按钮。
	palette_toggle.offset_top = 80.0
	palette_toggle.offset_right = -352.0
	palette_toggle.offset_bottom = 124.0
	palette_toggle.text = "收起"
	palette_toggle.tooltip_text = "收起 / 展开右侧地图编辑工具栏"
	palette_toggle.focus_mode = Control.FOCUS_NONE
	palette_toggle.theme = EDITOR_THEME
	palette_toggle.pressed.connect(_toggle_monster_palette_panel)
	root.add_child(palette_toggle)
	_monster_palette_toggle = palette_toggle

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -344.0
	panel.offset_top = 16.0
	panel.offset_right = -16.0
	# 三列紧凑排布，并始终贴合视口底部，避免按钮落到地面/窗口外。
	panel.offset_bottom = -16.0
	panel.theme = EDITOR_THEME
	panel.theme_type_variation = &"OverlayPanel"
	root.add_child(panel)
	_monster_palette_panel = panel

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
	var monster_grid := GridContainer.new()
	monster_grid.name = "MonsterGrid"
	monster_grid.columns = 3
	monster_grid.add_theme_constant_override("h_separation", 6)
	monster_grid.add_theme_constant_override("v_separation", 6)
	column.add_child(monster_grid)
	for index in MONSTER_NAMES.size():
		# 炸弹狂侧面保留给旧地图加载与撤销恢复，但不再提供新放置入口。
		if MONSTER_KINDS[index] == MapMonsterScript.Kind.BOMB_SIDE:
			continue
		var button := Button.new()
		button.name = MONSTER_NODE_NAMES[index] + "Button"
		button.text = MONSTER_NAMES[index]
		button.tooltip_text = "选择后在地图上单击放置%s" % MONSTER_NAMES[index]
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(96.0, 44.0)
		button.pressed.connect(select_monster_tool.bind(MONSTER_KINDS[index]))
		monster_grid.add_child(button)
		_monster_buttons.append(button)

	_adjust_monster_button = Button.new()
	_adjust_monster_button.name = "AdjustMonsterButton"
	_adjust_monster_button.text = "调整小怪"
	_adjust_monster_button.tooltip_text = "单击选中，拖动调整位置；滚轮调整大小"
	_adjust_monster_button.toggle_mode = true
	_adjust_monster_button.focus_mode = Control.FOCUS_NONE
	_adjust_monster_button.custom_minimum_size = Vector2(96.0, 44.0)
	_adjust_monster_button.pressed.connect(select_monster_tool.bind(MONSTER_MODE_ADJUST))
	monster_grid.add_child(_adjust_monster_button)

	_reset_monster_scale_button = Button.new()
	_reset_monster_scale_button.name = "ResetMonsterScaleButton"
	_reset_monster_scale_button.text = "恢复原始大小"
	_reset_monster_scale_button.tooltip_text = "恢复当前选中小怪的原始大小"
	_reset_monster_scale_button.focus_mode = Control.FOCUS_NONE
	_reset_monster_scale_button.custom_minimum_size = Vector2(96.0, 44.0)
	_reset_monster_scale_button.pressed.connect(_reset_selected_monster_scale)
	monster_grid.add_child(_reset_monster_scale_button)

	_delete_monster_button = Button.new()
	_delete_monster_button.name = "DeleteMonsterButton"
	_delete_monster_button.text = "删除小怪"
	_delete_monster_button.tooltip_text = "选择后单击地图中的小怪进行删除"
	_delete_monster_button.toggle_mode = true
	_delete_monster_button.focus_mode = Control.FOCUS_NONE
	_delete_monster_button.custom_minimum_size = Vector2(96.0, 44.0)
	_delete_monster_button.pressed.connect(select_monster_tool.bind(MONSTER_MODE_DELETE))
	monster_grid.add_child(_delete_monster_button)

	var separator := HSeparator.new()
	column.add_child(separator)
	var dialogue_title := Label.new()
	dialogue_title.text = "对话触发点"
	dialogue_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dialogue_title.theme_type_variation = &"TitleLabel"
	column.add_child(dialogue_title)
	var dialogue_grid := GridContainer.new()
	dialogue_grid.name = "DialogueGrid"
	dialogue_grid.columns = 3
	dialogue_grid.add_theme_constant_override("h_separation", 6)
	dialogue_grid.add_theme_constant_override("v_separation", 6)
	column.add_child(dialogue_grid)

	_place_dialogue_button = Button.new()
	_place_dialogue_button.name = "PlaceDialogueTriggerButton"
	_place_dialogue_button.text = "放置对话点"
	_place_dialogue_button.tooltip_text = "选择后单击地图，输入按顺序播放的多句文案"
	_place_dialogue_button.toggle_mode = true
	_place_dialogue_button.focus_mode = Control.FOCUS_NONE
	_place_dialogue_button.custom_minimum_size = Vector2(96.0, 44.0)
	_place_dialogue_button.pressed.connect(select_monster_tool.bind(DIALOGUE_MODE_PLACE))
	dialogue_grid.add_child(_place_dialogue_button)

	_delete_dialogue_button = Button.new()
	_delete_dialogue_button.name = "DeleteDialogueTriggerButton"
	_delete_dialogue_button.text = "删除对话点"
	_delete_dialogue_button.tooltip_text = "选择后单击 100×100 对话触发区域进行删除"
	_delete_dialogue_button.toggle_mode = true
	_delete_dialogue_button.focus_mode = Control.FOCUS_NONE
	_delete_dialogue_button.custom_minimum_size = Vector2(96.0, 44.0)
	_delete_dialogue_button.pressed.connect(select_monster_tool.bind(DIALOGUE_MODE_DELETE))
	dialogue_grid.add_child(_delete_dialogue_button)

	var text_separator := HSeparator.new()
	column.add_child(text_separator)
	var text_title := Label.new()
	text_title.text = "文本放置"
	text_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text_title.theme_type_variation = &"TitleLabel"
	column.add_child(text_title)
	var text_grid := GridContainer.new()
	text_grid.name = "TextGrid"
	text_grid.columns = 3
	text_grid.add_theme_constant_override("h_separation", 6)
	text_grid.add_theme_constant_override("v_separation", 6)
	column.add_child(text_grid)

	_place_text_button = Button.new()
	_place_text_button.name = "PlaceTextButton"
	_place_text_button.text = "放置文本"
	_place_text_button.tooltip_text = "选择后单击地图，输入要显示的手写文本"
	_place_text_button.toggle_mode = true
	_place_text_button.focus_mode = Control.FOCUS_NONE
	_place_text_button.custom_minimum_size = Vector2(96.0, 44.0)
	_place_text_button.pressed.connect(select_monster_tool.bind(TEXT_MODE_PLACE))
	text_grid.add_child(_place_text_button)

	_delete_text_button = Button.new()
	_delete_text_button.name = "DeleteTextButton"
	_delete_text_button.text = "删除文本"
	_delete_text_button.tooltip_text = "选择后单击地图上的文本进行删除"
	_delete_text_button.toggle_mode = true
	_delete_text_button.focus_mode = Control.FOCUS_NONE
	_delete_text_button.custom_minimum_size = Vector2(96.0, 44.0)
	_delete_text_button.pressed.connect(select_monster_tool.bind(TEXT_MODE_DELETE))
	text_grid.add_child(_delete_text_button)

	var stop_button := Button.new()
	stop_button.name = "StopMonsterToolButton"
	stop_button.text = "停止放置"
	stop_button.focus_mode = Control.FOCUS_NONE
	stop_button.custom_minimum_size = Vector2(96.0, 44.0)
	stop_button.pressed.connect(select_monster_tool.bind(MONSTER_MODE_NONE))
	text_grid.add_child(stop_button)

	_monster_status_label = Label.new()
	_monster_status_label.name = "MonsterStatus"
	_monster_status_label.text = "未选中小怪"
	_monster_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_monster_status_label)

	var hint := Label.new()
	hint.text = "放置：左键单击　对话：Enter 下一句　Ctrl+Z 撤销"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(hint)


func _toggle_monster_palette_panel() -> void:
	if _monster_palette_panel == null or _monster_palette_toggle == null:
		return
	_monster_palette_panel.visible = not _monster_palette_panel.visible
	_monster_palette_toggle.text = "收起" if _monster_palette_panel.visible else "工具"
	_monster_palette_toggle.tooltip_text = (
		"收起右侧地图编辑工具栏" if _monster_palette_panel.visible
		else "展开右侧地图编辑工具栏"
	)
	# 收起后按钮贴在屏幕右边，展开后回到面板左侧，始终可点击。
	if _monster_palette_panel.visible:
		_monster_palette_toggle.offset_left = -424.0
		_monster_palette_toggle.offset_right = -352.0
	else:
		_monster_palette_toggle.offset_left = -96.0
		_monster_palette_toggle.offset_right = -16.0


func select_monster_tool(mode: int) -> void:
	if mode != MONSTER_MODE_NONE and mode != MONSTER_MODE_DELETE and mode != MONSTER_MODE_ADJUST \
	and mode != DIALOGUE_MODE_PLACE and mode != DIALOGUE_MODE_DELETE \
	and mode != TEXT_MODE_PLACE and mode != TEXT_MODE_DELETE \
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
	if _place_dialogue_button != null:
		_place_dialogue_button.set_pressed_no_signal(_monster_mode == DIALOGUE_MODE_PLACE)
	if _delete_dialogue_button != null:
		_delete_dialogue_button.set_pressed_no_signal(_monster_mode == DIALOGUE_MODE_DELETE)
	if _place_text_button != null:
		_place_text_button.set_pressed_no_signal(_monster_mode == TEXT_MODE_PLACE)
	if _delete_text_button != null:
		_delete_text_button.set_pressed_no_signal(_monster_mode == TEXT_MODE_DELETE)


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


## 对话输入窗口：每句一个文本栏，Enter 自动建立并聚焦下一句。
func _build_dialogue_input_window() -> void:
	if _dialogue_window != null:
		return
	var window := Window.new()
	window.name = "DialogueTriggerInput"
	window.title = "设置对话触发点（100×100）"
	window.size = Vector2i(560, 430)
	window.min_size = Vector2i(440, 320)
	window.transient = true
	window.exclusive = true
	window.unresizable = false
	window.visible = false
	window.theme = EDITOR_THEME
	window.close_requested.connect(_cancel_dialogue_input)
	add_child(window)
	_dialogue_window = window

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_bottom", 16)
	window.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var help := Label.new()
	help.text = "输入第一句，按 Enter 切换到下一句；播放时将按此顺序逐句输出。"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(help)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	_dialogue_lines_box = VBoxContainer.new()
	_dialogue_lines_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dialogue_lines_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_dialogue_lines_box)

	_dialogue_input_status = Label.new()
	_dialogue_input_status.modulate = Color(0.75, 0.12, 0.08)
	column.add_child(_dialogue_input_status)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(actions)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.pressed.connect(_cancel_dialogue_input)
	actions.add_child(cancel)
	var confirm := Button.new()
	confirm.text = "放置触发点"
	confirm.pressed.connect(_confirm_dialogue_input)
	actions.add_child(confirm)


func _open_dialogue_input(world_position: Vector2) -> void:
	if not active or _dialogue_window == null:
		return
	_pending_dialogue_position = world_position
	for child in _dialogue_lines_box.get_children():
		child.queue_free()
	_dialogue_input_status.text = ""
	var first := _add_dialogue_line_input()
	_dialogue_window.popup_centered(Vector2i(560, 430))
	first.call_deferred("grab_focus")


func _add_dialogue_line_input(initial_text := "") -> LineEdit:
	var input := LineEdit.new()
	input.placeholder_text = "第 %d 句" % (_dialogue_lines_box.get_child_count() + 1)
	input.text = initial_text
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.text_submitted.connect(_on_dialogue_line_submitted.bind(input))
	_dialogue_lines_box.add_child(input)
	return input


func _on_dialogue_line_submitted(_text: String, input: LineEdit) -> void:
	var index := input.get_index()
	var next: LineEdit = null
	if index + 1 < _dialogue_lines_box.get_child_count():
		next = _dialogue_lines_box.get_child(index + 1) as LineEdit
	else:
		next = _add_dialogue_line_input()
	if next != null:
		next.grab_focus()


func _confirm_dialogue_input() -> void:
	var dialogue_lines := PackedStringArray()
	for child in _dialogue_lines_box.get_children():
		if not child is LineEdit:
			continue
		var sentence: String = child.text.strip_edges()
		if not sentence.is_empty():
			dialogue_lines.append(sentence)
	if dialogue_lines.is_empty():
		_dialogue_input_status.text = "请至少输入一句文案。"
		return
	place_dialogue_trigger(_pending_dialogue_position, dialogue_lines)
	_dialogue_window.hide()


func _cancel_dialogue_input() -> void:
	if _dialogue_window != null:
		_dialogue_window.hide()


func _ensure_dialogue_container() -> Node2D:
	if is_instance_valid(_dialogue_container):
		return _dialogue_container
	var level := _level_root()
	if level == null:
		return null
	_dialogue_container = level.get_node_or_null("DialogueTriggers") as Node2D
	if _dialogue_container == null:
		_dialogue_container = Node2D.new()
		_dialogue_container.name = "DialogueTriggers"
		level.add_child(_dialogue_container)
		_dialogue_container.owner = level
	return _dialogue_container


func place_dialogue_trigger(
	world_position: Vector2,
	dialogue_lines: PackedStringArray,
	record_undo := true,
	trigger_id := ""
) -> Node2D:
	if dialogue_lines.is_empty():
		return null
	var container := _ensure_dialogue_container()
	if container == null:
		return null
	var trigger := DialogueTriggerScript.new() as Node2D
	trigger.name = "DialogueTrigger"
	trigger.set("lines", dialogue_lines.duplicate())
	if trigger_id.is_empty():
		trigger_id = _new_dialogue_id()
	trigger.set("editor_id", trigger_id)
	container.add_child(trigger, true)
	trigger.global_position = world_position
	var level := _level_root()
	if level != null:
		trigger.owner = level
	if record_undo:
		_record_edit({"type": &"dialogue_place", "id": trigger_id})
	return trigger


func remove_dialogue_trigger_at(world_position: Vector2) -> bool:
	var trigger := _find_dialogue_trigger_at(world_position)
	if trigger == null:
		return false
	var removed := {
		"type": &"dialogue_delete",
		"id": str(trigger.get("editor_id")),
		"position": trigger.global_position,
		"lines": PackedStringArray(trigger.get("lines")),
	}
	trigger.get_parent().remove_child(trigger)
	trigger.queue_free()
	_record_edit(removed)
	return true


func _find_dialogue_trigger_at(world_position: Vector2) -> Node2D:
	var container := _ensure_dialogue_container()
	if container == null:
		return null
	var nearest: Node2D = null
	var nearest_distance: float = INF
	for child in container.get_children():
		if not child is Node2D or not child.is_in_group(DialogueTriggerScript.GROUP):
			continue
		if not child.trigger_rect().has_point(world_position):
			continue
		var distance: float = child.global_position.distance_to(world_position)
		if distance < nearest_distance:
			nearest = child
			nearest_distance = distance
	return nearest


func _new_dialogue_id() -> String:
	var container := _ensure_dialogue_container()
	while true:
		var candidate := "dialogue_%d" % _next_dialogue_id
		_next_dialogue_id += 1
		var used := false
		if container != null:
			for child in container.get_children():
				if str(child.get("editor_id")) == candidate:
					used = true
					break
		if not used:
			return candidate
	return ""


func _remove_dialogue_trigger_by_id(trigger_id: String) -> bool:
	var container := _ensure_dialogue_container()
	if container == null or trigger_id.is_empty():
		return false
	for child in container.get_children():
		if str(child.get("editor_id")) != trigger_id:
			continue
		container.remove_child(child)
		child.queue_free()
		return true
	return false


func _refresh_dialogue_trigger_visuals() -> void:
	if not is_inside_tree():
		return
	for trigger in get_tree().get_nodes_in_group(DialogueTriggerScript.GROUP):
		if trigger.has_method("_refresh_editor_visibility"):
			trigger._refresh_editor_visibility()


#region 地图文本
func _build_text_input_window() -> void:
	if _text_window != null:
		return
	var window := Window.new()
	window.name = "MapTextInput"
	window.title = "放置地图文本"
	window.size = Vector2i(560, 330)
	window.min_size = Vector2i(440, 280)
	window.transient = true
	window.visible = false
	window.theme = EDITOR_THEME
	window.close_requested.connect(_cancel_text_input)
	add_child(window)
	window.hide()
	_text_window = window

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_bottom", 16)
	window.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)
	var help := Label.new()
	help.text = "输入要写在地图上的文字；支持换行，显示时使用沐瑶软笔手写体。"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(help)
	_text_input = TextEdit.new()
	_text_input.name = "TextInput"
	_text_input.placeholder_text = "输入地图文本……"
	_text_input.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text_input.custom_minimum_size = Vector2(0, 150)
	column.add_child(_text_input)
	_text_input_status = Label.new()
	_text_input_status.modulate = Color(0.75, 0.12, 0.08)
	column.add_child(_text_input_status)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 8)
	column.add_child(actions)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.pressed.connect(_cancel_text_input)
	actions.add_child(cancel)
	var confirm := Button.new()
	confirm.text = "放置文本"
	confirm.pressed.connect(_confirm_text_input)
	actions.add_child(confirm)


func _open_text_input(world_position: Vector2) -> void:
	if not active or _text_window == null:
		return
	_pending_text_position = world_position
	_text_input.text = ""
	_text_input_status.text = ""
	_text_window.popup_centered(Vector2i(560, 330))
	_text_input.call_deferred("grab_focus")


func _confirm_text_input() -> void:
	var content := _text_input.text.strip_edges()
	if content.is_empty():
		_text_input_status.text = "请输入要放置的文字。"
		return
	place_map_text(_pending_text_position, content)
	_text_window.hide()


func _cancel_text_input() -> void:
	if _text_window != null:
		_text_window.hide()


func _ensure_text_container() -> Node2D:
	if is_instance_valid(_text_container):
		return _text_container
	var level := _level_root()
	if level == null:
		return null
	_text_container = level.get_node_or_null("MapTexts") as Node2D
	if _text_container == null:
		_text_container = Node2D.new()
		_text_container.name = "MapTexts"
		level.add_child(_text_container)
		_text_container.owner = level
	return _text_container


func place_map_text(
	world_position: Vector2,
	content: String,
	record_undo := true,
	text_id := ""
) -> Label:
	content = content.strip_edges()
	if content.is_empty():
		return null
	var container := _ensure_text_container()
	if container == null:
		return null
	var label := MapTextScript.new() as Label
	label.name = "MapText"
	label.text = content
	if _map_text_font == null:
		_map_text_font = load(MAP_TEXT_FONT_PATH) as Font
	if _map_text_font != null:
		label.add_theme_font_override("font", _map_text_font)
	label.add_theme_font_size_override("font_size", 48)
	label.add_theme_color_override("font_color", Color(0.035, 0.031, 0.024, 1.0))
	label.add_theme_color_override("font_shadow_color", Color.TRANSPARENT)
	# 地图文字始终盖在地面和固化墨迹上，避免被关卡实体遮住。
	label.z_index = 20
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	if text_id.is_empty():
		text_id = _new_text_id()
	label.set("editor_id", text_id)
	container.add_child(label, true)
	label.global_position = world_position
	label.reset_size()
	var level := _level_root()
	if level != null:
		label.owner = level
	if record_undo:
		_record_edit({"type": &"text_place", "id": text_id})
	return label


func remove_map_text_at(world_position: Vector2) -> bool:
	var label := _find_map_text_at(world_position)
	if label == null:
		return false
	var removed := {
		"type": &"text_delete",
		"id": str(label.get("editor_id")),
		"position": label.global_position,
		"text": label.text,
	}
	label.get_parent().remove_child(label)
	label.queue_free()
	_record_edit(removed)
	return true


func _find_map_text_at(world_position: Vector2) -> Label:
	var container := _ensure_text_container()
	if container == null:
		return null
	for child in container.get_children():
		if child is Label and child.is_in_group(MapTextScript.GROUP) \
		and child.pick_rect().has_point(world_position):
			return child as Label
	return null


func _new_text_id() -> String:
	var container := _ensure_text_container()
	while true:
		var candidate := "text_%d" % _next_text_id
		_next_text_id += 1
		var used := false
		if container != null:
			for child in container.get_children():
				if str(child.get("editor_id")) == candidate:
					used = true
					break
		if not used:
			return candidate
	return ""


func _remove_map_text_by_id(text_id: String) -> bool:
	var container := _ensure_text_container()
	if container == null or text_id.is_empty():
		return false
	for child in container.get_children():
		if str(child.get("editor_id")) != text_id:
			continue
		container.remove_child(child)
		child.queue_free()
		return true
	return false
#endregion


func _on_canvas_edit_committed() -> void:
	if active:
		_record_edit({"type": &"canvas"})


func _on_map_changed() -> void:
	if active:
		_queue_edit_auto_save()


func _record_edit(edit: Dictionary) -> void:
	_edit_history.append(edit)
	if _edit_history.size() > MAX_EDIT_HISTORY:
		_edit_history.pop_front()
	_queue_edit_auto_save()


## 按绘图与小怪编辑发生的实际顺序撤销，供 Ctrl+Z 和自动测试调用。
func undo_last_edit() -> bool:
	if _edit_history.is_empty():
		return false
	var edit: Dictionary = _edit_history.pop_back()
	var changed := false
	match edit.get("type", &""):
		&"canvas":
			var surface: Node = _map_canvas.get_node_or_null("CanvasSurface") if _map_canvas != null else null
			changed = surface != null and surface.undo_last_edit()
		&"monster_place":
			changed = _remove_monster_by_id(str(edit.get("id", "")))
		&"monster_delete":
			changed = place_monster(
				int(edit.get("kind", -1)),
				edit.get("position", Vector2.ZERO),
				false,
				str(edit.get("id", "")),
				edit.get("scale", Vector2.ONE)
			) != null
		&"monster_transform":
			changed = _apply_monster_transform(
				str(edit.get("id", "")),
				edit.get("old_position", Vector2.ZERO),
				edit.get("old_scale", Vector2.ONE)
			)
		&"dialogue_place":
			changed = _remove_dialogue_trigger_by_id(str(edit.get("id", "")))
		&"dialogue_delete":
			changed = place_dialogue_trigger(
				edit.get("position", Vector2.ZERO),
				PackedStringArray(edit.get("lines", PackedStringArray())),
				false,
				str(edit.get("id", ""))
			) != null
		&"text_place":
			changed = _remove_map_text_by_id(str(edit.get("id", "")))
		&"text_delete":
			changed = place_map_text(
				edit.get("position", Vector2.ZERO),
				str(edit.get("text", "")),
				false,
				str(edit.get("id", ""))
			) != null
	if changed:
		_queue_edit_auto_save()
	return changed


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
	_outside_cleanup_elapsed += delta
	if _map_canvas != null and _outside_cleanup_elapsed >= outside_cleanup_interval:
		_outside_cleanup_elapsed = 0.0
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
	_open_map_save_window()
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
	dialog.dir_selected.connect(_on_save_directory_chosen)
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


func _build_map_save_window() -> void:
	if _map_save_window != null:
		return
	var popup := PopupPanel.new()
	popup.name = "MapSaveWindow"
	popup.theme = EDITOR_THEME
	add_child(popup)
	_map_save_window = popup
	var column := VBoxContainer.new()
	column.name = "Content"
	column.custom_minimum_size = Vector2(520, 440)
	column.add_theme_constant_override("separation", 10)
	popup.add_child(column)
	var title := Label.new()
	title.text = "保存地图"
	title.theme_type_variation = &"TitleLabel"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	_save_preview = TextureRect.new()
	_save_preview.name = "MapThumbnail"
	_save_preview.custom_minimum_size = Vector2(480, 270)
	_save_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_save_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	column.add_child(_save_preview)
	var name_row := HBoxContainer.new()
	column.add_child(name_row)
	var name_label := Label.new()
	name_label.text = "名称"
	name_label.custom_minimum_size = Vector2(68, 0)
	name_row.add_child(name_label)
	_save_name_input = LineEdit.new()
	_save_name_input.name = "MapNameInput"
	_save_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_name_input.placeholder_text = "输入地图名称"
	name_row.add_child(_save_name_input)
	var dir_row := HBoxContainer.new()
	column.add_child(dir_row)
	var dir_label := Label.new()
	dir_label.text = "路径"
	dir_label.custom_minimum_size = Vector2(68, 0)
	dir_row.add_child(dir_label)
	_save_directory_input = LineEdit.new()
	_save_directory_input.name = "MapDirectoryInput"
	_save_directory_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_directory_input.editable = false
	dir_row.add_child(_save_directory_input)
	var browse := Button.new()
	browse.text = "选择路径"
	browse.pressed.connect(_request_map_save_directory)
	dir_row.add_child(browse)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(actions)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.pressed.connect(popup.hide)
	actions.add_child(cancel)
	var save := Button.new()
	save.text = "保存"
	save.pressed.connect(_confirm_named_map_save)
	actions.add_child(save)


func _open_map_save_window() -> void:
	if _map_save_window == null:
		_build_map_save_window()
	if _map_save_window == null:
		return
	_save_name_input.text = map_path.get_file().get_basename()
	_save_directory_input.text = map_path.get_base_dir()
	_refresh_map_save_preview()
	_map_save_window.popup_centered()


func _refresh_map_save_preview() -> void:
	if _save_preview == null:
		return
	var image := get_viewport().get_texture().get_image()
	if image == null:
		return
	image.resize(480, 270, Image.INTERPOLATE_NEAREST)
	_save_preview.texture = ImageTexture.create_from_image(image)


func _on_save_directory_chosen(directory: String) -> void:
	if _save_directory_input != null:
		_save_directory_input.text = directory


func _confirm_named_map_save() -> void:
	if _save_name_input == null or _save_directory_input == null:
		return
	var name := _save_name_input.text.strip_edges().validate_filename()
	if name.to_lower().ends_with(".tscn"):
		name = name.trim_suffix(".tscn")
	var directory := _save_directory_input.text.strip_edges()
	if name.is_empty() or directory.is_empty():
		return
	map_path = directory.path_join(name + ".tscn")
	baked_map_path = directory.path_join(name + ".png")
	if export_map_to(map_path) == OK and _map_save_window != null:
		_map_save_window.hide()


func _save_current_map_overwrite() -> Error:
	if map_path.is_empty():
		return ERR_INVALID_PARAMETER
	baked_map_path = map_path.get_basename() + ".png"
	return export_map_to(map_path)


## 编辑中的自动保存只打包当前状态，不固化画布，保证下一步仍然可以撤销和继续绘制。
func _queue_edit_auto_save() -> void:
	if not active or not auto_save_edits or map_path.is_empty():
		return
	_auto_save_revision += 1
	var revision := _auto_save_revision
	get_tree().create_timer(auto_save_delay).timeout.connect(_run_edit_auto_save.bind(revision))


func _run_edit_auto_save(revision: int) -> void:
	if revision != _auto_save_revision or not active or not auto_save_edits:
		return
	var surface: Node = _map_canvas.get_node_or_null("CanvasSurface") if _map_canvas != null else null
	if surface != null and surface.has_method("save_ink"):
		# 内容仍是 PNG 压缩数据，但 .snapshot 不会和编辑器的 PNG 导入线程争抢文件。
		var snapshot_path := map_path.get_basename() + ".edit.snapshot"
		if surface.save_ink(snapshot_path) != OK:
			return
		edit_snapshot_path = snapshot_path
		surface.saved_ink_path = snapshot_path
	export_map_to(map_path, false)


func _reload_saved_map_for_editor() -> bool:
	var tree_root := get_tree().current_scene
	if tree_root == null or not tree_root.has_method("load_level") or map_path.is_empty():
		return false
	if _map_reload_in_progress:
		return true
	# 自动保存会反复覆盖同一路径；忽略资源缓存才能恢复磁盘上的最新版本。
	# 后台读取避免 F2 在大地图上冻结主线程。
	var error := ResourceLoader.load_threaded_request(
		map_path, "PackedScene", true, ResourceLoader.CACHE_MODE_IGNORE
	)
	if error != OK:
		push_warning("Creative: 无法开始恢复地图 %s (%d)" % [map_path, error])
		return false
	_map_reload_in_progress = true
	_finish_threaded_map_reload.call_deferred(tree_root)
	return true


func _finish_threaded_map_reload(tree_root: Node) -> void:
	var status := ResourceLoader.load_threaded_get_status(map_path)
	while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await get_tree().process_frame
		status = ResourceLoader.load_threaded_get_status(map_path)
	_map_reload_in_progress = false
	var packed := ResourceLoader.load_threaded_get(map_path) as PackedScene \
		if status == ResourceLoader.THREAD_LOAD_LOADED else null
	if packed == null:
		push_warning("Creative: 无法恢复已保存地图 %s" % map_path)
		_skip_restore_on_enter = true
		_enter()
		return
	if not is_instance_valid(tree_root):
		return
	var level: Node = tree_root.load_level(packed)
	var replacement := level.get_node_or_null(^"Creative")
	if replacement != null:
		replacement.call_deferred("_activate_restored_editor")


func _activate_restored_editor() -> void:
	_skip_restore_on_enter = true
	set_active(true)


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
		var surface: Node = _map_canvas.get_node_or_null("CanvasSurface")
		if surface != null:
			surface.saved_ink_path = ""
		edit_snapshot_path = ""
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
		# 玩家、手与小怪的运行时姿态不是地图编辑结果；尤其不能把上帝模式
		# 飞行位置写成出生位置。
		if body.tags.has(&"living"):
			continue
		node.position = body.position
		node.rotation = body.rotation
#endregion
