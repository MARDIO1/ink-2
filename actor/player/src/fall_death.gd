extends Node
## 掉落死亡：玩家连续下落超过阈值时显示"已死亡"，倒计时后回到最近的出生点或复活点。
## 挂在 Player 节点下作为子节点；通过 PlayerInput.support 判断是否着地。

#region 配置
## 连续下落多少像素触发死亡。
@export var fall_death_threshold := 1000.0
## 死亡后多少秒重生。
@export var respawn_delay := 3.0
## 玩家进入此范围后，才允许“脱离卡死”返回该点；不会跳到未经过的点。
@export var checkpoint_visit_radius := 80.0
const PLAYER_SPAWN_NAME := "PlayerSpawn"
const PLAYER_SPAWN_GROUP := &"player_spawn"
const RESPAWN_POINT_PREFIX := "RespawnPoint"
const RESPAWN_POINT_GROUP := &"respawn_point"
const InkPalette := preload("res://ink/src/ink_palette.gd")
const SafeSpawnSearch := preload("res://actor/player/src/safe_spawn_search.gd")
var recovering := false
var recovery_error := ""
var last_search_stats: Dictionary = {}
var _pending_safety_check: Dictionary = {}
#endregion


#region 状态
var _player: Node2D
var _player_input: Node
var _health: Node
var _body = null # PBody，延迟到 _body 烘焙出来后取
## 本次下落轨迹的最高点（y 最小）；着地时重置为当前 y。
var _peak_y := INF
var _dead := false
var _death_timer := 0.0
var _death_layer: CanvasLayer
var _death_label: Label
var _visited_points: Array[Marker2D] = []
var _checkpoints: Array = []
var _checkpoints_initialized := false
var _initial_position := Vector2.ZERO
var _initial_rotation := 0.0
#endregion


#region 生命周期
func _ready() -> void:
	process_physics_priority = 100 # 世界推进后再复查实际落点。
	_player = get_parent()
	_initial_position = _player.global_position
	_initial_rotation = _player.global_rotation
	_player_input = _player.get_node_or_null("PlayerInput")
	_health = _player.get_node_or_null("InkHealth")
	if _health != null and not _health.depleted.is_connected(_on_ink_depleted):
		_health.depleted.connect(_on_ink_depleted)
	_build_death_ui()


func _physics_process(_delta: float) -> void:
	if not _pending_safety_check.is_empty() and not recovering and not _editor_active():
		_verify_after_resume()
		return
	if not _editor_active():
		_update_visited_points()
	else:
		_checkpoints_initialized = false # 编辑器可新增、移动或删除复活点。
	if _dead:
		_death_timer -= _delta
		_death_label.text = "已死亡\n%.0f" % ceil(_death_timer)
		if _death_timer <= 0.0:
			_respawn()
		return

	if _body == null:
		_body = _player.get("body")
		if _body == null:
			return

	var pos: Vector2 = _body.com_world()
	var vel: Vector2 = _body.linear_velocity
	var grounded := _player_input != null and _player_input.support != null

	if grounded or absf(vel.y) < 5.0:
		# 着地或几乎静止：重置最高点，下一次下落从这里算起。
		_peak_y = pos.y
	elif vel.y > 0.0:
		# 下落中：累计从最高点下降的距离。
		if pos.y - _peak_y > fall_death_threshold:
			_die()
	else:
		# 上升中：更新最高点。
		_peak_y = minf(_peak_y, pos.y)
#endregion


#region 死亡 UI
func _build_death_ui() -> void:
	_death_layer = CanvasLayer.new()
	_death_layer.layer = 200
	_death_label = Label.new()
	_death_label.add_theme_font_size_override("font_size", 56)
	_death_label.anchor_right = 1.0
	_death_label.anchor_bottom = 1.0
	_death_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_death_layer.add_child(_death_label)
	add_child(_death_layer)
	_death_layer.visible = false
#endregion


#region 死亡与重生
func _die() -> void:
	if _dead:
		return
	_dead = true
	_death_timer = respawn_delay
	_death_layer.visible = true
	_death_label.text = "已死亡"
	if _body:
		_body.linear_velocity = Vector2.ZERO
		_body.angular_velocity = 0.0
		_body.control_force = Vector2.ZERO
		_body.control_torque = 0.0


func _respawn() -> void:
	_dead = false
	_death_layer.visible = false
	_peak_y = INF

	var spawn := _find_respawn_target()
	if _body == null:
		return

	if spawn != null:
		_teleport_to(spawn.global_position, spawn.global_rotation)
	else:
		_teleport_to(_initial_position, _initial_rotation)
	_refill_black_ink()


func _on_ink_depleted(material_id: int) -> void:
	if material_id == InkPalette.material_id_of(InkPalette.BLACK) and not _editor_active():
		_die()


func _refill_black_ink() -> void:
	if _health == null:
		return
	var black_id: int = InkPalette.material_id_of(InkPalette.BLACK)
	_health.add(black_id, _health.max_of(black_id) - _health.ink_of(black_id))


func _teleport_to(target: Vector2, target_rotation: float) -> void:
	# 与 creative.gd _reset_player_to_spawn 相同的传送方式。
	_player.global_position = target
	_player.global_rotation = target_rotation
	var level := _level_root() as Node2D
	_body.position = level.to_local(target)
	_body.rotation = target_rotation - level.global_rotation
	_body.linear_velocity = Vector2.ZERO
	_body.angular_velocity = 0.0
	_body.control_force = Vector2.ZERO
	_body.control_torque = 0.0
	_body.awake = true
	_body.sleep_timer = 0.0
	_body.refresh_com()
	_body.update_aabb()
	if _player_input != null:
		_player_input.support = null

	var hand := _player.get_node_or_null("Arm/Hand/HandControl")
	if hand != null and hand.has_method("reset_after_player_teleport"):
		hand.reset_after_player_teleport()


## 暂停菜单也可调用。不回血、不更改普通死亡的最近复活点规则。
func escape_stuck(skipped: Array = [], retry := 0) -> bool:
	if _editor_active() or recovering:
		return false
	_body = _player.get("body")
	if _body == null:
		return false
	recovering = true
	recovery_error = ""
	_pending_safety_check = {}
	var was_paused := get_tree().paused
	get_tree().paused = true
	_update_visited_points()
	var level := _level_root() as Node2D
	var points: Array = []
	for point in _visited_points:
		if is_instance_valid(point) and point.is_inside_tree():
			points.append(point)
	var current_position: Vector2 = _body.com_world()
	points.sort_custom(func(a, b): return level.to_local(a.global_position).distance_squared_to(current_position) < level.to_local(b.global_position).distance_squared_to(current_position))
	var targets: Array = []
	for point in points.slice(0, 8):
		targets.append({"position": level.to_local(point.global_position), "rotation": point.global_rotation - level.global_rotation})
	if targets.is_empty():
		targets.append({"position": level.to_local(_initial_position), "rotation": _initial_rotation - level.global_rotation})
	var hand := _player.get_node_or_null("Arm/Hand/HandControl")
	var search := SafeSpawnSearch.new()
	search.setup(self, level.world, _body, hand)
	var landing: Dictionary = await search.find(targets, skipped)
	var previous_position := _player.global_position
	var previous_rotation := _player.global_rotation
	# 提交后等待一帧，重新读取当前物品和碎屑位置，而非只使用首次快照。
	if not landing.is_empty():
		_teleport_to(level.to_global(landing.position), landing.rotation + level.global_rotation)
		await get_tree().process_frame
		if not await search.verify(_body.position, _body.rotation):
			skipped.append(landing.position)
			landing = await search.find(targets, skipped)
			if not landing.is_empty():
				_teleport_to(level.to_global(landing.position), landing.rotation + level.global_rotation)
				if not await search.verify(_body.position, _body.rotation):
					landing = {}
		if landing.is_empty():
			_teleport_to(previous_position, previous_rotation)
	last_search_stats = {"candidates": search.candidates_checked, "pairs": search.pairs_checked, "yielded_frames": search.frames_yielded}
	if landing.is_empty():
		recovery_error = "落点被阻挡或没有安全支撑，请清理附近障碍后重试。"
		recovering = false
		# 找不到安全位置时不自动恢复游戏，不强行把玩家塞进物品。
		return false
	_dead = false
	_death_timer = 0.0
	_death_layer.visible = false
	_peak_y = INF
	# 复位抓握后同步工具栏，避免手已启用但 UI 仍显示画笔。
	for canvas in get_tree().get_nodes_in_group(&"play_canvas"):
		if _level_root().is_ancestor_of(canvas) and canvas.active:
			canvas.activate_hand_tool()
	_pending_safety_check = {"position": landing.position, "retry": retry}
	recovering = false
	get_tree().paused = was_paused
	return true


## 恢复游玩后的首个真实物理步再复查一次；只运行一次，不成为常驻碰撞扫描。
func _verify_after_resume() -> void:
	var pending := _pending_safety_check
	_pending_safety_check = {}
	recovering = true
	get_tree().paused = true
	var search := SafeSpawnSearch.new()
	search.setup(self, _level_root().world, _body, _player.get_node_or_null("Arm/Hand/HandControl"))
	var safe: bool = await search.verify(_body.position, _body.rotation)
	recovering = false
	if safe:
		get_tree().paused = false
		return
	var menu := get_tree().get_first_node_in_group(&"esc_menu")
	if menu != null:
		menu.open_menu()
	var succeeded := false
	if int(pending.retry) < 1:
		if menu != null:
			succeeded = await menu._on_escape_stuck_button_pressed([pending.position], int(pending.retry) + 1)
		else:
			succeeded = await escape_stuck([pending.position], int(pending.retry) + 1)
			if succeeded:
				get_tree().paused = false
	if not succeeded:
		recovery_error = "落点被移动物品阻挡，请再次脱离卡死。"
		if menu != null:
			menu.show_recovery_status(recovery_error)


func _level_root() -> Node:
	return _player.get_parent()


func _editor_active() -> bool:
	var creative := _level_root().get_node_or_null("Creative")
	return creative != null and bool(creative.get("active"))


func _update_visited_points() -> void:
	if not _checkpoints_initialized:
		_checkpoints_initialized = true
		_checkpoints = _collect_respawn_points(_level_root())
		var spawn := _find_player_spawn(_level_root())
		if spawn != null:
			_checkpoints.append(spawn)
			if not _visited_points.has(spawn):
				_visited_points.append(spawn) # 关卡出生点始终是安全回退目标。
	var position: Vector2 = _body.com_world() if _body != null else _player.global_position
	for point in _checkpoints:
		if is_instance_valid(point) and not _visited_points.has(point) \
				and point.global_position.distance_squared_to(position) <= checkpoint_visit_radius * checkpoint_visit_radius:
			_visited_points.append(point)


func _nearest_visited_point() -> Marker2D:
	var position: Vector2 = _body.com_world() if _body != null else _player.global_position
	var best: Marker2D = null
	var best_distance := INF
	for point in _visited_points:
		if not is_instance_valid(point) or not point.is_inside_tree():
			continue
		var distance := point.global_position.distance_squared_to(position)
		if distance < best_distance:
			best = point
			best_distance = distance
	return best
#endregion


#region 复活点查找
## 在唯一出生点 PlayerSpawn 和全部 RespawnPoint 中统一计算距离，自动选择
## 离死亡位置最近的目标。旧地图的 PlayerSpawn2 等也兼容为复活点。
func _find_respawn_target() -> Marker2D:
	var root: Node = _player
	while root.get_parent() != null and root.get_parent().name != "Level":
		root = root.get_parent()
	var best: Marker2D = null
	var best_dist := INF
	var death_position: Vector2 = _body.com_world() if _body != null else _player.global_position
	var candidates := _collect_respawn_points(root)
	var player_spawn := _find_player_spawn(root)
	if player_spawn != null:
		candidates.append(player_spawn)
	for s in candidates:
		var d: float = s.global_position.distance_to(death_position)
		if d < best_dist:
			best_dist = d
			best = s
	return best


func _find_player_spawn(root: Node) -> Marker2D:
	if root is Marker2D and (root.is_in_group(PLAYER_SPAWN_GROUP) or String(root.name) == PLAYER_SPAWN_NAME):
		return root as Marker2D
	for child in root.get_children():
		var found := _find_player_spawn(child)
		if found != null:
			return found
	return null


func _collect_respawn_points(root: Node) -> Array:
	var result: Array = []
	for child in root.get_children():
		if child is Marker2D:
			var child_name := String(child.name)
			var legacy_respawn := child_name.begins_with(PLAYER_SPAWN_NAME) and child_name != PLAYER_SPAWN_NAME
			if child.is_in_group(RESPAWN_POINT_GROUP) \
			or child_name.begins_with(RESPAWN_POINT_PREFIX) or legacy_respawn:
				result.append(child)
		result.append_array(_collect_respawn_points(child))
	return result
#endregion
