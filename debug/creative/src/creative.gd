#创造模式（= 地图编辑模式）：F2 进/出。
#进去后本体没有碰撞、没有重力，WASD 直接改位置（上帝手感，不走惯性）；
#数字键 1/2/3/4 切画布工具；F5 先把画布固化，再把世界里的墨水物品导出成地图场景。

#region 依赖
extends Node
const UiHitTest := preload("res://ui/input/src/ui_hit_test.gd")

signal map_saved(path: String)
signal mode_changed(editing: bool)

const HEALTH_UI_GROUP := &"health_ui"
const MONSTER_CONTAINER_NAME := &"Monsters"
const PLAYER_SPAWN_NAME := &"PlayerSpawn"
const PLAYER_SPAWN_GROUP := &"player_spawn"
const RESPAWN_POINT_PREFIX := LayoutTools.RESPAWN_PREFIX
const RESPAWN_POINT_GROUP := LayoutTools.RESPAWN_GROUP
const PLAY_CANVAS_GROUP := &"play_canvas"
## 模式常量只在 `application/editor_modes.gd` 定义一处；这里保留同名常量是为了
## 不破坏既有引用（测试和外部都直接写 `creative.LAYOUT_MODE_*`）。
const Modes := preload("res://debug/creative/application/editor_modes.gd")
const MONSTER_MODE_NONE := Modes.MONSTER_MODE_NONE
const MONSTER_MODE_DELETE := Modes.MONSTER_MODE_DELETE
const MONSTER_MODE_ADJUST := Modes.MONSTER_MODE_ADJUST
const DIALOGUE_MODE_PLACE := Modes.DIALOGUE_MODE_PLACE
const DIALOGUE_MODE_DELETE := Modes.DIALOGUE_MODE_DELETE
const TEXT_MODE_PLACE := Modes.TEXT_MODE_PLACE
const TEXT_MODE_DELETE := Modes.TEXT_MODE_DELETE
const LAYOUT_MODE_MOVE_SPAWN := Modes.LAYOUT_MODE_MOVE_SPAWN
const LAYOUT_MODE_PLACE_RESPAWN := Modes.LAYOUT_MODE_PLACE_RESPAWN
const LAYOUT_MODE_MOVE_RESPAWN := Modes.LAYOUT_MODE_MOVE_RESPAWN
const LAYOUT_MODE_PLACE_CANVAS := Modes.LAYOUT_MODE_PLACE_CANVAS
const LAYOUT_MODE_MOVE_CANVAS := Modes.LAYOUT_MODE_MOVE_CANVAS
const CONTROL_MODE := Modes.CONTROL_MODE
const LAYOUT_MODE_PLACE_PORTAL := Modes.LAYOUT_MODE_PLACE_PORTAL
const LAYOUT_MODE_DELETE_PORTAL := Modes.LAYOUT_MODE_DELETE_PORTAL
const LAYOUT_MODE_FOUNTAIN := Modes.LAYOUT_MODE_FOUNTAIN
const LAYOUT_MODE_DELETE_CANVAS := Modes.LAYOUT_MODE_DELETE_CANVAS
const LAYOUT_MODE_DELETE_RESPAWN := Modes.LAYOUT_MODE_DELETE_RESPAWN
const LAYOUT_MODES := Modes.LAYOUT_MODES
const EditorSession := preload("res://debug/creative/application/editor_session.gd")
## 保存/导出的纯逻辑；`creative` 只保留状态与调用顺序。
const EditorSave := preload("res://debug/creative/application/editor_save.gd")
## 布局物件的文档操作（找/建/删），不碰撤销与界面。
const LayoutTools := preload("res://debug/creative/features/layout_tools.gd")
## 小怪的文档操作（查找/计数/编辑器物理暂停）。
const MonsterTools := preload("res://debug/creative/features/monster_tools.gd")
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
const InkFountainScript := preload("res://actor/fountain/src/ink_fountain.gd")
const MapPlacementOverlayScript := preload("res://debug/creative/src/map_placement_overlay.gd")
const MapImportedImageScript := preload("res://debug/creative/src/map_imported_image.gd")
const PlayCanvasScene := preload("res://actor/canvas/canvas.tscn")
const InkPalette := preload("res://ink/general/src/ink_palette.gd")
const CanvasSurfaceScript := preload("res://actor/canvas/src/canvas_surface.gd")
const GearCenters := preload("res://actor/canvas/src/gear_centers.gd")
const YellowHinge := preload("res://ink/yellow/src/hinge.gd")
const YellowStroke := preload("res://ink/yellow/src/stroke.gd")
const YellowRail := preload("res://ink/yellow/src/rail.gd")
const YellowSliderPin := preload("res://ink/yellow/src/slider_pin.gd")
const BlueMotor := preload("res://ink/blue/src/motor.gd")
const BlueWire := preload("res://ink/blue/src/wire_layer.gd")
const InkSelectionIndicator := preload("res://ui/theme/ink_selection_indicator.gd")
var _editor_ink_buttons: Array[Button]:
	get:
		return _palette._editor_ink_buttons if is_instance_valid(_palette) else []
var _editor_ink_label: Label:
	get:
		return _palette._editor_ink_label if is_instance_valid(_palette) else null
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
## 旧地图外置草稿快照的兼容入口；新保存使用 editor_draft。
@export_file("*.snapshot", "*.png", "*.res", "*.tres") var edit_snapshot_path := ""
## 标准编辑蓝图；试玩实体不能反写它。空字典仅表示尚未迁移的旧地图。
@export_storage var editor_draft: Dictionary = {}
var _document_restored := false
## 退出编辑器时：把非机关实体墨化回画布，再保存“墨水为主”的快照。
@export var auto_save_on_exit := false
## 每次完成绘图、小怪编辑或撤销后，覆盖保存当前地图。
@export var auto_save_edits := false
@export_range(0.05, 2.0, 0.05) var auto_save_delay := 0.3
## 用户停止操作后再提交完整编辑蓝图，避免连续编辑反复打包整关。
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
var _save_view: Node
var _palette: CanvasLayer
var active := false
var _player = null
var _body = null
var _spawn_point: Marker2D = null
var _layout_overlay = null
var _layout_buttons: Dictionary:
	get:
		return _palette._layout_buttons if is_instance_valid(_palette) else {}
var _layout_status_label: Label:
	get:
		return _palette._layout_status_label if is_instance_valid(_palette) else null
## 「关卡墨水配额」表格：材质 id -> SpinBox。配额写进关卡根节点的 starting_ink，只对当前地图生效。
var _ink_quota_fields: Dictionary:
	get:
		return _palette._ink_quota_fields if is_instance_valid(_palette) else {}
var _portal_destination: PopupMenu:
	get:
		return _palette._portal_destination if is_instance_valid(_palette) else null
var _portal_target_path := ""
var _portal_menu_target: Node2D = null
var _canvas_size_dialog: ConfirmationDialog = null
var _canvas_width_input: SpinBox = null
var _canvas_height_input: SpinBox = null
var _new_canvas_size := Vector2i(400, 280)
var _canvas = null
var _map_canvas = null
var _saved_layer := 1
var _saved_mask := 0xFFFFFFFF
var _saved_gravity := 1.0
var _saved_player_visible := true
var _player_visibility_saved := false
var _saved_player_modulate := Color.WHITE
## 只有完整执行完进入编辑器流程后才允许“卸载前保存”，
## 避免 F2 异步重载刚开始时把尚未初始化好的旧关卡写成地图。
var _editor_ready := false
var _editor_player_states: Array[Dictionary] = []
var _editor_input_mode := Node.PROCESS_MODE_INHERIT
var _editor_arm_mode := Node.PROCESS_MODE_INHERIT
var _saved_health_ui_visibility := {}
## 交互态（当前模式 / 拖动 / 选中）都在 session 里。
var _session := EditorSession.new()
## 兼容层：`game_cursor` 和现有测试仍按旧字段名读写这几个交互态。
## 内部代码一律走 `_session.*`；P4 把外部调用改完后整块删除。
@warning_ignore("unused_private_class_variable")
var _monster_mode: int:
	get: return _session.mode
	set(value): _session.mode = value
@warning_ignore("unused_private_class_variable")
var _selected_monster: Node2D:
	get: return _session.selected_monster
	set(value): _session.selected_monster = value
@warning_ignore("unused_private_class_variable")
var _dragging_monster: bool:
	get: return _session.dragging_monster
	set(value): _session.dragging_monster = value
@warning_ignore("unused_private_class_variable")
var _monster_drag_view_locked: bool:
	get: return _session.monster_drag_view_locked
	set(value): _session.monster_drag_view_locked = value
@warning_ignore("unused_private_class_variable")
var _drag_player_states: Array[Dictionary]:
	get: return _session.drag_player_states
	set(value): _session.drag_player_states = value
var _layout_drag_target:
	get: return _session.layout_drag_target
	set(value): _session.layout_drag_target = value
@warning_ignore("unused_private_class_variable")
var _layout_drag_resizing: bool:
	get: return _session.layout_drag_resizing
	set(value): _session.layout_drag_resizing = value
@warning_ignore("unused_private_class_variable")
var _selected_control_target:
	get: return _session.selected_control_target
	set(value): _session.selected_control_target = value
@warning_ignore("unused_private_class_variable")
var _selected_portal: Node2D:
	get: return _session.selected_portal
	set(value): _session.selected_portal = value
var _monster_container: Node2D = null
var _monster_palette: CanvasLayer = null
@warning_ignore("unused_private_class_variable")
var _monster_palette_panel: PanelContainer:
	get:
		return _palette._monster_palette_panel if is_instance_valid(_palette) else null
@warning_ignore("unused_private_class_variable")
var _monster_palette_toggle: Button:
	get:
		return _palette._monster_palette_toggle if is_instance_valid(_palette) else null
var _monster_buttons: Array[Button]:
	get:
		return _palette._monster_buttons if is_instance_valid(_palette) else []
var _delete_monster_button: Button:
	get:
		return _palette._delete_monster_button if is_instance_valid(_palette) else null
var _adjust_monster_button: Button:
	get:
		return _palette._adjust_monster_button if is_instance_valid(_palette) else null
var _reset_monster_scale_button: Button:
	get:
		return _palette._reset_monster_scale_button if is_instance_valid(_palette) else null
var _monster_status_label: Label:
	get:
		return _palette._monster_status_label if is_instance_valid(_palette) else null
@warning_ignore("unused_private_class_variable")
var _editor_nail_visibility: Button:
	get:
		return _palette._editor_nail_visibility if is_instance_valid(_palette) else null
var _skip_restore_on_enter := false
var _auto_save_revision := 0
var _syncing_canvas_tool := false
var _history = preload("res://debug/creative/application/editor_history.gd").new()
var _commands = preload("res://debug/creative/application/editor_commands.gd").new()
var _next_monster_id := 1
var _dialogue_container: Node2D = null
var _place_dialogue_button: Button:
	get:
		return _palette._place_dialogue_button if is_instance_valid(_palette) else null
var _delete_dialogue_button: Button:
	get:
		return _palette._delete_dialogue_button if is_instance_valid(_palette) else null
var _dialogue_window: Window = null
var _dialogue_lines_box: VBoxContainer = null
var _dialogue_input_status: Label = null
var _pending_dialogue_position := Vector2.ZERO
var _next_dialogue_id := 1
var _text_container: Node2D = null
var _place_text_button: Button:
	get:
		return _palette._place_text_button if is_instance_valid(_palette) else null
var _delete_text_button: Button:
	get:
		return _palette._delete_text_button if is_instance_valid(_palette) else null
var _text_window: Window = null
var _text_input: TextEdit = null
var _text_input_status: Label = null
var _pending_text_position := Vector2.ZERO
var _next_text_id := 1
var _editor_ui_ready := false
var _editor_runtime: Node = null
var _editor_runtime_was_processing := true
var _edit_snapshot_loaded := false
var _map_text_font: Font = null
var _outside_cleanup_elapsed := 0.0
var _map_reload_in_progress := false
#endregion


#region 生命周期
func _ready() -> void:
	add_to_group(&"creative_editor")
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
	_configure_history()
	# 游戏启动时不读取十几 MB 的编辑快照，也不创建地图编辑专用窗口和字体。
	# 这些资源只在首次进入地图编辑器时按需初始化。
	_show_canvas(_map_canvas, false)
	_prepare_document_after_ready.call_deferred()


func _prepare_document_after_ready() -> void:
	var level := _level_root()
	if level.get("body_bake_pending"):
		await level.body_bake_completed
	prepare_loaded_document(bool(level.get_meta(&"editor_document_load", false)))


## 游戏实例只固化自己的草稿；编辑实例保持草稿与实体的分离。
func prepare_loaded_document(editing: bool) -> void:
	if _document_restored or _map_canvas == null:
		return
	var previous_free: bool = _map_canvas.surface.ink_free
	_map_canvas.surface.ink_free = true
	_map_canvas.surface.defer_load_metadata = not editing
	var error: Error = OK
	if editor_draft.is_empty():
		# 旧地图的内容在外置快照里；普通游玩也要读取，不能等第一次 F2。
		_load_edit_snapshot_if_needed()
		if not _edit_snapshot_loaded:
			_map_canvas.surface.ink_free = previous_free
			_map_canvas.surface.defer_load_metadata = false
			return
		editor_draft = _map_canvas.surface.capture_document()
	else:
		error = _map_canvas.surface.restore_document(editor_draft)
	_document_restored = error == OK
	if error == OK and not editing:
		_map_canvas.generate(false)
	_map_canvas.surface.ink_free = previous_free
	_map_canvas.surface.defer_load_metadata = false
	if error != OK:
		push_error("Creative: 无法恢复内嵌草稿 (%d)" % error)


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
	# 新文档自带草稿，不再接受外置快照覆盖。
	if not editor_draft.is_empty():
		edit_snapshot_path = ""
		return
	# 旧地图保留快照恢复兼容。
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
	elif active and event is InputEventMouseButton and event.pressed \
	and event.button_index == MOUSE_BUTTON_RIGHT \
	and (MONSTER_KINDS.has(_session.mode) or _session.mode == MONSTER_MODE_DELETE):
		return remove_monster_at(_event_world_position(event))
	elif active and (LAYOUT_MODES.has(_session.mode) or _session.mode == CONTROL_MODE) \
	and event is InputEventMouseButton:
		return _handle_layout_mouse_button(event as InputEventMouseButton)
	elif active and (LAYOUT_MODES.has(_session.mode) or _session.mode == CONTROL_MODE) \
	and event is InputEventMouseMotion:
		return _handle_layout_mouse_motion(event as InputEventMouseMotion)
	elif active and (_session.mode == MONSTER_MODE_ADJUST or _session.mode == MONSTER_MODE_NONE) \
	and event is InputEventMouseButton:
		return _handle_monster_adjust_button(event as InputEventMouseButton)
	elif active and (_session.mode == MONSTER_MODE_ADJUST or _session.mode == MONSTER_MODE_NONE) \
	and event is InputEventMouseMotion:
		return _handle_monster_adjust_motion(event as InputEventMouseMotion)
	elif active and _session.mode != MONSTER_MODE_NONE \
	and event is InputEventMouseButton \
	and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var world_position: Vector2 = \
			get_viewport().get_canvas_transform().affine_inverse() * event.position
		if _session.mode == MONSTER_MODE_DELETE:
			remove_monster_at(world_position)
		elif _session.mode == DIALOGUE_MODE_PLACE:
			_open_dialogue_input(world_position)
		elif _session.mode == DIALOGUE_MODE_DELETE:
			remove_dialogue_trigger_at(world_position)
		elif _session.mode == TEXT_MODE_PLACE:
			_open_text_input(world_position)
		elif _session.mode == TEXT_MODE_DELETE:
			remove_map_text_at(world_position)
		else:
			var placed := place_monster(_session.mode, world_position)
			if placed != null:
				# 放置后自动退出放置模式，选中并直接进入拖动，方便立即调整位置。
				_session.mode = MONSTER_MODE_NONE
				_set_selected_monster(placed)
				_lock_monster_drag_view()
				_session.dragging_monster = true
				_session.drag_offset = placed.global_position - world_position
				_session.drag_start_position = placed.global_position
				_session.drag_start_scale = placed.scale
				_update_monster_buttons()
		return true
	return false


func _event_world_position(event: InputEventMouse) -> Vector2:
	if _session.monster_drag_view_locked:
		return _session.monster_drag_inverse * event.position
	return get_viewport().get_canvas_transform().affine_inverse() * event.position


## 全局输入早于 GUI 更新；用本次事件的位置判断，避免沿用上一帧的悬停控件。
func _pointer_over_editor_ui(screen_position: Vector2) -> bool:
	return UiHitTest.blocks_world_input(get_viewport(), screen_position)

func _handle_monster_adjust_button(event: InputEventMouseButton) -> bool:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not event.pressed:
			return false
		var target := _find_monster_at(_event_world_position(event))
		if target != null:
			_session.selected_monster = target
		if not is_instance_valid(_session.selected_monster):
			return false
		_resize_selected_monster(MONSTER_SCALE_STEP if event.button_index == MOUSE_BUTTON_WHEEL_UP else -MONSTER_SCALE_STEP)
		_update_monster_status()
		return true
	if event.button_index == MOUSE_BUTTON_RIGHT:
		return event.pressed and remove_monster_at(_event_world_position(event))
	if event.button_index != MOUSE_BUTTON_LEFT:
		return false
	if event.pressed:
		var monster := _find_monster_at(_event_world_position(event))
		_set_selected_monster(monster)
		if monster == null:
			# 默认模式下点击空白不拦截，让地图画布正常绘画。
			return _session.mode == MONSTER_MODE_ADJUST
		_lock_monster_drag_view()
		_session.dragging_monster = true
		_session.drag_offset = monster.global_position - _event_world_position(event)
		_session.drag_start_position = monster.global_position
		_session.drag_start_scale = monster.scale
		return true
	if not _session.dragging_monster:
		return false
	_flush_monster_drag_move()
	_session.dragging_monster = false
	_unlock_monster_drag_view()
	_record_monster_transform(_session.selected_monster, _session.drag_start_position, _session.drag_start_scale)
	return true


func _handle_monster_adjust_motion(event: InputEventMouseMotion) -> bool:
	if not _session.dragging_monster or not is_instance_valid(_session.selected_monster):
		return false
	_session.selected_monster.global_position = _event_world_position(event) + _session.drag_offset
	_session.pending_monster_move = _session.selected_monster
	return true


func _flush_monster_drag_move() -> void:
	var target := _session.pending_monster_move
	_session.pending_monster_move = null
	if is_instance_valid(target):
		target.sync_editor_translation()
		if target == _session.layout_drag_target:
			_refresh_layout_overlay(target)


func _on_drag_focus_lost() -> void:
	if not _session.monster_drag_view_locked:
		return
	if is_instance_valid(_session.layout_drag_target):
		_finish_layout_drag()
	else:
		_flush_monster_drag_move()
		_session.dragging_monster = false
		_unlock_monster_drag_view()
		_record_monster_transform(_session.selected_monster, _session.drag_start_position, _session.drag_start_scale)


func _lock_monster_drag_view() -> void:
	if _session.monster_drag_view_locked:
		return
	var camera := _level_root().get_node_or_null("Camera2D")
	if camera != null and camera.has_method("set_editor_drag_locked"):
		camera.set_editor_drag_locked(true)
	_session.monster_drag_inverse = get_viewport().get_canvas_transform().affine_inverse()
	_session.monster_drag_view_locked = true
	if _player == null or _body == null:
		return
	# 冻结玩家自身，鼠标手臂控制和飞行输入不能把隐藏的玩家拉走。
	_session.drag_hand_control = _player.get_node_or_null("Arm/Hand/HandControl")
	if _session.drag_hand_control != null:
		_session.drag_hand_mode = _session.drag_hand_control.process_mode
		_session.drag_hand_control.process_mode = Node.PROCESS_MODE_DISABLED
	var bodies: Array = [_body, _player.get_node("Arm").body, _player.get_node("Arm/Hand").body]
	for physics_body in bodies:
		_session.drag_player_states.append({"body": physics_body, "frozen": physics_body.frozen,
			"had_tag": physics_body.tags.has("editor_physics_paused"),
			"tag": physics_body.tags.get("editor_physics_paused", false)})
		physics_body.tags["editor_physics_paused"] = true
		physics_body.linear_velocity = Vector2.ZERO
		physics_body.angular_velocity = 0.0
		_level_root().world.freeze(physics_body)


func _unlock_monster_drag_view() -> void:
	if not _session.monster_drag_view_locked:
		return
	_session.monster_drag_view_locked = false
	var level := _level_root()
	for state in _session.drag_player_states:
		if state.had_tag:
			state.body.tags["editor_physics_paused"] = state.tag
		else:
			state.body.tags.erase("editor_physics_paused")
		if level != null and not state.frozen:
			level.world.unfreeze(state.body)
	_session.drag_player_states.clear()
	if is_instance_valid(_session.drag_hand_control):
		_session.drag_hand_control.process_mode = _session.drag_hand_mode
	_session.drag_hand_control = null
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
	_editor_ready = false
	# 先隐藏玩家，再尝试恢复/重载编辑文档。
	# 第二页等大关卡进入编辑器时会走异步重载；旧实现要等重载分支返回后才隐藏玩家，
	# 重载稍慢或失败时就会把上一个游玩实例的墨水瓶留在画面里。
	if _player == null:
		for candidate in get_tree().get_nodes_in_group(&"player"):
			if candidate.get_parent() == _level_root():
				_player = candidate
				break
	if _player != null and not _player_visibility_saved:
		_saved_player_visible = _player.visible
		_saved_player_modulate = _player.modulate
		_player_visibility_saved = true
	_hide_editor_player()
	# 即使下面因为文档重载/Player 尚未烘焙而提前返回，也让编辑器帧兜底保持隐藏。
	set_physics_process(true)
	# 游玩中的破坏/碎片不能反写编辑文档。优先恢复内存试玩快照；
	# 首次打开编辑器时才从磁盘载入文档。
	if not _skip_restore_on_enter and _restore_editor_document():
		return
	_skip_restore_on_enter = false
	_ensure_editor_resources()
	_load_edit_snapshot_if_needed()
	_clear_edit_history()
	if _map_canvas != null:
		var edit_surface = _map_canvas.get_node_or_null("CanvasSurface")
		if edit_surface != null:
			edit_surface.clear_history()
	# 只有没有标准蓝图的旧地图允许转换一次；之后只加载蓝图。
	_set_ink_free(true)
	if _map_canvas != null and editor_draft.is_empty():
		_map_canvas.return_to_canvas(false, true)
		editor_draft = _map_canvas.surface.capture_document()
	_set_monster_physics_paused(true)
	_pause_editor_simulation()
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
	_player.visible = false
	_suspend_player_entity()
	_clear_character_effects()
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
	_editor_ready = true
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
	if not editor_draft.is_empty() or _edit_snapshot_loaded or edit_snapshot_path.is_empty() or _map_canvas == null:
		return
	var surface: Node = _map_canvas.get_node_or_null("CanvasSurface")
	if surface == null or not surface.has_method("load_ink"):
		return
	if surface.load_ink(edit_snapshot_path) == OK:
		surface.saved_ink_path = edit_snapshot_path
		_edit_snapshot_loaded = true


func _exit() -> void:
	_editor_ready = false
	set_physics_process(false)
	_flush_monster_drag_move()
	_unlock_monster_drag_view()
	if _session.layout_drag_target != null:
		_finish_layout_drag()
	_cancel_dialogue_input()
	_cancel_text_input()
	if _canvas_size_dialog != null:
		_canvas_size_dialog.hide()
	_restore_player_entity()
	if _body != null:
		_body.collision_layer = _saved_layer
		_body.collision_mask = _saved_mask
		_body.gravity_scale = _saved_gravity
		_body.linear_velocity = Vector2.ZERO
		_body.angular_velocity = 0.0
		_body.awake = true
		_body.sleep_timer = 0.0
	_reset_player_to_spawn()
	# F2 是内存中的试玩事务：先留存编辑蓝图，再仅对试玩实例固化草稿。
	# 即使旧地图保存了 auto_save_on_exit=true，也不能让模式切换覆盖文件。
	if auto_save_on_exit:
		var save_error := save_editor_snapshot_before_leave(true)
		if save_error != OK:
			push_error("Creative: snapshot save failed (%d)" % save_error)
	var router := get_tree().current_scene
	if router != null and router.has_method("restore_editor_level"):
		var checkpoint := PackedScene.new()
		EditorSave.sync_node_transforms(_level_root())
		if _pack_as_playable_scene(checkpoint, _level_root()) == OK:
			router.set_meta(&"editor_preview_document", {"path": map_path, "scene": checkpoint})
	if _map_canvas != null:
		_map_canvas.set_map_editor_mode(false)
		_map_canvas.generate(false)
	_resume_editor_simulation()
	_set_monster_physics_paused(false)
	_show_canvas(_map_canvas, false)
	for play_canvas in _play_canvases():
		_show_canvas(play_canvas, true)
		play_canvas.activate_hand_tool()
	# 无普通画布的地图也能游玩；隐藏的 MapCanvas 不会替玩家重新启用手。
	if _map_canvas != null:
		_map_canvas.activate_hand_tool()
	if _player != null:
		var hand: Node = _player.get_node_or_null("Arm/Hand/HandControl")
		if hand != null:
			hand.set_enabled(true)
	_session.mode = MONSTER_MODE_NONE
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
		_player.modulate = _saved_player_modulate
		_player_visibility_saved = false
		var health = _player.get_node_or_null("InkHealth")
		if health != null:
			health.damage_enabled = true
	_restore_health_ui()
	print("CREATIVE off")


## 编辑器内暂停 SimulationRuntime 的物理推进；不修改容器上的 auto_step，
## 避免保存时把“编辑暂停”写进地图。退出时恢复原处理状态。
func _pause_editor_simulation() -> void:
	var level := _level_root()
	if level == null:
		return
	var runtime := level.get_node_or_null("SimulationRuntime")
	if _editor_runtime != runtime:
		_editor_runtime = runtime
		if runtime != null:
			_editor_runtime_was_processing = runtime.is_physics_processing()
	if _editor_runtime != null:
		_editor_runtime.set_physics_process(false)
	if level.world == null:
		return
	for body in level.world.bodies:
		if body == null or body.is_static or body.tags.has("living"):
			continue
		body.linear_velocity = Vector2.ZERO
		body.angular_velocity = 0.0


func _resume_editor_simulation() -> void:
	if is_instance_valid(_editor_runtime):
		_editor_runtime.set_physics_process(_editor_runtime_was_processing)
	_editor_runtime = null


## 退出编辑器/离开关卡前调用：非机关实体墨化回画布，保存“墨水为主”的快照。
## 再次进入编辑器直接恢复这份快照，不做二次墨化。
func save_editor_snapshot_before_leave(force := false) -> Error:
	if not force and (not active or not _editor_ready):
		return OK
	if not auto_save_on_exit:
		return OK
	if map_path.is_empty():
		push_warning("Creative: 地图没有保存路径，无法写回快照")
		return ERR_INVALID_PARAMETER
	_inkify_non_mechanism_bodies()
	return export_map_to(map_path)


## 保留齿轮/轴承/弹簧/导轨/滑块/蓝墨机构所在刚体；其余实体全部回画布。
func _editor_preserved_bodies() -> Dictionary:
	var keep: Dictionary = {}
	var level := _level_root()
	if level == null or level.world == null:
		return keep
	for body in level.world.bodies:
		if body == null or body.tags.has("living"):
			continue
		if not GearCenters.body_records(body).is_empty():
			keep[body] = true
	for child in level.get_children():
		if child is YellowHinge:
			_keep_anchor(keep, child.yellow_anchor)
			_keep_anchor(keep, child.black_anchor)
		elif child is YellowStroke:
			for anchor: Dictionary in child.anchors:
				_keep_anchor(keep, anchor)
		elif child is YellowRail:
			if child.body != null:
				keep[child.body] = true
		elif child is YellowSliderPin:
			_keep_anchor(keep, child.black_anchor)
		elif child is BlueMotor or child is BlueWire:
			if child.body != null:
				keep[child.body] = true
	return keep


func _keep_anchor(keep: Dictionary, anchor: Dictionary) -> void:
	if anchor.is_empty():
		return
	var body = anchor.get("body")
	if is_instance_valid(body):
		keep[body] = true


func inkify_editor_preserved() -> void:
	if _map_canvas == null:
		return
	_map_canvas.return_to_canvas(true, true, _editor_preserved_bodies())


## 编辑时只保留无几何的相机锚点，身体、手臂和手均不再参与任何实体查询。


func _inkify_non_mechanism_bodies() -> void:
	if _map_canvas == null:
		return
	_map_canvas.return_to_canvas(false, true, _editor_preserved_bodies())


## 编辑时只保留无几何的相机锚点，身体、手臂和手均不再参与任何实体查询。
func _hide_editor_player() -> void:
	if _player != null:
		_player.visible = false
		var hidden := _saved_player_modulate
		hidden.a = 0.0
		_player.modulate = hidden


## 死亡/复活残影是玩家贴图的 Sprite2D 克隆，不属于 Player 节点；
## 进入编辑器时必须清掉，否则会看起来像“玩家没隐藏”。
func _clear_character_effects() -> void:
	for effect in get_tree().get_nodes_in_group(&"character_death_effect"):
		if is_instance_valid(effect):
			effect.queue_free()


func _suspend_player_entity() -> void:
	if not _editor_player_states.is_empty():
		return
	var hand: Node = _player.get_node("Arm/Hand/HandControl")
	hand._release_grab()
	hand._remove_arm()
	_editor_input_mode = _player.get_node("PlayerInput").process_mode
	_editor_arm_mode = _player.get_node("Arm").process_mode
	_player.get_node("PlayerInput").process_mode = Node.PROCESS_MODE_DISABLED
	_player.get_node("Arm").process_mode = Node.PROCESS_MODE_DISABLED
	for part in [_player, _player.get_node("Arm"), _player.get_node("Arm/Hand")]:
		var body = part.body
		_editor_player_states.append({"body": body, "shapes": body.shapes, "rects": body.rects,
			"layer": body.collision_layer, "mask": body.collision_mask, "gravity": body.gravity_scale,
			"frozen": body.frozen, "had_paused": body.tags.has("editor_physics_paused"),
			"paused": body.tags.get("editor_physics_paused", false)})
		body.tags["editor_physics_paused"] = true
		body.collision_layer = 0
		body.collision_mask = 0
		body.gravity_scale = 0.0
		body.shapes = []
		body.rects = []
		body.rects_rev += 1 # 同步清除原生碰撞体及凸包缓存。
		body.linear_velocity = Vector2.ZERO
		body.angular_velocity = 0.0
		body.control_force = Vector2.ZERO
		body.control_torque = 0.0
		_level_root().world.freeze(body)
		body.update_aabb()


func _restore_player_entity() -> void:
	if _editor_player_states.is_empty():
		return
	for state in _editor_player_states:
		var body = state.body
		body.shapes = state.shapes
		body.rects = state.rects
		body.rects_rev += 1 # 恢复时强制重建原生碰撞体。
		body.collision_layer = state.layer
		body.collision_mask = state.mask
		body.gravity_scale = state.gravity
		if state.had_paused:
			body.tags["editor_physics_paused"] = state.paused
		else:
			body.tags.erase("editor_physics_paused")
		if not state.frozen:
			_level_root().world.unfreeze(body)
		body.update_aabb()
	_editor_player_states.clear()
	_player.get_node("PlayerInput").process_mode = _editor_input_mode
	_player.get_node("Arm").process_mode = _editor_arm_mode


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
	if _session.mode == CONTROL_MODE:
		_layout_status_label.text += "\n操纵：%s" % _control_target_name(_session.selected_control_target)


func _collect_nodes_recursive(root: Node) -> Array:
	return LayoutTools.collect(root)


func _unique_level_node_name(prefix: String) -> String:
	return LayoutTools.unique_name(_level_root(), prefix)


func _respawn_points() -> Array:
	return LayoutTools.respawn_points(_level_root(), _spawn_point)


func _handle_layout_mouse_button(event: InputEventMouseButton) -> bool:
	if _session.mode == LAYOUT_MODE_MOVE_CANVAS and event.button_index == MOUSE_BUTTON_RIGHT:
		if not event.pressed:
			return false
		return delete_play_canvas(_pick_play_canvas(_event_world_position(event)))
	if _session.mode == LAYOUT_MODE_FOUNTAIN and event.button_index == MOUSE_BUTTON_RIGHT:
		if not event.pressed:
			return false
		return delete_ink_fountain(_pick_ink_fountain(_event_world_position(event)))
	# 放置类工具统一右键删除：光标下是什么就删什么，不用先切到删除工具。
	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var delete_at := _event_world_position(event)
		match _session.mode:
			LAYOUT_MODE_PLACE_RESPAWN, LAYOUT_MODE_MOVE_RESPAWN:
				return delete_respawn_point(_pick_respawn_point(delete_at))
			LAYOUT_MODE_PLACE_CANVAS:
				return delete_play_canvas(_pick_play_canvas(delete_at))
			LAYOUT_MODE_PLACE_PORTAL:
				return delete_portal(_pick_portal(delete_at))
	if _session.mode == CONTROL_MODE and event.button_index == MOUSE_BUTTON_RIGHT:
		if not event.pressed:
			return false
		return _delete_control_target(_event_world_position(event))
	if _session.mode == CONTROL_MODE \
	and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		if not event.pressed:
			return false
		var target = _pick_control_target(_event_world_position(event), true)
		if target == null:
			target = _session.selected_control_target
		if target == null:
			return false
		_session.selected_control_target = target
		var direction := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
		return _resize_control_target(target, direction)
	if event.button_index != MOUSE_BUTTON_LEFT:
		return false
	if event.pressed:
		var world_position := _event_world_position(event)
		# 模式分发表：新增布局工具 = 加一行映射 + 一个处理函数，不再往 match 里塞分支。
		if _layout_click.is_empty():
			_configure_layout_actions()
		var handler: Callable = _layout_click.get(_session.mode)
		if handler.is_valid():
			handler.call(world_position, event)
		return true
	if _session.layout_drag_target != null:
		_handle_layout_mouse_motion(event)
		_finish_layout_drag()
		return true
	return false


## 布局模式 → 左键处理函数。键是 `editor_modes` 里的负数常量。
## 只在第一次用到时构建：类体里直接写方法名会被当成未定义标识符。
var _layout_click: Dictionary = {}


func _configure_layout_actions() -> void:
	_layout_click = {
		CONTROL_MODE: _click_control,
		LAYOUT_MODE_PLACE_RESPAWN: _click_place_respawn,
		LAYOUT_MODE_DELETE_RESPAWN: _click_delete_respawn,
		LAYOUT_MODE_MOVE_RESPAWN: _click_move_respawn,
		LAYOUT_MODE_PLACE_CANVAS: _click_place_canvas,
		LAYOUT_MODE_DELETE_CANVAS: _click_delete_canvas,
		LAYOUT_MODE_MOVE_CANVAS: _click_move_canvas,
		LAYOUT_MODE_PLACE_PORTAL: _click_place_portal,
		LAYOUT_MODE_DELETE_PORTAL: _click_delete_portal,
		LAYOUT_MODE_FOUNTAIN: _click_fountain,
		LAYOUT_MODE_MOVE_SPAWN: _click_move_spawn,
	}


func _click_control(world_position: Vector2, event: InputEventMouseButton) -> void:
	_session.selected_control_target = _pick_control_target(world_position)
	if event.double_click and is_instance_valid(_session.selected_control_target) \
	and _session.selected_control_target.is_in_group(MapPortalScript.GROUP):
		_open_portal_menu(_session.selected_control_target)
		return
	_begin_layout_drag(_session.selected_control_target, world_position)
	_session.layout_drag_resizing = is_instance_valid(_session.selected_control_target) \
		and _session.selected_control_target.is_in_group(MapImportedImageScript.GROUP) \
		and _session.selected_control_target.resize_handle_hit(world_position)


## 放置类工具统一：按在已有对象上是移动它，按在空地上才是新增。
func _click_place_respawn(world_position: Vector2, _event: InputEventMouseButton) -> void:
	var picked := _pick_respawn_point(world_position)
	if picked != null:
		_begin_layout_drag(picked, world_position)
	else:
		place_respawn_point(world_position)


func _click_delete_respawn(world_position: Vector2, _event: InputEventMouseButton) -> void:
	delete_respawn_point(_pick_respawn_point(world_position))


func _click_move_respawn(world_position: Vector2, _event: InputEventMouseButton) -> void:
	_begin_layout_drag(_pick_respawn_point(world_position), world_position)


func _click_place_canvas(world_position: Vector2, _event: InputEventMouseButton) -> void:
	var picked := _pick_play_canvas(world_position)
	if picked != null:
		_begin_layout_drag(picked, world_position)
	else:
		place_play_canvas(world_position)


func _click_delete_canvas(world_position: Vector2, _event: InputEventMouseButton) -> void:
	delete_play_canvas(_pick_play_canvas(world_position))


func _click_move_canvas(world_position: Vector2, _event: InputEventMouseButton) -> void:
	_begin_layout_drag(_pick_play_canvas(world_position), world_position)


func _click_place_portal(world_position: Vector2, _event: InputEventMouseButton) -> void:
	var picked := _pick_portal(world_position)
	if picked != null:
		_begin_layout_drag(picked, world_position)
		return
	var placed := place_portal(world_position, _portal_choice())
	if is_instance_valid(placed):
		select_control_tool()
		_session.selected_control_target = placed
		_select_portal(placed)
		_update_layout_status()


func _click_delete_portal(world_position: Vector2, _event: InputEventMouseButton) -> void:
	delete_portal(_pick_portal(world_position))


func _click_fountain(world_position: Vector2, _event: InputEventMouseButton) -> void:
	var picked := _pick_ink_fountain(world_position)
	if picked != null:
		_begin_layout_drag(picked, world_position)
	else:
		place_ink_fountain(world_position)


func _click_move_spawn(world_position: Vector2, _event: InputEventMouseButton) -> void:
	_begin_layout_drag(_pick_spawn_point(world_position), world_position)


func _handle_layout_mouse_motion(event: InputEventMouse) -> bool:
	if not is_instance_valid(_session.layout_drag_target):
		_cancel_layout_drag()
		return false
	var world_position := _event_world_position(event)
	var start_mouse: Vector2 = _session.layout_drag_start - _session.layout_drag_offset
	if world_position.is_equal_approx(start_mouse) \
	and _session.layout_drag_target.global_position.is_equal_approx(_session.layout_drag_start) \
	and _session.layout_drag_target.scale.is_equal_approx(_session.layout_drag_start_scale):
		return true
	if _session.layout_drag_resizing and _session.layout_drag_target is Sprite2D:
		var image: Sprite2D = _session.layout_drag_target
		if image.texture != null:
			var local_delta: Vector2 = image.get_parent().to_local(world_position) - image.get_parent().to_local(start_mouse)
			var ratio := local_delta.rotated(-image.rotation) / Vector2(image.texture.get_size())
			image.scale = Vector2.ONE * clampf(minf(_session.layout_drag_start_scale.x + ratio.x, _session.layout_drag_start_scale.y + ratio.y),
				MapImportedImageScript.MIN_SCALE, MapImportedImageScript.MAX_SCALE)
			return true
	var target_position := world_position + _session.layout_drag_offset
	if _session.layout_drag_target.global_position.is_equal_approx(target_position):
		return true
	_session.layout_drag_target.global_position = target_position
	if _session.layout_drag_target.is_in_group(&"map_monster"):
		_session.pending_monster_move = _session.layout_drag_target
	elif _session.layout_drag_target.has_method("sync_physics_from_node"):
		_session.layout_drag_target.sync_physics_from_node()
	if not _session.layout_drag_target.is_in_group(&"map_monster"):
		_refresh_layout_overlay(_session.layout_drag_target)
	return true


func _begin_layout_drag(target, world_position: Vector2) -> void:
	_cancel_layout_drag()
	if target == null:
		_refresh_layout_overlay()
		return
	LayoutTools.begin_drag(_session, target, world_position)
	if target.is_in_group(&"map_monster"):
		_lock_monster_drag_view()
	_refresh_layout_overlay(target)
	if _session.mode == CONTROL_MODE:
		_select_portal(target if target.is_in_group(MapPortalScript.GROUP) else null)
		_set_imported_image_selection(target if target.is_in_group(MapImportedImageScript.GROUP) else null)


func _finish_layout_drag() -> void:
	_flush_monster_drag_move()
	_unlock_monster_drag_view()
	var edit: Dictionary = LayoutTools.finish_drag(_session)
	if not edit.is_empty():
		_record_edit(edit)
	_refresh_layout_overlay(_session.selected_control_target if _session.mode == CONTROL_MODE else null)


func _cancel_layout_drag() -> void:
	_flush_monster_drag_move()
	_unlock_monster_drag_view()
	LayoutTools.cancel_drag(_session)


func _pick_control_target(world_position: Vector2, resizable_only := false):
	var candidates := [
		_find_imported_image_at(world_position),
		_find_monster_at(world_position),
		_find_map_text_at(world_position),
	]
	if not resizable_only:
		candidates.append_array([
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
	if is_instance_valid(_session.layout_drag_target):
		_finish_layout_drag()
	var deleted := false
	if target.is_in_group(MapMonsterScript.GROUP):
		deleted = delete_monster(target)
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
		if _session.selected_control_target == target:
			_session.selected_control_target = null
		_refresh_layout_overlay(_session.selected_control_target)
		_update_layout_status()
	return deleted


func _resize_control_target(target, direction: float) -> bool:
	if not is_instance_valid(target):
		return false
	if target.is_in_group(MapMonsterScript.GROUP):
		_session.selected_monster = target
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
	_refresh_layout_overlay(_session.selected_control_target)
	return true


func _control_target_name(target) -> String:
	if not is_instance_valid(target):
		return "左键拖动对象；滚轮缩放；右键删除怪物、画布、文本、对话、图片、传送门或墨泉"
	if target.is_in_group(MapImportedImageScript.GROUP):
		return "图片：拖动定位，右下角或滚轮缩放，右键删除"
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
	return LayoutTools.pick_respawn_point(_respawn_points(), world_position, _layout_pick_radius())


func _pick_play_canvas(world_position: Vector2) -> Node2D:
	return LayoutTools.pick_play_canvas(_play_canvases(), world_position)


func place_respawn_point(world_position: Vector2, record_undo := true) -> Marker2D:
	var level := _level_root()
	var point: Marker2D = LayoutTools.create_respawn_point(level, world_position)
	if point == null:
		return null
	if record_undo:
		_record_edit({"type": &"respawn_place", "target": point})
	_refresh_layout_overlay(point)
	return point


func delete_respawn_point(point: Marker2D) -> bool:
	if not is_instance_valid(point) or not point.is_in_group(RESPAWN_POINT_GROUP):
		return false
	if _session.layout_drag_target == point:
		_finish_layout_drag()
	_record_edit({"type": &"respawn_delete", "position": point.global_position, "target": point})
	point.get_parent().remove_child(point)
	point.queue_free()
	_refresh_layout_overlay()
	return true


func _portals() -> Array:
	return LayoutTools.portals(_level_root())


func _pick_portal(world_position: Vector2) -> Node2D:
	return LayoutTools.pick_portal(_portals(), world_position)


func _ink_fountains() -> Array:
	return LayoutTools.ink_fountains(_level_root())


func _pick_ink_fountain(world_position: Vector2) -> Node2D:
	return LayoutTools.pick_ink_fountain(_ink_fountains(), world_position)


func place_ink_fountain(world_position: Vector2, record_undo := true) -> Node2D:
	var fountain: Node2D = LayoutTools.create_ink_fountain(_level_root(), world_position)
	if fountain == null:
		return null
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
	var portal: Node2D = LayoutTools.create_portal(_level_root(), world_position, destination)
	if portal == null:
		return null
	if record_undo:
		_record_edit({"type": &"portal_place", "target": portal})
	_refresh_layout_overlay(portal)
	return portal


func delete_portal(portal: Node2D) -> bool:
	if not is_instance_valid(portal) or not portal.is_in_group(MapPortalScript.GROUP):
		return false
	if _session.layout_drag_target == portal:
		_finish_layout_drag()
	if _session.selected_control_target == portal:
		_session.selected_control_target = null
	_record_edit({"type": &"portal_delete", "position": portal.global_position,
		"destination": portal.target_map, "size": portal.portal_size, "scale": portal.scale, "target": portal})
	portal.get_parent().remove_child(portal)
	portal.queue_free()
	_session.selected_portal = null
	_refresh_layout_overlay()
	return true


func _portal_choice() -> String:
	return _portal_target_path


func _select_portal(portal: Node2D) -> void:
	_session.selected_portal = portal
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
	if _session.mode == LAYOUT_MODE_PLACE_CANVAS:
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
	if _session.layout_drag_target == canvas:
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
	if _session.selected_control_target == canvas:
		_session.selected_control_target = null
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
	if is_instance_valid(_palette):
		return
	_palette = preload("res://debug/creative/ui/editor_palette.tscn").instantiate()
	_monster_palette = _palette
	_palette.query_ink_quota = ink_quota_of
	_palette.action_requested.connect(_dispatch_palette_action)
	add_child(_palette)
	var brush: Dictionary = _map_canvas.brush_range()
	_palette.bind_canvas(_map_canvas, {
		"brush_min": brush.min, "brush_max": brush.max, "brush_step": brush.step,
		"brush_size": brush.value, "selected_ink": _map_canvas.surface.selected_ink,
		"nails_visible": _map_canvas.nails_visible(),
	})

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
	if is_instance_valid(_palette):
		_palette._refresh_editor_visibility()

func _toggle_monster_palette_panel() -> void:
	if is_instance_valid(_palette):
		_palette._toggle_monster_palette_panel()

func _select_editor_ink(index: int) -> void:
	if is_instance_valid(_palette):
		_palette._select_editor_ink(index)

func _refresh_editor_ink(index: int, animate := true) -> void:
	if is_instance_valid(_palette):
		_palette._refresh_editor_ink(index, animate)

func select_monster_tool(mode: int) -> void:
	if mode != MONSTER_MODE_NONE and mode != MONSTER_MODE_DELETE and mode != MONSTER_MODE_ADJUST \
	and mode != DIALOGUE_MODE_PLACE and mode != DIALOGUE_MODE_DELETE \
	and mode != TEXT_MODE_PLACE and mode != TEXT_MODE_DELETE \
	and mode != CONTROL_MODE and not LAYOUT_MODES.has(mode) \
	and not MONSTER_KINDS.has(mode):
		mode = MONSTER_MODE_NONE
	elif mode == _session.mode:
		mode = MONSTER_MODE_NONE
	_session.mode = mode
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
		_session.selected_control_target = null
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
	if not is_instance_valid(_palette) or _map_canvas == null:
		return
	var tool: int = _map_canvas.surface.tool
	_palette.sync_gear_buttons(tool == CanvasSurfaceScript.Tool.GEAR,
		tool == CanvasSurfaceScript.Tool.GEAR_8)


## 无限标签是机关部件（钉在红墨上供给无尽能源），入口在右侧「机关部件」栏。
## 再点一次回到手，和齿轮按钮同一套开关语义。
func select_infinite_nail_tool() -> void:
	if not active or _map_canvas == null or not _map_canvas._map_editor_mode:
		return
	if _map_canvas.surface.tool == CanvasSurfaceScript.Tool.INFINITE_NAIL:
		_map_canvas.set_tool(CanvasSurfaceScript.Tool.HAND)
		return
	select_monster_tool(MONSTER_MODE_NONE)
	_map_canvas.set_tool(CanvasSurfaceScript.Tool.INFINITE_NAIL)


func _sync_infinite_nail_button() -> void:
	if is_instance_valid(_palette):
		_palette.sync_infinite_nail_button(_map_canvas != null \
			and _map_canvas.surface.tool == CanvasSurfaceScript.Tool.INFINITE_NAIL)


func select_control_tool() -> void:
	if _session.mode == CONTROL_MODE:
		return
	select_monster_tool(CONTROL_MODE)


func _update_monster_buttons() -> void:
	_sync_gear_button()
	for index in _monster_buttons.size():
		_monster_buttons[index].set_pressed_no_signal(_session.mode == int(_monster_buttons[index].get_meta("monster_kind")))
	if _delete_monster_button != null:
		_delete_monster_button.set_pressed_no_signal(_session.mode == MONSTER_MODE_DELETE)
	if _adjust_monster_button != null:
		_adjust_monster_button.set_pressed_no_signal(_session.mode == MONSTER_MODE_ADJUST)
	if _reset_monster_scale_button != null:
		_reset_monster_scale_button.disabled = not is_instance_valid(_session.selected_monster)
	if _place_dialogue_button != null:
		_place_dialogue_button.set_pressed_no_signal(_session.mode == DIALOGUE_MODE_PLACE)
	if _delete_dialogue_button != null:
		_delete_dialogue_button.set_pressed_no_signal(_session.mode == DIALOGUE_MODE_DELETE)
	if _place_text_button != null:
		_place_text_button.set_pressed_no_signal(_session.mode == TEXT_MODE_PLACE)
	if _delete_text_button != null:
		_delete_text_button.set_pressed_no_signal(_session.mode == TEXT_MODE_DELETE)
	for mode in _layout_buttons:
		(_layout_buttons[mode] as Button).set_pressed_no_signal(_session.mode == int(mode))
	_update_layout_status()


func _on_canvas_tool_changed(_tool: int) -> void:
	_sync_gear_button()
	_sync_infinite_nail_button()
	if _syncing_canvas_tool or _session.mode == MONSTER_MODE_NONE:
		return
	_session.mode = MONSTER_MODE_NONE
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
	var fixed_scale_value: float = MONSTER_FIXED_SCALES.get(kind, 1.0)
	# 无指定尺寸时采用默认值；删除撤销/恢复必须保留用户缩放。
	var scale := Vector2.ONE * fixed_scale_value if monster_scale == Vector2.ZERO else monster_scale
	var monster: Node2D = MonsterTools.create(container, MONSTER_SCENES[scene_index],
		MONSTER_NODE_NAMES[scene_index], world_position, scale)
	if monster == null:
		return null
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
	return delete_monster(_find_monster_at(world_position))


func delete_monster(monster: Node2D, record_undo := true) -> bool:
	var container := _ensure_monster_container()
	if not is_instance_valid(monster) or container == null or monster.get_parent() != container:
		return false
	if _session.layout_drag_target == monster:
		_finish_layout_drag()
	if monster == _session.selected_monster:
		_set_selected_monster(null)
	if _session.selected_control_target == monster:
		_session.selected_control_target = null
	var removed := {
		"type": &"monster_delete",
		"id": str(monster.get("editor_id")),
		"kind": int(monster.get("kind")),
		"position": monster.global_position,
		"scale": monster.scale,
	}
	MonsterTools.remove(container, monster)
	if record_undo:
		_record_edit(removed)
	_refresh_layout_overlay(_session.selected_control_target)
	return true


func _set_monster_physics_paused(paused: bool) -> void:
	MonsterTools.set_physics_paused(_ensure_monster_container(), paused)


func _find_monster_at(world_position: Vector2) -> Node2D:
	return MonsterTools.find_at(_ensure_monster_container(), world_position,
		_layout_pick_radius() * (8.0 / 28.0))


func _set_selected_monster(monster: Node2D) -> void:
	_flush_monster_drag_move()
	_unlock_monster_drag_view()
	_session.selected_monster = monster if is_instance_valid(monster) else null
	_session.dragging_monster = false
	_update_monster_buttons()
	_update_monster_status()


func _update_monster_status() -> void:
	if _monster_status_label == null:
		return
	if not is_instance_valid(_session.selected_monster):
		_monster_status_label.text = "未选中小怪"
		return
	_monster_status_label.text = "%s  大小 ×%.1f" % [
		str(_session.selected_monster.get("display_name")), _session.selected_monster.scale.x
	]


func _resize_selected_monster(amount: float) -> void:
	if not is_instance_valid(_session.selected_monster):
		return
	var old_position := _session.selected_monster.global_position
	var old_scale := _session.selected_monster.scale
	var next_scale := maxf(old_scale.x + amount, MONSTER_MIN_SCALE)
	if not is_finite(next_scale) or is_equal_approx(next_scale, old_scale.x):
		return
	_session.selected_monster.scale = Vector2.ONE * next_scale
	if _session.selected_monster.has_method("sync_physics_from_node"):
		_session.selected_monster.sync_physics_from_node(true)
	_record_monster_transform(_session.selected_monster, old_position, old_scale)


func _reset_selected_monster_scale() -> void:
	if not is_instance_valid(_session.selected_monster):
		return
	var old_position := _session.selected_monster.global_position
	var old_scale := _session.selected_monster.scale
	# 恢复到该种类的固定大小，与"平路"关卡一致。
	var kind: int = int(_session.selected_monster.get("kind"))
	var fixed_scale_value: float = MONSTER_FIXED_SCALES.get(kind, 1.0)
	_session.selected_monster.scale = Vector2.ONE * fixed_scale_value
	if _session.selected_monster.has_method("sync_physics_from_node"):
		_session.selected_monster.sync_physics_from_node(true)
	_record_monster_transform(_session.selected_monster, old_position, old_scale)


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
	return MonsterTools.count(_ensure_monster_container())


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
	var container := _level_root().get_node_or_null("DialogueTriggers") as Node2D
	if container != null:
		container.visible = active
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
	if _session.layout_drag_target == image:
		_finish_layout_drag()
	if _session.selected_control_target == image:
		_session.selected_control_target = null
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
	_history.record(edit)

func _dispose_history_edit(edit: Dictionary) -> void:
	_commands._dispose_history_edit(edit)


## 撤销重放要靠 `editor_id` 找回被恢复的节点；实现已搬进 `editor_commands`，
## 这里保留转发是因为 `test_editor_record_redo` 仍按旧入口调用（P7 随测试一起改）。
func _find_editor_node(container: Node, editor_id: String) -> Node:
	return _commands._find_editor_node(container, editor_id)

func _clear_edit_history() -> void:
	_history.clear()

func undo_last_edit() -> bool:
	return _history.undo()



func _capture_redo_data(edit: Dictionary) -> Dictionary:
	return _commands._capture_redo_data(edit)

func redo_last_edit() -> bool:
	return _history.redo()

func _rebind_history_target(old_target, restored: Node) -> void:
	_history.rebind(old_target, restored)

func _remove_monster_by_id(monster_id: String) -> bool:
	return delete_monster(MonsterTools.find_by_id(_ensure_monster_container(), monster_id), false)


func _apply_monster_transform(monster_id: String, position: Vector2, scale: Vector2) -> bool:
	var applied := MonsterTools.apply_transform(_ensure_monster_container(), monster_id, position, scale)
	if applied:
		_update_monster_status()
	return applied


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
	# 保存/自动保存会为了打包临时把玩家设为可见；这里在渲染前再兜底一次，
	# 避免任何异步路径把上一个游玩实例的墨水瓶留在编辑器画面里。
	_hide_editor_player()
	_flush_monster_drag_move()
	if _session.monster_drag_view_locked:
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
	# 角色几何和手臂约束已退出编辑世界，镜头锚点不再经过物理积分。
	_body.position += direction * fly_speed * delta
	_body.refresh_com()
	_body.update_aabb()
	_player.global_position = _level_root().to_global(_body.position)
	_body.linear_velocity = Vector2.ZERO
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
	_ensure_save_view()
	_save_view.map_path = map_path
	_save_view.baked_map_path = baked_map_path
	_save_view._build_save_directory_dialog()

func _request_map_save_directory() -> void:
	_ensure_save_view()
	_save_view.map_path = map_path
	_save_view.baked_map_path = baked_map_path
	_save_view._request_map_save_directory()

func _build_map_save_window() -> void:
	_ensure_save_view()
	_save_view.map_path = map_path
	_save_view.baked_map_path = baked_map_path
	_save_view._build_map_save_window()

func _open_map_save_window() -> void:
	_ensure_save_view()
	_save_view.map_path = map_path
	_save_view.baked_map_path = baked_map_path
	_save_view._open_map_save_window()

func _refresh_map_save_preview() -> void:
	_ensure_save_view()
	_save_view.map_path = map_path
	_save_view.baked_map_path = baked_map_path
	_save_view._refresh_map_save_preview()

func _on_save_directory_chosen(directory: String) -> void:
	_ensure_save_view()
	_save_view.map_path = map_path
	_save_view.baked_map_path = baked_map_path
	_save_view._on_save_directory_chosen(directory)

func _confirm_named_map_save() -> void:
	_ensure_save_view()
	_save_view.map_path = map_path
	_save_view.baked_map_path = baked_map_path
	_save_view._confirm_named_map_save()

func _save_current_map_overwrite() -> Error:
	if map_path.is_empty():
		return ERR_INVALID_PARAMETER
	baked_map_path = map_path.get_basename() + ".png"
	return _save_editor_snapshot_to(map_path)


## 手动保存/自动保存统一写“墨水为主”的快照；
## 否则会把当前编辑世界中临时存在/旧地图遗留的固化实体原样写回去。
func _save_editor_snapshot_to(save_path: String) -> Error:
	if active:
		_inkify_non_mechanism_bodies()
	return export_map_to(save_path)


## 编辑中的自动保存也只写“墨水为主”的快照：
## 先选择性墨化非机关实体，再打包；机关实体保持可玩，其余进入 editor_draft。
## 具体节流与回调在 `editor_save.gd`；这里只提供当前编辑状态。
func _queue_edit_auto_save() -> void:
	if not active or not auto_save_edits or map_path.is_empty():
		return
	_auto_save_revision += 1
	EditorSave.schedule_auto_save({
		"host": self,
		"revision": _auto_save_revision,
		"map_path": map_path,
		"full_delay": full_auto_save_delay,
		"is_current": _auto_save_is_current,
		"export_scene": _save_editor_snapshot_to,
	})


## 只有这次编辑仍然是最新的、且还在编辑态，才允许落盘。
func _auto_save_is_current(revision: int) -> bool:
	return revision == _auto_save_revision and active and auto_save_edits


func _restore_editor_document() -> bool:
	var tree_root := get_tree().current_scene
	if tree_root == null or not tree_root.has_method("restore_editor_level") or map_path.is_empty():
		return false
	var checkpoint: Dictionary = tree_root.get_meta(&"editor_preview_document", {})
	if checkpoint.get("path", "") == map_path and checkpoint.get("scene") is PackedScene:
		_map_reload_in_progress = true
		tree_root.call_deferred("restore_editor_level", checkpoint.scene, _mode_transition_pending)
		return true
	if _map_reload_in_progress:
		return true
	# 自动保存会反复覆盖同一路径；忽略资源缓存才能恢复磁盘上的最新版本。
	# 后台读取避免 F2 在大地图上冻结主线程。
	var error := ResourceLoader.load_threaded_request(
		map_path, "PackedScene", false, ResourceLoader.CACHE_MODE_IGNORE
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
			await _transition.finish()
		return
	if not is_instance_valid(tree_root):
		if _mode_transition_pending:
			await _transition.finish()
		return
	# 交接后旧节点即将释放，异步加载、激活新编辑器和揭幕均由 Root 持有。
	tree_root.call_deferred("restore_editor_level", packed, _mode_transition_pending)


func _activate_restored_editor() -> void:
	# Root 会在入树前把编辑器关卡的 Player 隐藏，避免重载闪一帧。
	# 这个隐藏不是“进入编辑器前的可见性”，退出编辑器必须恢复为可见。
	_saved_player_visible = true
	_player_visibility_saved = true
	_skip_restore_on_enter = true
	set_active(true)


## 保存只序列化文档，不承担固化或模式切换。
func export_map_to(save_path: String) -> Error:
	var error := EditorSave.export_scene({
		"level_root": _level_root(),
		"map_canvas": _map_canvas,
		"play_canvases": _play_canvases(),
		# 编辑态里角色是隐藏的；打包瞬间要按进编辑器之前的状态还原，
		# 否则存出来的关卡一开始就是"看不见的玩家"。
		"player": _player,
		"player_visible": _saved_player_visible,
		"player_modulate": _saved_player_modulate,
		"bake_preview": save_preview_on_export,
		"baked_map_path": baked_map_path,
	}, save_path)
	if error == OK:
		map_saved.emit(save_path)
	return error


func _normalize_scene_path(path: String) -> String:
	return EditorSave.normalize_scene_path(path)


## 编辑中角色、普通画布和工具栏的状态不应被写进关卡。
## 打包瞬间恢复正常游玩布局，pack 完成后立刻回到编辑布局。
func _pack_as_playable_scene(packed: PackedScene, scene: Node) -> Error:
	return EditorSave.pack_playable(packed, scene, {
		"player": _player,
		"player_visible": _saved_player_visible,
		"player_modulate": _saved_player_modulate,
		"map_canvas": _map_canvas,
		"play_canvases": _play_canvases(),
	})


## 要存的关卡根 = 装着画布的那个节点。
## ⚠️ 别用 `get_tree().current_scene`：主场景是 `root/root.tscn` 的 Root 容器，
##    关卡和 UI 都是它 `_ready()` 里运行时 add_child 挂上去的（owner 为空），
##    `PackedScene.pack()` 只收 owner 指回根的节点 —— 存出来会是一个 314 字节的空壳。
##    直接跑关卡场景（F6）时，画布的父节点正好就是关卡根，这条规则两种情况都对。
func _level_root() -> Node:
	if _map_canvas != null:
		return _map_canvas.get_parent()
	return get_tree().current_scene

#endregion

## 视图只提交已知动作；不允许通过反射任意调用编辑器。
func _dispatch_palette_action(action: StringName, arguments: Array) -> void:
	var actions := {
		&"set_brush_size": _map_canvas.set_brush_size,
		&"set_nails_visible": _map_canvas.set_nails_visible,
		&"select_monster_tool": select_monster_tool,
		&"select_gear_tool": select_gear_tool,
		&"select_infinite_nail_tool": select_infinite_nail_tool,
		&"_open_map_save_window": _open_map_save_window,
		&"_reset_selected_monster_scale": _reset_selected_monster_scale,
		&"_sync_gear_button": _sync_gear_button,
		&"_build_canvas_size_dialog": _build_canvas_size_dialog,
		&"_refresh_portal_choices": _refresh_portal_choices,
		&"_on_portal_destination_selected": _on_portal_destination_selected,
		&"_open_portal_menu": _open_portal_menu,
		&"_open_canvas_size_dialog": _open_canvas_size_dialog,
		&"_on_ink_quota_changed": _on_ink_quota_changed,
		&"reset_ink_quota": reset_ink_quota,
	}
	if actions.has(action):
		actions[action].callv(arguments)

func _configure_history() -> void:
	_commands.configure(_map_canvas, _history, {
		&"_remove_monster_by_id": _remove_monster_by_id,
		&"place_monster": place_monster,
		&"_apply_monster_transform": _apply_monster_transform,
		&"_remove_dialogue_trigger_by_id": _remove_dialogue_trigger_by_id,
		&"place_dialogue_trigger": place_dialogue_trigger,
		&"_remove_map_text_by_id": _remove_map_text_by_id,
		&"_restore_deleted_image": _restore_deleted_image,
		&"place_map_text": place_map_text,
		&"_refresh_layout_overlay": _refresh_layout_overlay,
		&"_undo_placed_layout_node": _undo_placed_layout_node,
		&"_restore_deleted_play_canvas": _restore_deleted_play_canvas,
		&"place_ink_fountain": place_ink_fountain,
		&"place_respawn_point": place_respawn_point,
		&"_restore_ink_quota": _restore_ink_quota,
		&"place_portal": place_portal,
		&"place_play_canvas": place_play_canvas,
		&"delete_play_canvas": delete_play_canvas,
		&"_ensure_monster_container": _ensure_monster_container,
		&"_ensure_dialogue_container": _ensure_dialogue_container,
		&"_ensure_text_container": _ensure_text_container,
	})
	_history.limit = MAX_EDIT_HISTORY
	_history.capture = _commands._capture_redo_data
	_history.undo_command = _commands.undo
	_history.redo_command = _commands.redo
	_history.dispose = _commands._dispose_history_edit
	_history.recorded.connect(_on_history_recorded)
	_history.changed.connect(_queue_edit_auto_save)

func _on_history_recorded(edit: Dictionary) -> void:
	if edit.get("type", &"") != &"canvas" and _map_canvas != null:
		_map_canvas.surface.clear_history()

func _ensure_save_view() -> void:
	if is_instance_valid(_save_view):
		return
	_save_view = preload("res://debug/creative/ui/editor_save_view.tscn").instantiate()
	_save_view.presentation_root = self
	_save_view.save_scene = _save_scene_from_form
	add_child(_save_view)

func _save_scene_from_form(path: String) -> Error:
	var previous_map := map_path
	var previous_bake := baked_map_path
	map_path = path
	baked_map_path = path.get_basename() + ".png"
	var error := _save_editor_snapshot_to(path)
	if error != OK:
		map_path = previous_map
		baked_map_path = previous_bake
	return error

#region 对外入口
## 编辑器对外的**唯一契约**：输入、拖动、查询。
##
## 实现仍留在私有方法里（它们是实现细节，允许继续拆分）；
## 测试和外部脚本只调这里，这样重命名/搬家不会再把 29 个测试文件打散。

func editor_input(event: InputEvent) -> bool:
	return _handle_editor_input(event)


func editor_mouse_button(event: InputEventMouseButton) -> bool:
	return _handle_layout_mouse_button(event)


func editor_mouse_motion(event: InputEventMouse) -> bool:
	return _handle_layout_mouse_motion(event)


func editor_drag_begin(target, world_position: Vector2) -> void:
	_begin_layout_drag(target, world_position)


func editor_drag_finish() -> void:
	_finish_layout_drag()


func editor_drag_cancel() -> void:
	_cancel_layout_drag()


func editor_portals() -> Array:
	return _portals()


func editor_fountains() -> Array:
	return _ink_fountains()


func editor_respawn_points() -> Array:
	return _respawn_points()


func editor_canvases() -> Array:
	return _play_canvases()


func editor_canvas() -> Node:
	return _map_canvas


func editor_palette() -> Node:
	return _palette


func editor_undo_available() -> bool:
	return not _history.undo_stack.is_empty()


func editor_redo_available() -> bool:
	return not _history.redo_stack.is_empty()


func editor_history_depth() -> int:
	return _history.undo_stack.size()


func editor_clear_history() -> void:
	_clear_edit_history()
#endregion
