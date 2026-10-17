#创造模式（= 地图编辑模式）：F2 进/出。
#进去后本体没有碰撞、没有重力，WASD 直接改位置（上帝手感，不走惯性）；
#数字键 1/2/3/4 切画布工具；F5 先把画布固化，再把世界里的墨水物品导出成地图场景。

#region 依赖
extends Node

signal map_saved(path: String)
signal mode_changed(editing: bool)

const HEALTH_UI_GROUP := &"health_ui"
const MONSTER_CONTAINER_NAME := &"Monsters"
const PLAYER_SPAWN_NAME := &"PlayerSpawn"
const PLAYER_SPAWN_GROUP := &"player_spawn"
const RESPAWN_POINT_PREFIX := "RespawnPoint"
const RESPAWN_POINT_GROUP := &"respawn_point"
const PLAY_CANVAS_GROUP := &"play_canvas"
const MONSTER_MODE_NONE := -1
const MONSTER_MODE_DELETE := -2
const MONSTER_MODE_ADJUST := -3
const DIALOGUE_MODE_PLACE := -4
const DIALOGUE_MODE_DELETE := -5
const TEXT_MODE_PLACE := -6
const TEXT_MODE_DELETE := -7
const LAYOUT_MODE_MOVE_SPAWN := -8
const LAYOUT_MODE_PLACE_RESPAWN := -9
const LAYOUT_MODE_MOVE_RESPAWN := -10
const LAYOUT_MODE_PLACE_CANVAS := -11
const LAYOUT_MODE_MOVE_CANVAS := -12
const CONTROL_MODE := -13
const LAYOUT_MODE_PLACE_PORTAL := -14
const LAYOUT_MODE_DELETE_PORTAL := -16
const LAYOUT_MODE_FOUNTAIN := -17
const LAYOUT_MODE_DELETE_CANVAS := -18
const LAYOUT_MODE_DELETE_RESPAWN := -19
const LAYOUT_MODES := [
	LAYOUT_MODE_MOVE_SPAWN,
	LAYOUT_MODE_PLACE_RESPAWN,
	LAYOUT_MODE_MOVE_RESPAWN,
	LAYOUT_MODE_DELETE_RESPAWN,
	LAYOUT_MODE_PLACE_CANVAS,
	LAYOUT_MODE_MOVE_CANVAS,
	LAYOUT_MODE_DELETE_CANVAS,
	LAYOUT_MODE_PLACE_PORTAL,
	LAYOUT_MODE_DELETE_PORTAL,
	LAYOUT_MODE_FOUNTAIN,
]
const MONSTER_SCALE_STEP := 0.1
## 只保留非零正尺寸，避免退化碰撞体；不设玩法缩放上限。
const MONSTER_MIN_SCALE := 0.01
const TEXT_SCALE_STEP := 0.1
const TEXT_MIN_SCALE := 0.35
const TEXT_MAX_SCALE := 3.0
const MapMonsterScript := preload("res://actor/monster/src/map_monster.gd")
const DialogueTriggerScript := preload("res://debug/creative/src/map_dialogue_trigger.gd")
const MapTextScript := preload("res://ui/map_text/src/map_text_label.gd")
const MapPortalScript := preload("res://actor/portal/src/map_portal.gd")
const MapPortalScene := preload("res://actor/portal/map_portal.tscn")
const InkFountainScript := preload("res://actor/fountain/src/ink_fountain.gd")
const InkFountainScene := preload("res://actor/fountain/ink_fountain.tscn")
const MapPlacementOverlayScript := preload("res://debug/creative/src/map_placement_overlay.gd")
const MapImportedImageScript := preload("res://debug/creative/src/map_imported_image.gd")
const PlayCanvasScene := preload("res://actor/canvas/canvas.tscn")
const InkPalette := preload("res://ink/general/src/ink_palette.gd")
const CanvasSurfaceScript := preload("res://actor/canvas/src/canvas_surface.gd")
const GearBearing := preload("res://actor/canvas/src/gear_bearing.gd")
const InkSelectionIndicator := preload("res://ui/theme/ink_selection_indicator.gd")
var _editor_ink_buttons: Array[Button] = []
var _editor_ink_label: Label
var _gear_button: Button
var _gear8_button: Button
const MAP_TEXT_FONT_PATH := "res://ui/map_text/asset/Muyao-Softbrush.ttf"
const MONSTER_SCENES: Array[PackedScene] = [
	preload("res://actor/monster/bomb_side.tscn"),
	preload("res://actor/monster/little_soldier.tscn"),
	preload("res://actor/monster/great_shield.tscn"),
]
const MONSTER_KINDS := [
	MapMonsterScript.Kind.BOMB_SIDE,
	MapMonsterScript.Kind.LITTLE_SOLDIER,
	MapMonsterScript.Kind.SHIELD_SOLDIER,
]
const MONSTER_NAMES := ["炸弹狂", "小兵", "盾兵"]
const MONSTER_NODE_NAMES := ["BombSide", "LittleSoldier", "GreatShield"]
## 新放置怪物的默认大小；恢复原始大小也使用此表。
const MONSTER_FIXED_SCALES := {
	MapMonsterScript.Kind.BOMB_SIDE: 1.0,
	MapMonsterScript.Kind.LITTLE_SOLDIER: 0.7,
	MapMonsterScript.Kind.SHIELD_SOLDIER: 0.9,
}
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
## 编辑快照很小，可以快速保存；完整场景等用户停止操作后再落盘，避免连续编辑反复打包整关。
@export_range(0.1, 30.0, 0.1) var full_auto_save_delay := 5.0
## 烘焙图目前只作参考、运行时没有节点读取。按需开启，默认避免保存时再次遍历整张地图。
@export var save_preview_on_export := false
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
var _layout_overlay = null
var _layout_buttons: Dictionary = {}
var _layout_status_label: Label = null
## 「关卡墨水配额」表格：材质 id -> SpinBox。配额写进关卡根节点的 starting_ink，只对当前地图生效。
var _ink_quota_fields: Dictionary = {}
var _portal_destination: PopupMenu = null
var _portal_target_path := ""
var _portal_menu_target: Node2D = null
var _selected_portal: Node2D = null
var _canvas_size_dialog: ConfirmationDialog = null
var _canvas_width_input: SpinBox = null
var _canvas_height_input: SpinBox = null
var _new_canvas_size := Vector2i(400, 280)
var _layout_drag_target = null
var _layout_drag_offset := Vector2.ZERO
var _layout_drag_start := Vector2.ZERO
var _layout_drag_start_scale := Vector2.ONE
var _layout_drag_resizing := false
var _gear_drag_history: Dictionary = {}
var _selected_control_target = null
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
var _monster_drag_view_locked := false
var _monster_drag_inverse := Transform2D.IDENTITY
var _pending_monster_move: Node2D
var _drag_player_states: Array[Dictionary] = []
var _drag_hand_control: Node
var _drag_hand_mode := Node.PROCESS_MODE_INHERIT
var _save_directory_dialog: FileDialog = null
var _map_save_window: PopupPanel = null
var _save_name_input: LineEdit = null
var _save_directory_input: LineEdit = null
var _save_preview: TextureRect = null
var _save_status: Label
var _editor_player_visibility: Button
var _editor_nail_visibility: Button
var _skip_restore_on_enter := false
var _auto_save_revision := 0
var _syncing_canvas_tool := false
var _edit_history: Array[Dictionary] = []
var _redo_history: Array[Dictionary] = []
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
	get_window().focus_exited.connect(_on_drag_focus_lost)
	set_physics_process(false)
	_player = get_node_or_null(player_path)
	_canvas = get_node_or_null(canvas_path)
	_map_canvas = get_node_or_null(map_canvas_path)
	if _canvas == null:
		var level := _level_root()
		for candidate in get_tree().get_nodes_in_group(PLAY_CANVAS_GROUP):
			if level != null and level.is_ancestor_of(candidate):
				_canvas = candidate
				canvas_path = get_path_to(candidate)
				break
	if _canvas != null:
		_new_canvas_size = _canvas.canvas_size
	_bind_paths_to_current_level()
	if _map_canvas != null:
		_map_canvas.dev_save_enabled = false   # 大地图的 F5 只走导出
		if _map_canvas.has_signal("tool_changed"):
			_map_canvas.tool_changed.connect(_on_canvas_tool_changed)
		if _map_canvas.has_signal("editor_control_requested"):
			_map_canvas.editor_control_requested.connect(select_control_tool)
		var surface: Node = _map_canvas.get_node_or_null("CanvasSurface")
		if surface != null and surface.has_signal("edit_committed"):
			surface.edit_committed.connect(_on_canvas_edit_committed)
		if _map_canvas.has_signal("map_changed"):
			_map_canvas.map_changed.connect(_on_map_changed)
	# 游戏启动时不读取十几 MB 的编辑快照，也不创建地图编辑专用窗口和字体。
	# 这些资源只在首次进入地图编辑器时按需初始化。
	_show_canvas(_map_canvas, false)


func _exit_tree() -> void:
	_clear_edit_history()


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
	# 场景内明确记录的编辑快照优先；退出编辑器保存的固化场景会清空此路径。
	if edit_snapshot_path.begins_with(current_path.get_basename() + ".edit.") \
	and FileAccess.file_exists(edit_snapshot_path):
		return
	var native_snapshot := current_path.get_basename() + ".edit.snapshot"
	var png_snapshot := current_path.get_basename() + ".edit.png"
	var legacy_snapshot := current_path.get_basename() + ".edit.res"
	# 旧快照可能仍在磁盘；只有比关卡场景更新的未完成编辑才可恢复。
	var scene_time := FileAccess.get_modified_time(current_path)
	if FileAccess.file_exists(native_snapshot) and FileAccess.get_modified_time(native_snapshot) > scene_time:
		edit_snapshot_path = native_snapshot
	elif FileAccess.file_exists(png_snapshot) and FileAccess.get_modified_time(png_snapshot) > scene_time:
		edit_snapshot_path = png_snapshot
	elif FileAccess.file_exists(legacy_snapshot) and FileAccess.get_modified_time(legacy_snapshot) > scene_time:
		edit_snapshot_path = legacy_snapshot
	else:
		edit_snapshot_path = ""


## 放置放在普通输入阶段处理，优先于地图画布的绘制/物件输入；
## 旧地图中某些旧节点会提前消费 unhandled 输入，导致看起来选择了大盾却无法落下。
func _input(event: InputEvent) -> void:
	var blueprints := get_node_or_null("/root/Blueprints")
	if blueprints != null and blueprints.blocks_world_event(event):
		return
	# F2 进入编辑器时可能在本次输入处理中立刻替换整个关卡。
	# 先保留当前 Viewport，避免旧 Creative 节点脱离场景树后 get_viewport() 返回 null。
	var viewport := get_viewport()
	if _handle_editor_input(event):
		if is_instance_valid(viewport):
			viewport.set_input_as_handled()


func _handle_editor_input(event: InputEvent) -> bool:
	if active and event is InputEventMouseButton and event.pressed and _pointer_over_editor_ui(event.position):
		return false
	if active and event is InputEventKey:
		var focus := get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit:
			return false
	if event.is_action_pressed("creative"):
		toggle()
		return true
	elif active and event is InputEventKey and event.pressed and not event.echo \
	and event.ctrl_pressed and event.keycode == KEY_Z:
		undo_last_edit()
		return true
	elif active and event is InputEventKey and event.pressed and not event.echo \
	and event.ctrl_pressed and event.keycode == KEY_Y:
		redo_last_edit()
		return true
	elif active and event is InputEventKey and event.pressed and not event.echo \
	and not event.ctrl_pressed and not event.alt_pressed and not event.meta_pressed and event.keycode == KEY_F:
		select_control_tool()
		return true
	elif active and event is InputEventKey and event.pressed and not event.echo \
	and event.keycode == KEY_CAPSLOCK:
		_toggle_monster_palette_panel()
		return true
	elif active and event.is_action_pressed("canvas_save"):
		export_map()
		return true
	elif active and (LAYOUT_MODES.has(_monster_mode) or _monster_mode == CONTROL_MODE) \
	and event is InputEventMouseButton:
		return _handle_layout_mouse_button(event as InputEventMouseButton)
	elif active and (LAYOUT_MODES.has(_monster_mode) or _monster_mode == CONTROL_MODE) \
	and event is InputEventMouseMotion:
		return _handle_layout_mouse_motion(event as InputEventMouseMotion)
	elif active and (_monster_mode == MONSTER_MODE_ADJUST or _monster_mode == MONSTER_MODE_NONE) \
	and event is InputEventMouseButton:
		return _handle_monster_adjust_button(event as InputEventMouseButton)
	elif active and (_monster_mode == MONSTER_MODE_ADJUST or _monster_mode == MONSTER_MODE_NONE) \
	and event is InputEventMouseMotion:
		return _handle_monster_adjust_motion(event as InputEventMouseMotion)
	elif active and _monster_mode != MONSTER_MODE_NONE \
	and event is InputEventMouseButton \
	and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
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
			var placed := place_monster(_monster_mode, world_position)
			if placed != null:
				# 放置后自动退出放置模式，选中并直接进入拖动，方便立即调整位置。
				_monster_mode = MONSTER_MODE_NONE
				_set_selected_monster(placed)
				_lock_monster_drag_view()
				_dragging_monster = true
				_drag_offset = placed.global_position - world_position
				_drag_start_position = placed.global_position
				_drag_start_scale = placed.scale
				_update_monster_buttons()
		return true
	return false


func _event_world_position(event: InputEventMouse) -> Vector2:
	if _monster_drag_view_locked:
		return _monster_drag_inverse * event.position
	return get_viewport().get_canvas_transform().affine_inverse() * event.position


## 全局输入早于 GUI 更新；用本次事件的位置判断，避免沿用上一帧的悬停控件。
func _pointer_over_editor_ui(screen_position: Vector2) -> bool:
	for control: Control in get_tree().root.find_children("*", "Control", true, false):
		if control.get_viewport() != get_viewport() or not control.is_visible_in_tree() \
		or control.mouse_filter == Control.MOUSE_FILTER_IGNORE:
			continue
		if not Rect2(Vector2.ZERO, control.size).has_point(control.get_global_transform_with_canvas().affine_inverse() * screen_position):
			continue
		var clipped := false
		var parent := control.get_parent()
		while parent != null:
			if parent is Control and parent.clip_contents \
			and not Rect2(Vector2.ZERO, parent.size).has_point(parent.get_global_transform_with_canvas().affine_inverse() * screen_position):
				clipped = true
				break
			parent = parent.get_parent()
		if not clipped:
			return true
	return false


func _handle_monster_adjust_button(event: InputEventMouseButton) -> bool:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not event.pressed:
			return false
		var target := _find_monster_at(_event_world_position(event))
		if target != null:
			_selected_monster = target
		if not is_instance_valid(_selected_monster):
			return false
		_resize_selected_monster(MONSTER_SCALE_STEP if event.button_index == MOUSE_BUTTON_WHEEL_UP else -MONSTER_SCALE_STEP)
		_update_monster_status()
		return true
	if event.button_index == MOUSE_BUTTON_RIGHT:
		if not event.pressed:
			return false
		var world_pos := _event_world_position(event)
		var target := _find_monster_at(world_pos)
		if target == null:
			return false
		if target == _selected_monster:
			_set_selected_monster(null)
		var container := _ensure_monster_container()
		var removed := {
			"type": &"monster_delete",
			"id": str(target.get("editor_id")),
			"kind": int(target.get("kind")),
			"position": target.global_position,
			"scale": target.scale,
		}
		container.remove_child(target)
		target.queue_free()
		_record_edit(removed)
		return true
	if event.button_index != MOUSE_BUTTON_LEFT:
		return false
	if event.pressed:
		var monster := _find_monster_at(_event_world_position(event))
		_set_selected_monster(monster)
		if monster == null:
			# 默认模式下点击空白不拦截，让地图画布正常绘画。
			return _monster_mode == MONSTER_MODE_ADJUST
		_lock_monster_drag_view()
		_dragging_monster = true
		_drag_offset = monster.global_position - _event_world_position(event)
		_drag_start_position = monster.global_position
		_drag_start_scale = monster.scale
		return true
	if not _dragging_monster:
		return false
	_flush_monster_drag_move()
	_dragging_monster = false
	_unlock_monster_drag_view()
	_record_monster_transform(_selected_monster, _drag_start_position, _drag_start_scale)
	return true


func _handle_monster_adjust_motion(event: InputEventMouseMotion) -> bool:
	if not _dragging_monster or not is_instance_valid(_selected_monster):
		return false
	_selected_monster.global_position = _event_world_position(event) + _drag_offset
	_pending_monster_move = _selected_monster
	return true


func _flush_monster_drag_move() -> void:
	var target := _pending_monster_move
	_pending_monster_move = null
	if is_instance_valid(target):
		target.sync_editor_translation()
		if target == _layout_drag_target:
			_refresh_layout_overlay(target)


func _on_drag_focus_lost() -> void:
	if not _monster_drag_view_locked:
		return
	if is_instance_valid(_layout_drag_target):
		_finish_layout_drag()
	else:
		_flush_monster_drag_move()
		_dragging_monster = false
		_unlock_monster_drag_view()
		_record_monster_transform(_selected_monster, _drag_start_position, _drag_start_scale)


func _lock_monster_drag_view() -> void:
	if _monster_drag_view_locked:
		return
	var camera := _level_root().get_node_or_null("Camera2D")
	if camera != null and camera.has_method("set_editor_drag_locked"):
		camera.set_editor_drag_locked(true)
	_monster_drag_inverse = get_viewport().get_canvas_transform().affine_inverse()
	_monster_drag_view_locked = true
	if _player == null or _body == null:
		return
	# 冻结玩家自身，鼠标手臂控制和飞行输入不能把隐藏的玩家拉走。
	_drag_hand_control = _player.get_node_or_null("Arm/Hand/HandControl")
	if _drag_hand_control != null:
		_drag_hand_mode = _drag_hand_control.process_mode
		_drag_hand_control.process_mode = Node.PROCESS_MODE_DISABLED
	var bodies: Array = [_body, _player.get_node("Arm").body, _player.get_node("Arm/Hand").body]
	for physics_body in bodies:
		_drag_player_states.append({"body": physics_body, "frozen": physics_body.frozen,
			"had_tag": physics_body.tags.has("editor_physics_paused"),
			"tag": physics_body.tags.get("editor_physics_paused", false)})
		physics_body.tags["editor_physics_paused"] = true
		physics_body.linear_velocity = Vector2.ZERO
		physics_body.angular_velocity = 0.0
		_level_root().world.freeze(physics_body)


func _unlock_monster_drag_view() -> void:
	if not _monster_drag_view_locked:
		return
	_monster_drag_view_locked = false
	var level := _level_root()
	for state in _drag_player_states:
		if state.had_tag:
			state.body.tags["editor_physics_paused"] = state.tag
		else:
			state.body.tags.erase("editor_physics_paused")
		if level != null and not state.frozen:
			level.world.unfreeze(state.body)
	_drag_player_states.clear()
	if is_instance_valid(_drag_hand_control):
		_drag_hand_control.process_mode = _drag_hand_mode
	_drag_hand_control = null
	var camera := level.get_node_or_null("Camera2D") if level != null else null
	if camera != null and camera.has_method("set_editor_drag_locked"):
		camera.set_editor_drag_locked(false)
#endregion


#region 开关
func toggle() -> void:
	if _transition.busy:
		return
	var message := "展开地图画稿…" if not active else "墨迹成形，回到游玩…"
	if not await _transition.begin(_transition.Style.DRAFT, message):
		return
	_mode_transition_pending = true
	set_active(not active)
	if not _map_reload_in_progress:
		_mode_transition_pending = false
		await _transition.finish()


var _mode_transition_pending := false
@onready var _transition: Node = get_node("/root/SceneTransition")


func set_active(value: bool) -> void:
	if value == active:
		return
	active = value
	if active:
		_enter()
	else:
		_exit()
	mode_changed.emit(active)


func _enter() -> void:
	# 从游玩态进编辑器时，运行中的破坏/碎片不能带进来。通过 Root 换成上次
	# F2 退出时覆盖保存的关卡实例，再由新实例进入编辑态。
	if not _skip_restore_on_enter and _reload_saved_map_for_editor():
		return
	_skip_restore_on_enter = false
	_ensure_editor_resources()
	_load_edit_snapshot_if_needed()
	_clear_edit_history()
	if _map_canvas != null:
		var edit_surface = _map_canvas.get_node_or_null("CanvasSurface")
		if edit_surface != null:
			edit_surface._undo_steps.clear()
			edit_surface._redo_steps.clear()
	# 记录1是上次退出时保存的可游玩关卡；编辑时把它还原为可画的液态像素。
	# 这是进入编辑器的恢复步骤，不应占用一次 Ctrl+Z。
	_set_ink_free(true)
	if _map_canvas != null:
		_map_canvas.return_to_canvas(false, true)
	_set_monster_physics_paused(true)
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
	for play_canvas in _play_canvases():
		_show_canvas(play_canvas, false)
	_show_canvas(_map_canvas, true)
	# 地图编辑器有独立的屏幕固定工具栏和四向扩展按钮。
	if _map_canvas != null:
		_map_canvas.set_map_editor_mode(true)
	_refresh_editor_visibility()
	if _monster_palette != null:
		_monster_palette.visible = true
	_refresh_layout_overlay()
	_refresh_dialogue_trigger_visuals()
	# 换过地图之后表格要重新读一遍本关的 starting_ink。
	_sync_ink_quota_fields()
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
	_migrate_legacy_respawn_points()
	_build_layout_overlay()
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
	_flush_monster_drag_move()
	_unlock_monster_drag_view()
	if _layout_drag_target != null:
		_finish_layout_drag()
	_cancel_dialogue_input()
	_cancel_text_input()
	if _canvas_size_dialog != null:
		_canvas_size_dialog.hide()
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
	_set_monster_physics_paused(false)
	_show_canvas(_map_canvas, false)
	for play_canvas in _play_canvases():
		_show_canvas(play_canvas, true)
	if _map_canvas != null:
		_map_canvas.set_map_editor_mode(false)
	if _canvas != null and _canvas.has_method("activate_hand_tool"):
		_canvas.activate_hand_tool()
	_monster_mode = MONSTER_MODE_NONE
	_cancel_layout_drag()
	_set_selected_monster(null)
	_set_imported_image_selection(null)
	_update_monster_buttons()
	if _monster_palette != null:
		_monster_palette.visible = false
	if _layout_overlay != null:
		_layout_overlay.visible = false
	_refresh_dialogue_trigger_visuals()
	_set_ink_free(false)
	if _player != null:
		_player.visible = _saved_player_visible
		var health = _player.get_node_or_null("InkHealth")
		if health != null:
			health.damage_enabled = true
	_restore_health_ui()
	print("CREATIVE off")


## 出生点与游玩画布互相独立。旧地图没有出生点时只补建一次，之后绝不
## 因画布移动而自动改写；编辑器也只提供“移动出生点”，不提供新增入口。
func _ensure_spawn_point() -> Marker2D:
	if is_instance_valid(_spawn_point):
		return _spawn_point
	var level := _level_root()
	if level == null:
		return null
	_spawn_point = level.get_node_or_null(NodePath(String(PLAYER_SPAWN_NAME))) as Marker2D
	if _spawn_point != null:
		_spawn_point.add_to_group(PLAYER_SPAWN_GROUP, true)
		return _spawn_point
	_spawn_point = Marker2D.new()
	_spawn_point.name = PLAYER_SPAWN_NAME
	level.add_child(_spawn_point)
	_spawn_point.global_position = _initial_spawn_position()
	_spawn_point.global_rotation = 0.0
	_spawn_point.add_to_group(PLAYER_SPAWN_GROUP, true)
	_spawn_point.owner = level
	return _spawn_point


func _initial_spawn_position() -> Vector2:
	if _player != null:
		return _player.global_position
	if _canvas != null:
		return _canvas.to_global(Vector2(_canvas.canvas_size) * 0.5)
	return Vector2.ZERO


## 旧版本用 PlayerSpawn2、PlayerSpawn3 表示复活点。保留唯一 PlayerSpawn，
## 其余旧标记迁移到独立复活点组，避免死亡逻辑再把出生点与复活点混用。
func _migrate_legacy_respawn_points() -> void:
	var level := _level_root()
	if level == null:
		return
	for node in _collect_nodes_recursive(level):
		if not node is Marker2D or node == _spawn_point:
			continue
		var marker := node as Marker2D
		if marker.is_in_group(RESPAWN_POINT_GROUP) or String(marker.name).begins_with(RESPAWN_POINT_PREFIX):
			marker.add_to_group(RESPAWN_POINT_GROUP, true)
		elif String(marker.name).begins_with(String(PLAYER_SPAWN_NAME)):
			marker.name = _unique_level_node_name(RESPAWN_POINT_PREFIX)
			marker.add_to_group(RESPAWN_POINT_GROUP, true)


func _reset_player_to_spawn() -> void:
	var spawn := _ensure_spawn_point()
	if spawn == null or _player == null or _body == null:
		return
	_player.teleport_to(spawn.global_position, spawn.global_rotation)


#切换哪块画布在工作：可见 + 收不收输入。
func _show_canvas(canvas, on: bool) -> void:
	if canvas == null:
		return
	canvas.visible = on
	canvas.active = on


## 当前关卡中的普通游玩画布。主画布始终包含在内，额外画布通过 play_canvas 组加入。
func _play_canvases() -> Array:
	var result: Array = []
	if is_instance_valid(_canvas) and _canvas.is_inside_tree():
		if not _canvas.is_in_group(PLAY_CANVAS_GROUP):
			_canvas.add_to_group(PLAY_CANVAS_GROUP, true)
		result.append(_canvas)
	var level := _level_root()
	if level == null:
		return result
	for canvas in get_tree().get_nodes_in_group(PLAY_CANVAS_GROUP):
		if canvas != _map_canvas and level.is_ancestor_of(canvas) and not result.has(canvas):
			result.append(canvas)
	return result


#创造模式画图不花墨水：两张画布都免账，免得切回去时账目错位。
func _set_ink_free(free: bool) -> void:
	var canvases := _play_canvases()
	if _map_canvas != null:
		canvases.append(_map_canvas)
	for canvas in canvases:
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


#region 出生点、复活点与游玩画布布局
func _build_layout_overlay() -> void:
	if _layout_overlay != null:
		return
	_layout_overlay = MapPlacementOverlayScript.new()
	_layout_overlay.name = "MapPlacementOverlay"
	_layout_overlay.z_index = 1000
	add_child(_layout_overlay)
	_refresh_layout_overlay()


func _refresh_layout_overlay(selected = null) -> void:
	if _layout_overlay == null:
		return
	_layout_overlay.visible = active
	_layout_overlay.call("configure", _ensure_spawn_point(), _respawn_points(), _play_canvases(), selected)
	_update_layout_status()


func _update_layout_status() -> void:
	if _layout_status_label == null:
		return
	_layout_status_label.text = "出生点 1 个　复活点 %d 个　游玩画布 %d 块　传送门 %d 个　墨泉 %d 个" % [
		_respawn_points().size(),
		_play_canvases().size(),
		_portals().size(),
		_ink_fountains().size(),
	]
	if _monster_mode == CONTROL_MODE:
		_layout_status_label.text += "\n操纵：%s" % _control_target_name(_selected_control_target)


func _collect_nodes_recursive(root: Node) -> Array:
	var result: Array = []
	for child in root.get_children():
		result.append(child)
		result.append_array(_collect_nodes_recursive(child))
	return result


func _unique_level_node_name(prefix: String) -> String:
	var level := _level_root()
	if level == null:
		return prefix
	var suffix := 1
	var candidate := prefix
	while level.get_node_or_null(NodePath(candidate)) != null:
		suffix += 1
		candidate = "%s%d" % [prefix, suffix]
	return candidate


func _respawn_points() -> Array:
	var result: Array = []
	var level := _level_root()
	if level == null:
		return result
	for node in _collect_nodes_recursive(level):
		if node is Marker2D and node != _spawn_point \
		and (node.is_in_group(RESPAWN_POINT_GROUP) or String(node.name).begins_with(RESPAWN_POINT_PREFIX)):
			if not node.is_in_group(RESPAWN_POINT_GROUP):
				node.add_to_group(RESPAWN_POINT_GROUP, true)
			result.append(node)
	return result


func _handle_layout_mouse_button(event: InputEventMouseButton) -> bool:
	if _monster_mode == LAYOUT_MODE_MOVE_CANVAS and event.button_index == MOUSE_BUTTON_RIGHT:
		if not event.pressed:
			return false
		return delete_play_canvas(_pick_play_canvas(_event_world_position(event)))
	if _monster_mode == LAYOUT_MODE_FOUNTAIN and event.button_index == MOUSE_BUTTON_RIGHT:
		if not event.pressed:
			return false
		return delete_ink_fountain(_pick_ink_fountain(_event_world_position(event)))
	# 放置类工具统一右键删除：光标下是什么就删什么，不用先切到删除工具。
	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var delete_at := _event_world_position(event)
		match _monster_mode:
			LAYOUT_MODE_PLACE_RESPAWN, LAYOUT_MODE_MOVE_RESPAWN:
				return delete_respawn_point(_pick_respawn_point(delete_at))
			LAYOUT_MODE_PLACE_CANVAS:
				return delete_play_canvas(_pick_play_canvas(delete_at))
			LAYOUT_MODE_PLACE_PORTAL:
				return delete_portal(_pick_portal(delete_at))
	if _monster_mode == CONTROL_MODE and event.button_index == MOUSE_BUTTON_RIGHT:
		if not event.pressed:
			return false
		_delete_control_target(_event_world_position(event))
		return true
	if _monster_mode == CONTROL_MODE \
	and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		if not event.pressed:
			return false
		var target = _pick_control_target(_event_world_position(event), true)
		if target == null:
			target = _selected_control_target
		if target == null:
			return false
		_selected_control_target = target
		var direction := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
		return _resize_control_target(target, direction)
	if event.button_index != MOUSE_BUTTON_LEFT:
		return false
	if event.pressed:
		var world_position := _event_world_position(event)
		match _monster_mode:
			CONTROL_MODE:
				_selected_control_target = _pick_control_target(world_position)
				if event.double_click and is_instance_valid(_selected_control_target) \
				and _selected_control_target.is_in_group(MapPortalScript.GROUP):
					_open_portal_menu(_selected_control_target)
					return true
				_begin_layout_drag(_selected_control_target, world_position)
				_layout_drag_resizing = is_instance_valid(_selected_control_target) \
					and _selected_control_target.is_in_group(MapImportedImageScript.GROUP) \
					and _selected_control_target.resize_handle_hit(world_position)
			LAYOUT_MODE_PLACE_RESPAWN:
				# 放置类工具统一：按在已有对象上是移动它，按在空地上才是新增。
				var picked_respawn := _pick_respawn_point(world_position)
				if picked_respawn != null:
					_begin_layout_drag(picked_respawn, world_position)
				else:
					place_respawn_point(world_position)
				return true
			LAYOUT_MODE_DELETE_RESPAWN:
				delete_respawn_point(_pick_respawn_point(world_position))
				return true
			LAYOUT_MODE_PLACE_CANVAS:
				var picked_canvas := _pick_play_canvas(world_position)
				if picked_canvas != null:
					_begin_layout_drag(picked_canvas, world_position)
				else:
					place_play_canvas(world_position)
				return true
			LAYOUT_MODE_PLACE_PORTAL:
				var picked_portal := _pick_portal(world_position)
				if picked_portal != null:
					_begin_layout_drag(picked_portal, world_position)
					return true
				var placed_portal := place_portal(world_position, _portal_choice())
				if is_instance_valid(placed_portal):
					select_control_tool()
					_selected_control_target = placed_portal
					_select_portal(placed_portal)
					_update_layout_status()
				return true
			LAYOUT_MODE_FOUNTAIN:
				var picked_fountain := _pick_ink_fountain(world_position)
				if picked_fountain != null:
					_begin_layout_drag(picked_fountain, world_position)
				else:
					place_ink_fountain(world_position)
				return true
			LAYOUT_MODE_DELETE_PORTAL:
				delete_portal(_pick_portal(world_position))
				return true
			LAYOUT_MODE_DELETE_CANVAS:
				delete_play_canvas(_pick_play_canvas(world_position))
				return true
			LAYOUT_MODE_MOVE_SPAWN:
				_begin_layout_drag(_pick_spawn_point(world_position), world_position)
			LAYOUT_MODE_MOVE_RESPAWN:
				_begin_layout_drag(_pick_respawn_point(world_position), world_position)
			LAYOUT_MODE_MOVE_CANVAS:
				_begin_layout_drag(_pick_play_canvas(world_position), world_position)
		return true
	if _layout_drag_target != null:
		_handle_layout_mouse_motion(event)
		_finish_layout_drag()
		return true
	return false


func _handle_layout_mouse_motion(event: InputEventMouse) -> bool:
	if not is_instance_valid(_layout_drag_target):
		_cancel_layout_drag()
		return false
	var world_position := _event_world_position(event)
	var start_mouse: Vector2 = _layout_drag_start - _layout_drag_offset
	if world_position.is_equal_approx(start_mouse) \
	and _layout_drag_target.global_position.is_equal_approx(_layout_drag_start) \
	and _layout_drag_target.scale.is_equal_approx(_layout_drag_start_scale):
		return true
	if _layout_drag_resizing and _layout_drag_target is Sprite2D:
		var image: Sprite2D = _layout_drag_target
		if image.texture != null:
			var local_delta: Vector2 = image.get_parent().to_local(world_position) - image.get_parent().to_local(start_mouse)
			var ratio := local_delta.rotated(-image.rotation) / Vector2(image.texture.get_size())
			image.scale = Vector2.ONE * clampf(minf(_layout_drag_start_scale.x + ratio.x, _layout_drag_start_scale.y + ratio.y),
				MapImportedImageScript.MIN_SCALE, MapImportedImageScript.MAX_SCALE)
			return true
	var target_position := world_position + _layout_drag_offset
	if _layout_drag_target.global_position.is_equal_approx(target_position):
		return true
	if _layout_drag_target is GearBearing:
		_layout_drag_target.move_editor_drag(target_position)
		_refresh_layout_overlay(_layout_drag_target)
		return true
	_layout_drag_target.global_position = target_position
	if _layout_drag_target.is_in_group(&"map_monster"):
		_pending_monster_move = _layout_drag_target
	elif _layout_drag_target.has_method("sync_physics_from_node"):
		_layout_drag_target.sync_physics_from_node()
	if not _layout_drag_target.is_in_group(&"map_monster"):
		_refresh_layout_overlay(_layout_drag_target)
	return true


func _begin_layout_drag(target, world_position: Vector2) -> void:
	_cancel_layout_drag()
	if target == null:
		_refresh_layout_overlay()
		return
	if target is GearBearing:
		# 共用画布事务保存轮体和轴承，避免撤销创建后历史仍引用已释放的节点。
		var bounds: Rect2 = Rect2(_map_canvas.surface.global_position, Vector2(_map_canvas.canvas_size))
		bounds = bounds.merge(target.yellow_anchor.body.aabb)
		_gear_drag_history = _map_canvas.History.capture(_map_canvas, true, bounds)
		_gear_drag_history["bounds"] = bounds
		if not target.begin_editor_drag():
			_gear_drag_history.clear()
			return
	_layout_drag_target = target
	_layout_drag_offset = target.global_position - world_position
	_layout_drag_start = target.global_position
	_layout_drag_start_scale = target.scale
	_layout_drag_resizing = false
	if target.is_in_group(&"map_monster") or target is GearBearing:
		_lock_monster_drag_view()
	_refresh_layout_overlay(target)
	if _monster_mode == CONTROL_MODE:
		_select_portal(target if target.is_in_group(MapPortalScript.GROUP) else null)
		_set_imported_image_selection(target if target.is_in_group(MapImportedImageScript.GROUP) else null)


func _finish_layout_drag() -> void:
	_flush_monster_drag_move()
	_unlock_monster_drag_view()
	var target = _layout_drag_target
	_layout_drag_target = null
	if is_instance_valid(target) and target is GearBearing:
		var moved: bool = not target.global_position.is_equal_approx(_layout_drag_start)
		if moved:
			var cell := Vector2i(_map_canvas.surface.to_local(target.global_position).floor())
			if _map_canvas.surface._inside(Vector2(cell)) and _map_canvas.surface.material_at(cell.x, cell.y) != 0:
				_map_canvas.generate(false)
			target.finish_editor_drag()
			_gear_drag_history.bounds = _gear_drag_history.bounds.merge(target.yellow_anchor.body.aabb)
			_map_canvas.History.commit(_map_canvas, _gear_drag_history)
		else:
			target.finish_editor_drag(true)
		_gear_drag_history = {}
		_refresh_layout_overlay(target)
		_layout_drag_resizing = false
		return
	if is_instance_valid(target) and (not target.global_position.is_equal_approx(_layout_drag_start)
		or not target.scale.is_equal_approx(_layout_drag_start_scale)):
		_record_edit({
			"type": &"object_transform",
			"target": target,
			"old_position": _layout_drag_start,
			"old_scale": _layout_drag_start_scale,
		})
	_refresh_layout_overlay(_selected_control_target if _monster_mode == CONTROL_MODE else null)
	_layout_drag_resizing = false


func _cancel_layout_drag() -> void:
	if is_instance_valid(_layout_drag_target) and _layout_drag_target is GearBearing:
		_layout_drag_target.finish_editor_drag(true)
	_gear_drag_history = {}
	_flush_monster_drag_move()
	_unlock_monster_drag_view()
	_layout_drag_target = null
	_layout_drag_offset = Vector2.ZERO
	_layout_drag_start = Vector2.ZERO
	_layout_drag_start_scale = Vector2.ONE
	_layout_drag_resizing = false


func _pick_control_target(world_position: Vector2, resizable_only := false):
	var candidates := [
		_find_imported_image_at(world_position),
		_find_monster_at(world_position),
		_find_map_text_at(world_position),
	]
	if not resizable_only:
		candidates.append_array([
			_pick_gear(world_position),
			_pick_portal(world_position),
			_find_dialogue_trigger_at(world_position),
			_pick_spawn_point(world_position),
			_pick_respawn_point(world_position),
			_pick_play_canvas(world_position),
			_pick_ink_fountain(world_position),
		])
	var top = null
	var top_z := -4096
	for candidate in candidates:
		if is_instance_valid(candidate):
			var z := _control_target_z(candidate)
			if top == null or z > top_z or (z == top_z and candidate.is_greater_than(top)):
				top = candidate
				top_z = z
	return top


func _pick_gear(world_position: Vector2):
	var level := _level_root()
	if level == null:
		return null
	var children := level.get_children()
	children.reverse()
	for child in children:
		if child is GearBearing and not child.is_queued_for_deletion() \
		and child.editor_hit_test(world_position):
			child._process(0.0)
			return child
	return null


func _control_target_z(target: CanvasItem) -> int:
	# 出生/复活标记由布局层绘制，命中优先级与可见标记一致。
	if target is Marker2D:
		return _layout_overlay.z_index if is_instance_valid(_layout_overlay) else 1000
	var z := target.z_index
	var parent := target.get_parent()
	while target.z_as_relative and parent is CanvasItem:
		target = parent
		z += target.z_index
		parent = target.get_parent()
	return z


func _delete_control_target(world_position: Vector2) -> bool:
	var target = _pick_control_target(world_position)
	if not is_instance_valid(target):
		return false
	if is_instance_valid(_layout_drag_target):
		_finish_layout_drag()
	var deleted := false
	if target.is_in_group(MapMonsterScript.GROUP):
		deleted = remove_monster_at(world_position)
	elif target.is_in_group(MapTextScript.GROUP):
		deleted = remove_map_text_at(world_position)
	elif target.is_in_group(DialogueTriggerScript.GROUP):
		deleted = remove_dialogue_trigger_at(world_position)
	elif target.is_in_group(MapImportedImageScript.GROUP):
		deleted = delete_imported_image(target)
	elif target.is_in_group(MapPortalScript.GROUP):
		deleted = delete_portal(target)
	elif target.is_in_group(InkFountainScript.GROUP):
		deleted = delete_ink_fountain(target)
	elif target.is_in_group(PLAY_CANVAS_GROUP):
		deleted = delete_play_canvas(target)
	if deleted:
		if _selected_control_target == target:
			_selected_control_target = null
		_refresh_layout_overlay(_selected_control_target)
		_update_layout_status()
	return deleted


func _resize_control_target(target, direction: float) -> bool:
	if not is_instance_valid(target):
		return false
	if target.is_in_group(MapMonsterScript.GROUP):
		_selected_monster = target
		_resize_selected_monster(direction * MONSTER_SCALE_STEP)
		_update_monster_status()
		_refresh_layout_overlay(target)
		return true
	if target.is_in_group(MapImportedImageScript.GROUP):
		var old_image_scale: Vector2 = target.scale
		var image_scale := clampf(old_image_scale.x + direction * 0.1,
			MapImportedImageScript.MIN_SCALE, MapImportedImageScript.MAX_SCALE)
		if not is_equal_approx(image_scale, old_image_scale.x):
			target.scale = Vector2.ONE * image_scale
			_record_edit({"type": &"object_transform", "target": target,
				"old_position": target.global_position, "old_scale": old_image_scale})
		return true
	var minimum := TEXT_MIN_SCALE
	var maximum := TEXT_MAX_SCALE
	var step := TEXT_SCALE_STEP
	if not (target is Label and target.is_in_group(MapTextScript.GROUP)):
		return false
	var old_scale: Vector2 = target.scale
	var next_scale := clampf(old_scale.x + direction * step, minimum, maximum)
	if is_equal_approx(next_scale, old_scale.x):
		return true
	target.scale = Vector2.ONE * next_scale
	if target.has_method("sync_physics_from_node"):
		target.sync_physics_from_node(true)
	_record_edit({
		"type": &"object_transform",
		"target": target,
		"old_position": target.global_position,
		"old_scale": old_scale,
	})
	_refresh_layout_overlay(_selected_control_target)
	return true


func _control_target_name(target) -> String:
	if not is_instance_valid(target):
		return "左键拖动对象；滚轮缩放；右键删除怪物、画布、文本、对话、图片、传送门或墨泉"
	if target.is_in_group(MapImportedImageScript.GROUP):
		return "图片：拖动定位，右下角或滚轮缩放，右键删除"
	if target is GearBearing:
		return "齿轮：左键拖动整体及轴心，松开后重新连接支座"
	if target.is_in_group(MapMonsterScript.GROUP):
		return "怪物"
	if target is Label and target.is_in_group(MapTextScript.GROUP):
		return "文本"
	if target.is_in_group(DialogueTriggerScript.GROUP):
		return "对话触发点"
	if target.is_in_group(MapPortalScript.GROUP):
		return "传送门"
	if target.is_in_group(InkFountainScript.GROUP):
		return "墨泉"
	if target == _spawn_point:
		return "出生点"
	if target.is_in_group(RESPAWN_POINT_GROUP):
		return "复活点"
	if target.is_in_group(PLAY_CANVAS_GROUP):
		return "游玩画布：左键拖动，右键删除"
	return str(target.name)


func _layout_pick_radius() -> float:
	var inverse := get_viewport().get_canvas_transform().affine_inverse()
	return maxf(12.0, (inverse * Vector2(28.0, 0.0)).distance_to(inverse * Vector2.ZERO))


func _pick_spawn_point(world_position: Vector2) -> Marker2D:
	var spawn := _ensure_spawn_point()
	if spawn != null and spawn.global_position.distance_to(world_position) <= _layout_pick_radius():
		return spawn
	return null


func _pick_respawn_point(world_position: Vector2) -> Marker2D:
	var nearest: Marker2D = null
	var nearest_distance := _layout_pick_radius()
	for point in _respawn_points():
		var distance: float = point.global_position.distance_to(world_position)
		if distance <= nearest_distance:
			nearest = point
			nearest_distance = distance
	return nearest


func _pick_play_canvas(world_position: Vector2) -> Node2D:
	var canvases := _play_canvases()
	for index in range(canvases.size() - 1, -1, -1):
		var canvas = canvases[index]
		if Rect2(Vector2.ZERO, Vector2(canvas.get("canvas_size"))).has_point(canvas.to_local(world_position)):
			return canvas
	return null


func place_respawn_point(world_position: Vector2, record_undo := true) -> Marker2D:
	var level := _level_root()
	if level == null:
		return null
	var point := Marker2D.new()
	point.name = _unique_level_node_name(RESPAWN_POINT_PREFIX)
	level.add_child(point)
	point.global_position = world_position
	point.add_to_group(RESPAWN_POINT_GROUP, true)
	point.owner = level
	if record_undo:
		_record_edit({"type": &"respawn_place", "target": point})
	_refresh_layout_overlay(point)
	return point


func delete_respawn_point(point: Marker2D) -> bool:
	if not is_instance_valid(point) or not point.is_in_group(RESPAWN_POINT_GROUP):
		return false
	if _layout_drag_target == point:
		_finish_layout_drag()
	_record_edit({"type": &"respawn_delete", "position": point.global_position, "target": point})
	point.get_parent().remove_child(point)
	point.queue_free()
	_refresh_layout_overlay()
	return true


func _portals() -> Array:
	var result: Array = []
	var level := _level_root()
	if level != null:
		for child in level.get_children():
			if child.is_in_group(MapPortalScript.GROUP):
				result.append(child)
	return result


func _pick_portal(world_position: Vector2) -> Node2D:
	var portals := _portals()
	for index in range(portals.size() - 1, -1, -1):
		if portals[index].contains_world_point(world_position):
			return portals[index]
	return null


func _ink_fountains() -> Array:
	var result: Array = []
	var level := _level_root()
	if level == null:
		return result
	for node in _collect_nodes_recursive(level):
		if node.is_in_group(InkFountainScript.GROUP):
			result.append(node)
	return result


func _pick_ink_fountain(world_position: Vector2) -> Node2D:
	var fountains := _ink_fountains()
	for index in range(fountains.size() - 1, -1, -1):
		if fountains[index].contains_world_point(world_position):
			return fountains[index]
	return null


func place_ink_fountain(world_position: Vector2, record_undo := true) -> Node2D:
	var level := _level_root()
	if level == null:
		return null
	var fountain := InkFountainScene.instantiate() as Node2D
	fountain.name = _unique_level_node_name("InkFountain")
	level.add_child(fountain)
	fountain.global_position = world_position
	# 固定尺寸只存在于打包场景内部，编辑器永远不修改根节点 scale。
	fountain.scale = Vector2.ONE
	fountain.owner = level
	if record_undo:
		_record_edit({"type": &"fountain_place", "target": fountain})
	_update_layout_status()
	return fountain


func delete_ink_fountain(fountain: Node2D) -> bool:
	if not is_instance_valid(fountain) or not fountain.is_in_group(InkFountainScript.GROUP):
		return false
	_record_edit({"type": &"fountain_delete", "position": fountain.global_position, "target": fountain})
	fountain.get_parent().remove_child(fountain)
	fountain.queue_free()
	_update_layout_status()
	return true


func place_portal(world_position: Vector2, destination := "", record_undo := true) -> Node2D:
	var level := _level_root()
	if level == null:
		return null
	var portal := MapPortalScene.instantiate() as Node2D
	portal.name = _unique_level_node_name("Portal")
	portal.target_map = destination
	level.add_child(portal)
	portal.global_position = world_position
	portal.owner = level
	if record_undo:
		_record_edit({"type": &"portal_place", "target": portal})
	_refresh_layout_overlay(portal)
	return portal


func delete_portal(portal: Node2D) -> bool:
	if not is_instance_valid(portal) or not portal.is_in_group(MapPortalScript.GROUP):
		return false
	if _layout_drag_target == portal:
		_finish_layout_drag()
	if _selected_control_target == portal:
		_selected_control_target = null
	_record_edit({"type": &"portal_delete", "position": portal.global_position,
		"destination": portal.target_map, "size": portal.portal_size, "scale": portal.scale, "target": portal})
	portal.get_parent().remove_child(portal)
	portal.queue_free()
	_selected_portal = null
	_refresh_layout_overlay()
	return true


func _portal_choice() -> String:
	return _portal_target_path


func _select_portal(portal: Node2D) -> void:
	_selected_portal = portal
	if not is_instance_valid(portal) or _portal_destination == null:
		return
	_layout_status_label.text = "已选中传送门；左键拖动，双击修改目标地图"


func _refresh_portal_choices() -> void:
	_portal_destination.clear()
	_portal_destination.add_item("下一关（地图列表顺序）")
	_portal_destination.set_item_metadata(0, "")
	for path in MapPortalScript.LevelList.find_levels():
		var index := _portal_destination.item_count
		_portal_destination.add_item(path.get_file().get_basename())
		_portal_destination.set_item_metadata(index, path)
		_portal_destination.set_item_tooltip(index, path)


func _open_portal_menu(portal: Node2D = null) -> void:
	select_control_tool()
	_cancel_layout_drag()
	_portal_menu_target = portal
	_refresh_portal_choices()
	_portal_destination.popup_centered()


func set_portal_destination(portal: Node2D, destination: String) -> bool:
	if not is_instance_valid(portal) or not portal.is_in_group(MapPortalScript.GROUP):
		return false
	if not destination.is_empty() and not MapPortalScript.LevelList.find_levels().has(destination):
		return false
	if portal.target_map != destination:
		_record_edit({"type": &"portal_destination", "target": portal, "old_destination": portal.target_map})
		portal.target_map = destination
	return true


func _on_portal_destination_selected(index: int) -> void:
	_portal_target_path = str(_portal_destination.get_item_metadata(index))
	if is_instance_valid(_portal_menu_target):
		if set_portal_destination(_portal_menu_target, _portal_choice()):
			_layout_status_label.text = "传送门目标已修改；Ctrl+Z 撤销"
	else:
		select_monster_tool(LAYOUT_MODE_PLACE_PORTAL)
		_layout_status_label.text = "目标已选择；左键单击地图放置传送门"
	_portal_menu_target = null


func _build_canvas_size_dialog(parent: Control) -> void:
	_canvas_size_dialog = ConfirmationDialog.new()
	_canvas_size_dialog.name = "CanvasSizeDialog"
	_canvas_size_dialog.title = "新增游玩画布"
	_canvas_size_dialog.theme = EDITOR_THEME
	_canvas_size_dialog.get_ok_button().text = "开始放置"
	parent.add_child(_canvas_size_dialog)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	_canvas_size_dialog.add_child(column)
	for dimension in ["宽度", "高度"]:
		var row := HBoxContainer.new()
		column.add_child(row)
		var label := Label.new()
		label.text = dimension + "（像素）"
		label.custom_minimum_size.x = 105.0
		row.add_child(label)
		var input := SpinBox.new()
		input.min_value = 16.0
		input.max_value = 4096.0
		input.step = 1.0
		input.custom_minimum_size.x = 170.0
		input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(input)
		if dimension == "宽度":
			_canvas_width_input = input
		else:
			_canvas_height_input = input
	_canvas_size_dialog.confirmed.connect(_confirm_canvas_size)
	_canvas_size_dialog.canceled.connect(_update_monster_buttons)


func _open_canvas_size_dialog() -> void:
	if _canvas_size_dialog == null:
		return
	_canvas_width_input.value = clampi(_new_canvas_size.x, 16, 4096)
	_canvas_height_input.value = clampi(_new_canvas_size.y, 16, 4096)
	_canvas_size_dialog.popup_centered(Vector2i(360, 180))


func _confirm_canvas_size() -> void:
	_new_canvas_size = Vector2i(int(_canvas_width_input.value), int(_canvas_height_input.value))
	if _monster_mode == LAYOUT_MODE_PLACE_CANVAS:
		select_monster_tool(MONSTER_MODE_NONE)
	select_monster_tool(LAYOUT_MODE_PLACE_CANVAS)
	_layout_status_label.text = "已设置画布 %d × %d 像素；左键单击地图放置" % [
		_new_canvas_size.x, _new_canvas_size.y]


func place_play_canvas(world_position: Vector2, record_undo := true,
		size: Vector2i = Vector2i.ZERO) -> Node2D:
	var level := _level_root()
	if level == null:
		return null
	if size == Vector2i.ZERO:
		size = _new_canvas_size
	size = Vector2i(maxi(size.x, 1), maxi(size.y, 1))
	var canvas = PlayCanvasScene.instantiate()
	if canvas == null:
		return null
	canvas.name = _unique_level_node_name("PlayCanvas")
	# 入树前确定尺寸，只分配一次画布贴图与工作台布局。
	canvas.set("canvas_size", size)
	level.add_child(canvas)
	canvas.add_to_group(PLAY_CANVAS_GROUP, true)
	canvas.global_position = world_position - Vector2(canvas.get("canvas_size")) * 0.5
	canvas.visible = false
	canvas.set("active", false)
	canvas.owner = level
	if canvas.has_method("set_ink_free"):
		canvas.call("set_ink_free", true)
	if _canvas == null:
		_set_primary_play_canvas(canvas)
	if record_undo:
		_record_edit({"type": &"play_canvas_place", "target": canvas})
	_refresh_layout_overlay(canvas)
	return canvas as Node2D


func _set_primary_play_canvas(canvas: Node2D) -> void:
	_canvas = canvas
	canvas_path = get_path_to(canvas) if is_instance_valid(canvas) else NodePath("")


func delete_play_canvas(canvas: Node2D, record_undo := true) -> bool:
	if not is_instance_valid(canvas) or not _play_canvases().has(canvas):
		return false
	if _layout_drag_target == canvas:
		_finish_layout_drag()
	var was_primary: bool = canvas == _canvas
	var old_path := canvas_path
	var level := _level_root()
	if level == null or not level.is_ancestor_of(canvas):
		return false
	var parent := canvas.get_parent()
	if record_undo:
		# 保留原节点，撤销时原样恢复画布内像素、工具状态与尺寸。
		_record_edit({"type": &"play_canvas_delete", "target": canvas,
			"was_primary": was_primary, "old_path": old_path, "parent": parent})
	parent.remove_child(canvas)
	if was_primary:
		var remaining := _play_canvases()
		_set_primary_play_canvas(remaining[0] if not remaining.is_empty() else null)
	if _selected_control_target == canvas:
		_selected_control_target = null
	_refresh_layout_overlay()
	return true


func _restore_deleted_play_canvas(edit: Dictionary) -> bool:
	var canvas: Node2D = edit.get("target")
	var level := _level_root()
	if not is_instance_valid(canvas) or level == null or canvas.get_parent() != null:
		return false
	var parent: Node = edit.get("parent", level)
	if not is_instance_valid(parent) or (parent != level and not level.is_ancestor_of(parent)):
		parent = level
	parent.add_child(canvas)
	canvas.owner = level
	canvas.visible = false if active else true
	canvas.active = not active
	if bool(edit.get("was_primary", false)):
		_set_primary_play_canvas(canvas)
		canvas_path = edit.get("old_path", canvas_path)
	_refresh_layout_overlay(canvas)
	return true


func _undo_placed_layout_node(target: Node) -> bool:
	if not is_instance_valid(target) or target.get_parent() == null:
		return false
	var was_primary: bool = target == _canvas
	target.get_parent().remove_child(target)
	if was_primary:
		var remaining := _play_canvases()
		_set_primary_play_canvas(remaining[0] if not remaining.is_empty() else null)
	target.queue_free()
	_refresh_layout_overlay()
	return true
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
	palette_toggle.offset_left = -96.0
	# 避开右上角现有的日志、ESC 等按钮。
	palette_toggle.offset_top = 85.0
	palette_toggle.offset_right = -16.0
	palette_toggle.offset_bottom = 129.0
	palette_toggle.text = "工具\nCapslock"
	palette_toggle.tooltip_text = "收起 / 展开右侧地图编辑工具栏"
	palette_toggle.focus_mode = Control.FOCUS_NONE
	palette_toggle.theme = EDITOR_THEME
	palette_toggle.add_theme_font_size_override("font_size", 15)
	palette_toggle.pressed.connect(_toggle_monster_palette_panel)
	root.add_child(palette_toggle)
	_monster_palette_toggle = palette_toggle

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -592.0
	panel.offset_top = 134.0
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
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)
	var column := VBoxContainer.new()
	column.name = "VBox"
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	var color_title := Label.new()
	color_title.name = "ColorTitle"
	color_title.text = "色盘"
	color_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	color_title.theme_type_variation = &"TitleLabel"
	column.add_child(color_title)
	var color_grid := GridContainer.new()
	color_grid.name = "ColorGrid"
	color_grid.columns = InkPalette.ink_count()
	color_grid.add_theme_constant_override("h_separation", 18)
	color_grid.add_theme_constant_override("v_separation", 12)
	column.add_child(color_grid)
	for index in InkPalette.ink_count():
		var color := InkPalette.color_at(index)
		var color_style := StyleBoxFlat.new()
		color_style.bg_color = color
		color_style.corner_radius_top_left = 32
		color_style.corner_radius_top_right = 32
		color_style.corner_radius_bottom_left = 32
		color_style.corner_radius_bottom_right = 32
		color_style.border_width_left = 2
		color_style.border_width_top = 2
		color_style.border_width_right = 2
		color_style.border_width_bottom = 2
		color_style.border_color = Color(0.035, 0.031, 0.024, 1.0)
		var color_button := Button.new()
		color_button.name = "Ink%dButton" % index
		color_button.custom_minimum_size = Vector2(64.0, 64.0)
		color_button.tooltip_text = InkPalette.ink_name(index)
		color_button.focus_mode = Control.FOCUS_NONE
		color_button.toggle_mode = true
		color_button.add_theme_stylebox_override("normal", color_style)
		color_button.add_theme_stylebox_override("hover", color_style)
		color_button.add_theme_stylebox_override("pressed", color_style)
		color_button.pressed.connect(_select_editor_ink.bind(index))
		color_grid.add_child(color_button)
		_editor_ink_buttons.append(color_button)
		InkSelectionIndicator.install(color_button, color)
	_editor_ink_label = Label.new()
	_editor_ink_label.name = "SelectedInkLabel"
	_editor_ink_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_editor_ink_label.text = "当前：黑墨"
	column.add_child(_editor_ink_label)
	if _map_canvas != null:
		if not _map_canvas.ink_selected.is_connected(_refresh_editor_ink):
			_map_canvas.ink_selected.connect(_refresh_editor_ink)
		_refresh_editor_ink(_map_canvas.surface.selected_ink, false)
	var brush_row := HBoxContainer.new()
	brush_row.name = "BrushSizeRow"
	brush_row.add_theme_constant_override("separation", 12)
	column.add_child(brush_row)
	var brush_label := Label.new()
	brush_label.name = "BrushSizeLabel"
	brush_label.custom_minimum_size.x = 100.0
	brush_row.add_child(brush_label)
	var brush_slider := HSlider.new()
	brush_slider.name = "BrushSizeSlider"
	brush_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brush_slider.custom_minimum_size = Vector2(160, 32)
	brush_slider.focus_mode = Control.FOCUS_NONE
	var source_slider: HSlider = _map_canvas.brush_panel.get_node("PenSlider")
	brush_slider.min_value = source_slider.min_value
	brush_slider.max_value = source_slider.max_value
	brush_slider.step = source_slider.step
	brush_slider.value = _map_canvas.surface.brush_size
	brush_label.text = "粗细：%d px" % int(brush_slider.value)
	brush_slider.tooltip_text = "调整画笔、橡皮和形状的笔触直径"
	brush_row.add_child(brush_slider)
	brush_slider.value_changed.connect(func(value: float):
		_map_canvas.set_brush_size(int(round(value)))
		source_slider.set_value_no_signal(value)
		brush_label.text = "粗细：%d px" % int(round(value))
	)
	source_slider.value_changed.connect(func(value: float):
		brush_slider.set_value_no_signal(value)
		brush_label.text = "粗细：%d px" % int(round(value))
	)
	var color_separator := HSeparator.new()
	column.add_child(color_separator)
	var edit_actions := HBoxContainer.new()
	edit_actions.name = "EditActions"
	column.add_child(edit_actions)
	var history := preload("res://actor/canvas/src/history_actions.gd").new()
	history.name = "HistoryActions"
	history.canvas = _map_canvas
	history.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit_actions.add_child(history)
	var save_map_button := Button.new()
	save_map_button.name = "SaveMapButton"
	save_map_button.text = "保存地图"
	save_map_button.tooltip_text = "打开地图保存窗口（F5），确认后才写入地图"
	save_map_button.focus_mode = Control.FOCUS_NONE
	save_map_button.pressed.connect(_open_map_save_window)
	edit_actions.add_child(save_map_button)
	var view_actions := HBoxContainer.new()
	view_actions.name = "ViewActions"
	column.add_child(view_actions)
	_editor_player_visibility = Button.new()
	_editor_player_visibility.name = "PlayerVisibility"
	_editor_player_visibility.text = "显示小人"
	_editor_player_visibility.tooltip_text = "只切换编辑器中的角色显示，不改变出生点或物理"
	_editor_player_visibility.toggle_mode = true
	_editor_player_visibility.focus_mode = Control.FOCUS_NONE
	_editor_player_visibility.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_editor_player_visibility.toggled.connect(_map_canvas._on_player_visibility_toggled)
	view_actions.add_child(_editor_player_visibility)
	_editor_nail_visibility = Button.new()
	_editor_nail_visibility.name = "NailVisibility"
	_editor_nail_visibility.text = "显示钉子"
	_editor_nail_visibility.tooltip_text = "只切换钉子外观，保留固定点；不修改工具栏图标"
	_editor_nail_visibility.toggle_mode = true
	_editor_nail_visibility.focus_mode = Control.FOCUS_NONE
	_editor_nail_visibility.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_editor_nail_visibility.toggled.connect(_map_canvas._on_nail_visibility_toggled)
	view_actions.add_child(_editor_nail_visibility)
	_refresh_editor_visibility()

	var mechanism_title := Label.new()
	mechanism_title.name = "MechanismTitle"
	mechanism_title.text = "机关部件"
	mechanism_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mechanism_title.theme_type_variation = &"TitleLabel"
	column.add_child(mechanism_title)
	var mechanism_grid := GridContainer.new()
	mechanism_grid.name = "MechanismGrid"
	mechanism_grid.columns = 3
	column.add_child(mechanism_grid)
	_gear8_button = Button.new()
	_gear8_button.name = "Gear8ToolButton"
	_gear8_button.text = "八齿齿轮"
	_gear8_button.tooltip_text = "八齿齿轮：按下定圆心，拖动定半径；使用当前墨水颜色；操纵工具可移动"
	_gear8_button.toggle_mode = true
	_gear8_button.focus_mode = Control.FOCUS_NONE
	_gear8_button.custom_minimum_size = Vector2(96.0, 44.0)
	_gear8_button.pressed.connect(select_gear_tool.bind(8))
	mechanism_grid.add_child(_gear8_button)
	_gear_button = Button.new()
	_gear_button.name = "GearToolButton"
	_gear_button.text = "十二齿齿轮"
	_gear_button.tooltip_text = "十二齿齿轮：按下定圆心，拖动定半径；使用当前墨水颜色；操纵工具可移动；再次点击退出"
	_gear_button.toggle_mode = true
	_gear_button.focus_mode = Control.FOCUS_NONE
	_gear_button.custom_minimum_size = Vector2(96.0, 44.0)
	_gear_button.pressed.connect(select_gear_tool.bind(12))
	mechanism_grid.add_child(_gear_button)
	_sync_gear_button()
	column.add_child(HSeparator.new())

	var title := Label.new()
	title.name = "MonsterTitle"
	title.text = "小怪放置"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.theme_type_variation = &"TitleLabel"
	column.add_child(title)
	var monster_hint_label := Label.new()
	monster_hint_label.name = "MonsterHint"
	monster_hint_label.text = "左键选中拖动 · 右键删除"
	monster_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	monster_hint_label.add_theme_font_size_override("font_size", 14)
	monster_hint_label.add_theme_color_override("font_color", Color(0.35, 0.3, 0.2, 0.8))
	column.add_child(monster_hint_label)
	var monster_grid := GridContainer.new()
	monster_grid.name = "MonsterGrid"
	monster_grid.columns = 3
	monster_grid.add_theme_constant_override("h_separation", 6)
	monster_grid.add_theme_constant_override("v_separation", 6)
	column.add_child(monster_grid)
	for index in MONSTER_NAMES.size():
		var button := Button.new()
		button.name = MONSTER_NODE_NAMES[index] + "Button"
		button.set_meta("monster_kind", MONSTER_KINDS[index])
		button.text = MONSTER_NAMES[index]
		button.tooltip_text = "选择后在地图上单击放置%s" % MONSTER_NAMES[index]
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(96.0, 44.0)
		button.pressed.connect(select_monster_tool.bind(MONSTER_KINDS[index]))
		monster_grid.add_child(button)
		_monster_buttons.append(button)

	_reset_monster_scale_button = Button.new()
	_reset_monster_scale_button.name = "ResetMonsterScaleButton"
	_reset_monster_scale_button.text = "恢复原始大小"
	_reset_monster_scale_button.tooltip_text = "恢复当前选中小怪的原始大小"
	_reset_monster_scale_button.focus_mode = Control.FOCUS_NONE
	_reset_monster_scale_button.custom_minimum_size = Vector2(96.0, 44.0)
	_reset_monster_scale_button.pressed.connect(_reset_selected_monster_scale)
	monster_grid.add_child(_reset_monster_scale_button)

	var separator := HSeparator.new()
	column.add_child(separator)
	var dialogue_title := Label.new()
	dialogue_title.name = "DialogueTitle"
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
	text_title.name = "TextTitle"
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

	var layout_separator := HSeparator.new()
	column.add_child(layout_separator)
	var layout_title := Label.new()
	layout_title.name = "LayoutTitle"
	layout_title.text = "地图与布局"
	layout_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layout_title.theme_type_variation = &"TitleLabel"
	column.add_child(layout_title)
	var layout_grid := GridContainer.new()
	layout_grid.name = "LayoutGrid"
	layout_grid.columns = 3
	layout_grid.add_theme_constant_override("h_separation", 6)
	layout_grid.add_theme_constant_override("v_separation", 6)
	column.add_child(layout_grid)
	var layout_tools := [
		[LAYOUT_MODE_PLACE_RESPAWN, "PlaceRespawnButton", "新增复活点", "单击空地新增橙色复活点；按在已有复活点上拖动即可移动；右键删除"],
		[LAYOUT_MODE_MOVE_RESPAWN, "MoveRespawnButton", "移动复活点", "拖动橙色标记调整复活位置；右键删除"],
		[LAYOUT_MODE_DELETE_RESPAWN, "DeleteRespawnButton", "删除复活点", "单击橙色复活点删除；Ctrl+Z 撤销"],
		[LAYOUT_MODE_PLACE_CANVAS, "PlacePlayCanvasButton", "新增画布", "先设置宽高，再单击地图放置画布；按在已有画布上拖动即可移动；右键删除"],
		[LAYOUT_MODE_MOVE_CANVAS, "MovePlayCanvasButton", "移动画布", "左键拖动画布；右键删除画布；Ctrl+Z 撤销"],
		[LAYOUT_MODE_DELETE_CANVAS, "DeletePlayCanvasButton", "删除画布", "单击画布删除；Ctrl+Z 撤销"],
		[LAYOUT_MODE_PLACE_PORTAL, "PlacePortalButton", "新增传送门", "选择目标地图后单击地图放置；按在已有传送门上拖动即可移动；右键删除"],
		[LAYOUT_MODE_DELETE_PORTAL, "DeletePortalButton", "删除传送门", "单击传送门删除；Ctrl+Z 撤销"],
		[LAYOUT_MODE_FOUNTAIN, "InkFountainButton", "墨泉", "左键放置固定尺寸墨泉，按在已有墨泉上拖动即可移动；右键删除；Ctrl+Z 撤销"],
	]
	for tool in layout_tools:
		var layout_button := Button.new()
		layout_button.name = str(tool[1])
		layout_button.text = str(tool[2])
		layout_button.tooltip_text = str(tool[3])
		layout_button.toggle_mode = true
		layout_button.focus_mode = Control.FOCUS_NONE
		layout_button.custom_minimum_size = Vector2(96.0, 44.0)
		if int(tool[0]) == LAYOUT_MODE_PLACE_PORTAL:
			layout_button.pressed.connect(_open_portal_menu)
		elif int(tool[0]) == LAYOUT_MODE_PLACE_CANVAS:
			layout_button.pressed.connect(_open_canvas_size_dialog)
		else:
			layout_button.pressed.connect(select_monster_tool.bind(int(tool[0])))
		layout_grid.add_child(layout_button)
		_layout_buttons[int(tool[0])] = layout_button
	_build_canvas_size_dialog(root)
	_portal_destination = PopupMenu.new()
	_portal_destination.name = "PortalMapMenu"
	_portal_destination.theme = EDITOR_THEME
	_portal_destination.min_size = Vector2i(300, 0)
	root.add_child(_portal_destination)
	_refresh_portal_choices()
	_portal_destination.index_pressed.connect(_on_portal_destination_selected)

	_layout_status_label = Label.new()
	_layout_status_label.name = "LayoutStatus"
	_layout_status_label.text = "出生点 1 个；复活点和画布可新增"
	_layout_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_layout_status_label)

	_monster_status_label = Label.new()
	_monster_status_label.name = "MonsterStatus"
	_monster_status_label.text = "未选中小怪"
	_monster_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_monster_status_label)

	var hint := Label.new()
	hint.text = "放置：左键单击　对话：Enter 下一句　Ctrl+Z 撤销"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(hint)
	_build_ink_quota_table(column)
	panel.visible = false


## 「关卡墨水配额」：每种墨水的满瓶量，保存进关卡根节点的 starting_ink，
## 所以只对当前地图生效。没填的颜色沿用玩家自己的 max_ink。
func _build_ink_quota_table(column: VBoxContainer) -> void:
	column.add_child(HSeparator.new())
	var title := Label.new()
	title.name = "InkQuotaTitle"
	title.text = "关卡墨水配额（本图生效）"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.theme_type_variation = &"TitleLabel"
	column.add_child(title)
	var grid := GridContainer.new()
	grid.name = "InkQuotaGrid"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 4)
	column.add_child(grid)
	for index in InkPalette.ink_count():
		var material: Resource = InkPalette.ink_at(index)
		var id: int = InkPalette.material_id_of(material)
		var label := Label.new()
		label.text = InkPalette.ink_name(index)
		label.custom_minimum_size.x = 64.0
		grid.add_child(label)
		var field := SpinBox.new()
		field.name = "InkQuota%d" % id
		field.min_value = 0.0
		field.max_value = 200000.0
		field.step = 100.0
		field.value = ink_quota_of(id)
		field.suffix = " px"
		field.tooltip_text = "%s在本关的满瓶量；只写进当前地图，不填就沿用玩家默认值" % InkPalette.ink_name(index)
		field.value_changed.connect(_on_ink_quota_changed.bind(id))
		grid.add_child(field)
		_ink_quota_fields[id] = field
	var reset := Button.new()
	reset.name = "ResetInkQuotaButton"
	reset.text = "恢复默认配额"
	reset.tooltip_text = "清空本图的自定义配额，所有颜色回到玩家默认满瓶量"
	reset.focus_mode = Control.FOCUS_NONE
	reset.pressed.connect(reset_ink_quota)
	column.add_child(reset)


## 本关该墨水的满瓶量：地图根节点 starting_ink 里有就用自己的，没有就用玩家默认值。
func ink_quota_of(material_id: int) -> float:
	var override := _ink_quota_overrides()
	if override.has(material_id):
		return float(override[material_id])
	var health = _ink_health()
	return health.max_ink if health != null else 20000.0


func _ink_quota_overrides() -> Dictionary:
	var level := _level_root()
	return level.starting_ink if level != null and level.get("starting_ink") != null else {}


func _ink_health():
	return _player.get_node_or_null("InkHealth") if is_instance_valid(_player) else null


func _on_ink_quota_changed(value: float, material_id: int) -> void:
	var level := _level_root()
	if level == null:
		return
	var before := _ink_quota_overrides().duplicate()
	level.starting_ink[material_id] = maxf(0.0, value)
	_apply_ink_quota()
	_record_edit({"type": &"ink_quota", "before": before, "after": _ink_quota_overrides().duplicate()})


## 清空本图配额，全部回到玩家默认满瓶量。
func reset_ink_quota() -> void:
	var level := _level_root()
	if level == null or _ink_quota_overrides().is_empty():
		return
	var before := _ink_quota_overrides().duplicate()
	level.starting_ink.clear()
	_apply_ink_quota()
	_record_edit({"type": &"ink_quota", "before": before, "after": {}})


## 配额改了要立刻作用到这一局：容量重新读取，现存量夹到新容量。
func _apply_ink_quota() -> void:
	var health = _ink_health()
	if health != null:
		health.reload_caps()
	_sync_ink_quota_fields()


func _sync_ink_quota_fields() -> void:
	for id in _ink_quota_fields:
		(_ink_quota_fields[id] as SpinBox).set_value_no_signal(ink_quota_of(id))


func _restore_ink_quota(values: Dictionary) -> bool:
	var level := _level_root()
	if level == null:
		return false
	var override: Dictionary = level.starting_ink
	override.clear()
	for id in values:
		override[int(id)] = float(values[id])
	_apply_ink_quota()
	return true


func _refresh_editor_visibility() -> void:
	if _map_canvas == null:
		return
	if is_instance_valid(_editor_player_visibility):
		_editor_player_visibility.set_pressed_no_signal(_player != null and _player.visible)
	if is_instance_valid(_editor_nail_visibility):
		_editor_nail_visibility.set_pressed_no_signal(_map_canvas._nails_visible)


func _toggle_monster_palette_panel() -> void:
	if _monster_palette_panel == null or _monster_palette_toggle == null:
		return
	_monster_palette_panel.visible = not _monster_palette_panel.visible
	_monster_palette_toggle.text = "关闭" if _monster_palette_panel.visible else "工具\nCapslock"
	_monster_palette_toggle.tooltip_text = (
		"收起右侧地图编辑工具栏" if _monster_palette_panel.visible
		else "展开右侧地图编辑工具栏"
	)
	# 展开和收起时都固定在屏幕最右侧，不再横跨画布中央区域。
	_monster_palette_toggle.offset_left = -96.0
	_monster_palette_toggle.offset_right = -16.0


func _select_editor_ink(index: int) -> void:
	if _map_canvas != null and _map_canvas.has_method("select_ink"):
		_map_canvas.call("select_ink", index)


func _refresh_editor_ink(index: int, animate := true) -> void:
	for i in _editor_ink_buttons.size():
		var button := _editor_ink_buttons[i]
		button.set_pressed_no_signal(i == index)
		button.get_node("InkSelectionIndicator").set_selected(i == index, animate)
	if is_instance_valid(_editor_ink_label):
		_editor_ink_label.text = "当前墨水：%s" % InkPalette.ink_name(index)


func select_monster_tool(mode: int) -> void:
	if mode != MONSTER_MODE_NONE and mode != MONSTER_MODE_DELETE and mode != MONSTER_MODE_ADJUST \
	and mode != DIALOGUE_MODE_PLACE and mode != DIALOGUE_MODE_DELETE \
	and mode != TEXT_MODE_PLACE and mode != TEXT_MODE_DELETE \
	and mode != CONTROL_MODE and not LAYOUT_MODES.has(mode) \
	and not MONSTER_KINDS.has(mode):
		mode = MONSTER_MODE_NONE
	elif mode == _monster_mode:
		mode = MONSTER_MODE_NONE
	_monster_mode = mode
	if _map_canvas != null and (mode != MONSTER_MODE_NONE \
	or _map_canvas.surface.tool in [CanvasSurfaceScript.Tool.GEAR, CanvasSurfaceScript.Tool.GEAR_8]):
		# 普通手不在画布上落笔；放怪期间用它避免一次单击同时画墨。
		_syncing_canvas_tool = true
		_map_canvas.set_tool(0)
		_syncing_canvas_tool = false
	if mode != MONSTER_MODE_ADJUST:
		_set_selected_monster(null)
	if not LAYOUT_MODES.has(mode):
		_cancel_layout_drag()
	if mode != CONTROL_MODE:
		_selected_control_target = null
		_set_imported_image_selection(null)
	_update_monster_buttons()
	_refresh_layout_overlay()


func select_gear_tool(teeth := 12) -> void:
	if not active or _map_canvas == null or not _map_canvas._map_editor_mode:
		return
	var gear_tool: int = CanvasSurfaceScript.Tool.GEAR_8 if teeth == 8 else CanvasSurfaceScript.Tool.GEAR
	if _map_canvas.surface.tool == gear_tool:
		_map_canvas.set_tool(CanvasSurfaceScript.Tool.HAND)
		return
	select_monster_tool(MONSTER_MODE_NONE)
	_map_canvas.set_tool(gear_tool)


func _sync_gear_button() -> void:
	if _gear8_button != null:
		_gear8_button.set_pressed_no_signal(_map_canvas != null \
			and _map_canvas.surface.tool == CanvasSurfaceScript.Tool.GEAR_8)
	if _gear_button != null:
		_gear_button.set_pressed_no_signal(_map_canvas != null \
			and _map_canvas.surface.tool == CanvasSurfaceScript.Tool.GEAR)


func select_control_tool() -> void:
	if _monster_mode == CONTROL_MODE:
		return
	select_monster_tool(CONTROL_MODE)


func _update_monster_buttons() -> void:
	_sync_gear_button()
	for index in _monster_buttons.size():
		_monster_buttons[index].set_pressed_no_signal(_monster_mode == int(_monster_buttons[index].get_meta("monster_kind")))
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
	for mode in _layout_buttons:
		(_layout_buttons[mode] as Button).set_pressed_no_signal(_monster_mode == int(mode))
	_update_layout_status()


func _on_canvas_tool_changed(_tool: int) -> void:
	_sync_gear_button()
	if _syncing_canvas_tool or _monster_mode == MONSTER_MODE_NONE:
		return
	_monster_mode = MONSTER_MODE_NONE
	_cancel_layout_drag()
	_update_monster_buttons()
	_refresh_layout_overlay()


func place_monster(
	kind: int,
	world_position: Vector2,
	record_undo := true,
	monster_id := "",
	monster_scale := Vector2.ZERO
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
	var fixed_scale_value: float = MONSTER_FIXED_SCALES.get(kind, 1.0)
	# 无指定尺寸时采用默认值；删除撤销/恢复必须保留用户缩放。
	monster.scale = Vector2.ONE * fixed_scale_value if monster_scale == Vector2.ZERO else monster_scale
	container.add_child(monster, true)
	monster.global_position = world_position
	if monster.has_method("sync_physics_from_node"):
		monster.sync_physics_from_node(true)
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


func _set_monster_physics_paused(paused: bool) -> void:
	var container := _ensure_monster_container()
	if container == null:
		return
	for child in container.get_children():
		if child.has_method("set_editor_physics_paused"):
			child.set_editor_physics_paused(paused)


func _find_monster_at(world_position: Vector2) -> Node2D:
	var container := _ensure_monster_container()
	if container == null:
		return null
	var children := container.get_children()
	var margin := _layout_pick_radius() * (8.0 / 28.0)
	for index in range(children.size() - 1, -1, -1):
		var child = children[index]
		if not child is Node2D or not child.is_in_group(MapMonsterScript.GROUP):
			continue
		if child.editor_contains_point(world_position, margin):
			return child
	return null


func _set_selected_monster(monster: Node2D) -> void:
	_flush_monster_drag_move()
	_unlock_monster_drag_view()
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
	var next_scale := maxf(old_scale.x + amount, MONSTER_MIN_SCALE)
	if not is_finite(next_scale) or is_equal_approx(next_scale, old_scale.x):
		return
	_selected_monster.scale = Vector2.ONE * next_scale
	if _selected_monster.has_method("sync_physics_from_node"):
		_selected_monster.sync_physics_from_node(true)
	_record_monster_transform(_selected_monster, old_position, old_scale)


func _reset_selected_monster_scale() -> void:
	if not is_instance_valid(_selected_monster):
		return
	var old_position := _selected_monster.global_position
	var old_scale := _selected_monster.scale
	# 恢复到该种类的固定大小，与"平路"关卡一致。
	var kind: int = int(_selected_monster.get("kind"))
	var fixed_scale_value: float = MONSTER_FIXED_SCALES.get(kind, 1.0)
	_selected_monster.scale = Vector2.ONE * fixed_scale_value
	if _selected_monster.has_method("sync_physics_from_node"):
		_selected_monster.sync_physics_from_node(true)
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
		"target": trigger,
		"scale": trigger.scale,
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
		"target": label,
		"scale": label.scale,
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
	var children := container.get_children()
	for index in range(children.size() - 1, -1, -1):
		var child = children[index]
		if child is Label and child.is_in_group(MapTextScript.GROUP) \
		and child.contains_world_point(world_position, _layout_pick_radius() * (8.0 / 28.0)):
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


#region 地图图片
func _ensure_image_container() -> Node2D:
	var level := _level_root()
	if level == null:
		return null
	var container := level.get_node_or_null("MapImages") as Node2D
	if container == null:
		container = Node2D.new()
		container.name = "MapImages"
		level.add_child(container)
		container.owner = level
	return container


## 仅供撤销旧地图图片删除使用；不再提供导入或新放置入口。
func _restore_deleted_image(source_data: PackedByteArray, source_format: String,
		filename: String, world_position: Vector2, image_scale: Vector2) -> Sprite2D:
	if source_data.is_empty():
		return null
	var container := _ensure_image_container()
	if container == null:
		return null
	var image := MapImportedImageScript.new() as Sprite2D
	image.name = "ImportedImage"
	image.source_data = source_data
	image.source_format = source_format
	image.original_filename = filename
	container.add_child(image, true)
	if image.texture == null:
		container.remove_child(image)
		image.queue_free()
		return null
	image.global_position = world_position
	image.scale = image_scale
	image.owner = _level_root()
	return image


func _imported_images() -> Array:
	var level := _level_root()
	var container := level.get_node_or_null("MapImages") if level != null else null
	return container.get_children() if container != null else []


func _find_imported_image_at(world_position: Vector2) -> Sprite2D:
	var images := _imported_images()
	for index in range(images.size() - 1, -1, -1):
		var image = images[index]
		if image is Sprite2D and (image.resize_handle_hit(world_position)
			or image.contains_world_point(world_position, _layout_pick_radius() * (8.0 / 28.0))):
			return image
	return null


func _set_imported_image_selection(target) -> void:
	for image in _imported_images():
		image.editor_selected = image == target


func delete_imported_image(image: Sprite2D) -> bool:
	if not is_instance_valid(image) or not image.is_in_group(MapImportedImageScript.GROUP):
		return false
	if _layout_drag_target == image:
		_finish_layout_drag()
	if _selected_control_target == image:
		_selected_control_target = null
	_record_edit({"type": &"image_delete", "target": image,
		"position": image.global_position, "scale": image.scale,
		"source_data": image.source_data, "source_format": image.source_format,
		"filename": image.original_filename})
	image.get_parent().remove_child(image)
	image.queue_free()
	_set_imported_image_selection(null)
	return true
#endregion


func _on_canvas_edit_committed() -> void:
	if active:
		_record_edit({"type": &"canvas"})


func _on_map_changed() -> void:
	if active:
		_queue_edit_auto_save()


func _record_edit(edit: Dictionary) -> void:
	_edit_history.append(edit)
	for item in _redo_history:
		_dispose_history_edit(item.edit)
	_redo_history.clear()
	if edit.get("type", &"") != &"canvas" and _map_canvas != null:
		var surface = _map_canvas.get_node_or_null("CanvasSurface")
		if surface != null:
			surface._redo_steps.clear()
	if _edit_history.size() > MAX_EDIT_HISTORY:
		_dispose_history_edit(_edit_history.pop_front())
	_queue_edit_auto_save()


func _dispose_history_edit(edit: Dictionary) -> void:
	if edit.get("type", &"") != &"play_canvas_delete":
		return
	var canvas = edit.get("target")
	if is_instance_valid(canvas) and canvas.get_parent() == null:
		canvas.free()


func _clear_edit_history() -> void:
	for edit in _edit_history:
		_dispose_history_edit(edit)
	for item in _redo_history:
		_dispose_history_edit(item.edit)
	_edit_history.clear()
	_redo_history.clear()


## 按绘图与小怪编辑发生的实际顺序撤销，供 Ctrl+Z 和自动测试调用。
func undo_last_edit() -> bool:
	if is_instance_valid(_layout_drag_target) and _layout_drag_target is GearBearing:
		_cancel_layout_drag()
	if _edit_history.is_empty():
		return false
	var edit: Dictionary = _edit_history.pop_back()
	var redo_data := _capture_redo_data(edit)
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
			var trigger = place_dialogue_trigger(
				edit.get("position", Vector2.ZERO),
				PackedStringArray(edit.get("lines", PackedStringArray())),
				false,
				str(edit.get("id", ""))
			)
			if trigger != null:
				trigger.scale = edit.get("scale", Vector2.ONE)
				_rebind_history_target(edit.get("target"), trigger)
				edit["target"] = trigger
				changed = true
		&"text_place":
			changed = _remove_map_text_by_id(str(edit.get("id", "")))
		&"image_delete":
			var image = _restore_deleted_image(
				edit.get("source_data", PackedByteArray()), str(edit.get("source_format", "")),
				str(edit.get("filename", "")), edit.get("position", Vector2.ZERO),
				edit.get("scale", Vector2.ONE))
			if image != null:
				_rebind_history_target(edit.get("target"), image)
				edit["target"] = image
				changed = true
		&"text_delete":
			var label = place_map_text(
				edit.get("position", Vector2.ZERO),
				str(edit.get("text", "")),
				false,
				str(edit.get("id", ""))
			)
			if label != null:
				label.scale = edit.get("scale", Vector2.ONE)
				_rebind_history_target(edit.get("target"), label)
				edit["target"] = label
				changed = true
		&"layout_move", &"object_transform":
			var target = edit.get("target")
			if is_instance_valid(target):
				target.global_position = edit.get("old_position", target.global_position)
				target.scale = edit.get("old_scale", target.scale)
				if target.has_method("sync_physics_from_node"):
					target.sync_physics_from_node(true)
				_refresh_layout_overlay()
				changed = true
		&"respawn_place", &"play_canvas_place", &"portal_place", &"fountain_place":
			changed = _undo_placed_layout_node(edit.get("target"))
		&"play_canvas_delete":
			changed = _restore_deleted_play_canvas(edit)
		&"fountain_delete":
			var fountain = place_ink_fountain(edit.get("position", Vector2.ZERO), false)
			if fountain != null:
				_rebind_history_target(edit.get("target"), fountain)
				edit["target"] = fountain
				changed = true
		&"respawn_delete":
			var respawn = place_respawn_point(edit.get("position", Vector2.ZERO), false)
			if respawn != null:
				_rebind_history_target(edit.get("target"), respawn)
				edit["target"] = respawn
				changed = true
		&"ink_quota":
			changed = _restore_ink_quota(edit.get("before", {}))
		&"portal_destination":
			var portal = edit.get("target")
			if is_instance_valid(portal):
				portal.target_map = edit.get("old_destination", "")
				changed = true
		&"portal_delete":
			var portal = place_portal(edit.get("position", Vector2.ZERO), str(edit.get("destination", "")), false)
			if portal != null:
				portal.portal_size = edit.get("size", portal.portal_size)
				portal.scale = edit.get("scale", Vector2.ONE)
				_rebind_history_target(edit.get("target"), portal)
				edit["target"] = portal
				changed = true
	if changed:
		_redo_history.append({"edit": edit, "data": redo_data})
		if _redo_history.size() > MAX_EDIT_HISTORY:
			_dispose_history_edit(_redo_history.pop_front().edit)
		_queue_edit_auto_save()
	else:
		_edit_history.append(edit)
	return changed


func _find_editor_node(container: Node, editor_id: String) -> Node:
	if container == null or editor_id.is_empty():
		return null
	for child in container.get_children():
		if str(child.get("editor_id")) == editor_id:
			return child
	return null


func _capture_redo_data(edit: Dictionary) -> Dictionary:
	var data := {}
	var kind: StringName = edit.get("type", &"")
	var id := str(edit.get("id", ""))
	var node: Node = null
	match kind:
		&"monster_place":
			node = _find_editor_node(_ensure_monster_container(), id)
			if node is Node2D:
				data = {"kind": int(node.get("kind")), "position": node.global_position,
					"scale": node.scale}
		&"dialogue_place":
			node = _find_editor_node(_ensure_dialogue_container(), id)
			if node is Node2D:
				data = {"position": node.global_position, "scale": node.scale,
					"lines": PackedStringArray(node.get("lines"))}
		&"text_place":
			node = _find_editor_node(_ensure_text_container(), id)
			if node is Label:
				data = {"position": node.global_position, "scale": node.scale, "text": node.text}
		&"layout_move", &"object_transform", &"respawn_place", &"play_canvas_place", \
		&"portal_place", &"fountain_place":
			node = edit.get("target")
			if is_instance_valid(node) and (node is Node2D or node is Control):
				data = {"position": node.global_position, "scale": node.scale}
				if kind == &"play_canvas_place":
					data["size"] = node.get("canvas_size")
				elif kind == &"portal_place":
					data["destination"] = node.target_map
					data["size"] = node.portal_size
		&"portal_destination":
			node = edit.get("target")
			if is_instance_valid(node):
				data["destination"] = node.target_map
	if node != null and kind in [&"dialogue_place", &"text_place"]:
		edit["target"] = node
	return data


## 取消最近一次撤销；与 Ctrl+Z 共用按时间排序的编辑记录。
func redo_last_edit() -> bool:
	if is_instance_valid(_layout_drag_target) and _layout_drag_target is GearBearing:
		_cancel_layout_drag()
	if _redo_history.is_empty():
		return false
	var item: Dictionary = _redo_history.pop_back()
	var edit: Dictionary = item.edit
	var data: Dictionary = item.data
	var kind: StringName = edit.get("type", &"")
	var id := str(edit.get("id", ""))
	var changed := false
	var restored: Node = null
	match kind:
		&"canvas":
			var surface: Node = _map_canvas.get_node_or_null("CanvasSurface") if _map_canvas != null else null
			changed = surface != null and surface.redo_last_edit()
		&"monster_place":
			if data.has("kind"):
				restored = place_monster(int(data.kind), data.position, false, id, data.scale)
				changed = restored != null
		&"monster_delete":
			changed = _remove_monster_by_id(id)
		&"monster_transform":
			changed = _apply_monster_transform(id, edit.get("new_position", Vector2.ZERO),
				edit.get("new_scale", Vector2.ONE))
		&"dialogue_place":
			if data.has("lines"):
				restored = place_dialogue_trigger(data.position, data.lines, false, id)
				if restored != null:
					restored.scale = data.scale
					changed = true
		&"dialogue_delete":
			changed = _remove_dialogue_trigger_by_id(id)
		&"text_place":
			if data.has("text"):
				restored = place_map_text(data.position, data.text, false, id)
				if restored != null:
					restored.scale = data.scale
					changed = true
		&"text_delete":
			changed = _remove_map_text_by_id(id)
		&"layout_move", &"object_transform":
			var target = edit.get("target")
			if is_instance_valid(target) and data.has("position"):
				target.global_position = data.position
				target.scale = data.scale
				if target.has_method("sync_physics_from_node"):
					target.sync_physics_from_node(true)
				_refresh_layout_overlay()
				changed = true
		&"respawn_place":
			if data.has("position"):
				restored = place_respawn_point(data.position, false)
				changed = restored != null
		&"play_canvas_place":
			if data.has("position"):
				restored = place_play_canvas(data.position + Vector2(data.size) * 0.5,
					false, data.size)
				if restored != null:
					changed = true
		&"play_canvas_delete":
			changed = delete_play_canvas(edit.get("target"), false)
		&"portal_place":
			if data.has("position"):
				restored = place_portal(data.position, str(data.get("destination", "")), false)
				if restored != null:
					restored.portal_size = data.size
					restored.scale = data.scale
					changed = true
		&"fountain_place":
			if data.has("position"):
				restored = place_ink_fountain(data.position, false)
				changed = restored != null
		&"fountain_delete", &"portal_delete", &"image_delete", &"respawn_delete":
			changed = _undo_placed_layout_node(edit.get("target"))
		&"portal_destination":
			var portal = edit.get("target")
			if is_instance_valid(portal) and data.has("destination"):
				portal.target_map = data.destination
				changed = true
		&"ink_quota":
			changed = _restore_ink_quota(edit.get("after", {}))
	if not changed:
		_redo_history.append(item)
		return false
	if restored != null:
		_rebind_history_target(edit.get("target"), restored)
		edit["target"] = restored
	_edit_history.append(edit)
	if _edit_history.size() > MAX_EDIT_HISTORY:
		_dispose_history_edit(_edit_history.pop_front())
	_queue_edit_auto_save()
	return true


func _rebind_history_target(old_target, restored: Node) -> void:
	for entry in _edit_history:
		if entry.has("target") and entry.target == old_target:
			entry.target = restored
	for item in _redo_history:
		var entry: Dictionary = item.edit
		if entry.has("target") and entry.target == old_target:
			entry.target = restored


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
		if child.has_method("sync_physics_from_node"):
			child.sync_physics_from_node(true)
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
	_flush_monster_drag_move()
	if _monster_drag_view_locked:
		return
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
	# 目录框属于保存表单，不能作为同级弹窗抢走焦点并自动关闭 PopupPanel。
	if is_instance_valid(_map_save_window) and _map_save_window.visible \
	and _save_directory_dialog.get_parent() != _map_save_window:
		_save_directory_dialog.reparent(_map_save_window)
	_save_directory_dialog.current_dir = map_path.get_base_dir()
	_save_directory_dialog.popup_centered(Vector2i(get_viewport().get_visible_rect().size * 0.72))


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
	_save_name_input.text_submitted.connect(func(_text: String): _confirm_named_map_save())
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
	browse.name = "BrowseButton"
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
	actions.name = "Actions"
	cancel.name = "CancelButton"
	save.name = "SaveButton"
	save.text = "保存"
	save.pressed.connect(_confirm_named_map_save)
	actions.add_child(save)
	_save_status = Label.new()
	_save_status.name = "SaveStatus"
	_save_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_save_status.custom_minimum_size.x = 480
	_save_status.hide()
	column.add_child(_save_status)


func _open_map_save_window() -> void:
	if _map_save_window == null:
		_build_map_save_window()
	if _map_save_window == null:
		return
	_save_name_input.text = map_path.get_file().get_basename()
	_save_directory_input.text = map_path.get_base_dir()
	_save_status.hide()
	_refresh_map_save_preview()
	_map_save_window.popup_centered()
	_save_name_input.grab_focus()


func _refresh_map_save_preview() -> void:
	if _save_preview == null or DisplayServer.get_name() == "headless":
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
		_save_status.text = "请输入地图名称并选择保存目录。"
		_save_status.show()
		_save_name_input.grab_focus()
		return
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(directory)):
		_save_status.text = "保存目录不存在，请重新选择路径。"
		_save_status.show()
		return
	var previous_map := map_path
	var previous_bake := baked_map_path
	map_path = directory.path_join(name + ".tscn")
	baked_map_path = directory.path_join(name + ".png")
	var error := export_map_to(map_path)
	if error == OK and _map_save_window != null:
		_map_save_window.hide()
	elif error != OK:
		map_path = previous_map
		baked_map_path = previous_bake
		_save_status.text = "保存失败：%s；当前地图路径未改变。" % error_string(error)
		_save_status.show()


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
	get_tree().create_timer(maxf(full_auto_save_delay, auto_save_delay)).timeout.connect(
		_run_full_edit_auto_save.bind(revision)
	)


func _run_edit_auto_save(revision: int) -> void:
	if revision != _auto_save_revision or not active or not auto_save_edits:
		return
	var surface: Node = _map_canvas.get_node_or_null("CanvasSurface") if _map_canvas != null else null
	if surface != null and surface.has_method("request_snapshot"):
		# 内容仍是 PNG 压缩数据，但 .snapshot 不会和编辑器的 PNG 导入线程争抢文件；
		# 整图编码走后台线程，主线程不为它停帧。
		var snapshot_path := map_path.get_basename() + ".edit.snapshot"
		surface.request_snapshot(snapshot_path)
		edit_snapshot_path = snapshot_path
		surface.saved_ink_path = snapshot_path


func _run_full_edit_auto_save(revision: int) -> void:
	if revision != _auto_save_revision or not active or not auto_save_edits:
		return
	if is_instance_valid(_layout_drag_target) and _layout_drag_target is GearBearing:
		return # 松手后的事务会重新安排保存，不能打包临时解除轴承的状态。
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
		if _mode_transition_pending:
			_mode_transition_pending = false
			_transition.finish()
		return
	if not is_instance_valid(tree_root):
		if _mode_transition_pending:
			_transition.finish()
		return
	var level: Node = tree_root.load_level(packed)
	var replacement := level.get_node_or_null(^"Creative")
	if replacement != null:
		replacement.call_deferred("_activate_restored_editor", _mode_transition_pending)
	elif _mode_transition_pending:
		_transition.finish()


func _activate_restored_editor(finish_transition := false) -> void:
	_skip_restore_on_enter = true
	set_active(true)
	if finish_transition:
		_transition.finish()


## 保存入口始终写出可直接运行的 `.tscn`。prepare_canvas=false 仅供自动测试或只打包当前状态使用。
func export_map_to(save_path: String, prepare_canvas := true) -> Error:
	if is_instance_valid(_layout_drag_target) and _layout_drag_target is GearBearing:
		_finish_layout_drag()
	var scene := _level_root()
	if scene == null:
		push_error("Creative: 找不到关卡根")
		return ERR_DOES_NOT_EXIST
	save_path = _normalize_scene_path(save_path)
	if save_path.is_empty():
		push_error("Creative: 场景保存路径为空")
		return ERR_INVALID_PARAMETER
	if prepare_canvas and _map_canvas != null:
		_map_canvas.generate(false)       # 保存不是用户编辑操作，不追加撤销步骤。
		if save_preview_on_export:
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
	var play_canvas_states: Dictionary = {}
	for play_canvas in _play_canvases():
		play_canvas_states[play_canvas] = [play_canvas.visible, play_canvas.active]
	var map_visible: bool = _map_canvas.visible if _map_canvas != null else false
	var map_active: bool = _map_canvas.active if _map_canvas != null else false
	if _map_canvas != null:
		_map_canvas.set_map_editor_mode(false)
	if _player != null:
		_player.visible = _saved_player_visible
	for play_canvas in _play_canvases():
		_show_canvas(play_canvas, true)
	_show_canvas(_map_canvas, false)
	var error: Error = packed.pack(scene)
	for play_canvas in play_canvas_states:
		if is_instance_valid(play_canvas):
			play_canvas.visible = bool(play_canvas_states[play_canvas][0])
			play_canvas.active = bool(play_canvas_states[play_canvas][1])
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
