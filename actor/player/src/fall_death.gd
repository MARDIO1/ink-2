extends Node
## 掉落死亡：玩家连续下落超过阈值时显示"已死亡"，倒计时后回到最近的出生点或复活点。
## 挂在 Player 节点下作为子节点；通过 PlayerInput.support 判断是否着地。

#region 配置
## 连续下落多少像素触发死亡。
@export var fall_death_threshold := 1000.0
## 死亡后多少秒重生。
@export var respawn_delay := 3.0
## 单次实际扣除的黑墨低于此值时不播放受伤音效。
@export_range(0.0, 20000.0, 1.0, "or_greater") var hurt_sound_threshold := 100.0
## 连续受伤时避免同一段声音过密重播。
@export_range(0.0, 2.0, 0.01) var hurt_sound_cooldown := 0.25
## 玩家进入此范围后，才允许“脱离卡死”返回该点；不会跳到未经过的点。
@export var checkpoint_visit_radius := 80.0
const PLAYER_SPAWN_NAME := "PlayerSpawn"
const PLAYER_SPAWN_GROUP := &"player_spawn"
const RESPAWN_POINT_PREFIX := "RespawnPoint"
const RESPAWN_POINT_GROUP := &"respawn_point"
const InkPalette := preload("res://ink/src/ink_palette.gd")
const SafeSpawnSearch := preload("res://actor/player/src/safe_spawn_search.gd")
const DeathEffect := preload("res://actor/effects/character_death.gd")
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
var _death_bodies: Array[Dictionary] = []
var _death_nodes: Array[Dictionary] = []
var _death_effect: Node2D
var _revive_effect: Node2D
var _revive_nodes: Array[Dictionary] = []
var _death_visual_duration := 1.2
var _last_hurt_sound_ms := -1000000
@onready var _hurt_sound: AudioStreamPlayer = $HurtSound
@onready var _death_sound: AudioStreamPlayer = $DeathSound
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
	if _health != null and not _health.damaged.is_connected(_on_health_damaged):
		_health.damaged.connect(_on_health_damaged)
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
		_death_layer.visible = _death_timer <= respawn_delay - _death_visual_duration
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
			_die(true)
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
func _on_health_damaged(amount: float) -> void:
	var now_ms := Time.get_ticks_msec()
	if _dead or amount < hurt_sound_threshold \
			or now_ms - _last_hurt_sound_ms < roundi(hurt_sound_cooldown * 1000.0):
		return
	_last_hurt_sound_ms = now_ms
	_hurt_sound.play()


func _die(only_dissolve := false) -> void:
	if _dead:
		return
	_dead = true
	_hurt_sound.stop()
	_death_sound.play()
	_death_timer = respawn_delay
	_death_visual_duration = 0.65 if only_dissolve else 1.2
	_death_layer.visible = false
	_death_label.text = "已死亡"
	# 黑墨归零可能发生在原生接触遍历内，所有关节修改推迟到安全边界。
	_start_death_visual.call_deferred(only_dissolve)


func _start_death_visual(only_dissolve: bool) -> void:
	if not _dead or not _death_bodies.is_empty():
		return
	_clear_revive_visual()
	_body = _player.get("body")
	var level := _level_root() as Node2D
	if _body == null or level == null:
		return
	# 只冻结玩家自身，不能沿抓握关节把敌人或动态道具一起冻结。
	var bodies: Array = [_body, _player.get_node("Arm").body, _player.get_node("Arm/Hand").body]
	var visual := _player.get_node("Visual") as Sprite2D
	var foot := DeathEffect.foot_position(visual)
	_death_effect = DeathEffect.spawn(level, DeathEffect.visible_sprites(_player),
		DeathEffect.Style.PLAYER, foot, _body.linear_velocity.x, only_dissolve)
	var hand := _player.get_node_or_null("Arm/Hand/HandControl")
	if hand != null:
		hand._release_grab()
		hand._remove_arm()
	for body in bodies:
		_death_bodies.append({"body": body, "layer": body.collision_layer,
			"mask": body.collision_mask, "frozen": body.frozen,
			"paused": body.tags.get("editor_physics_paused", false),
			"had_paused": body.tags.has("editor_physics_paused")})
		# 沿用世界暂停闸门，避免视野激活重新解冻已死亡的角色。
		body.tags["editor_physics_paused"] = true
		body.collision_layer = 0
		body.collision_mask = 0
		body.linear_velocity = Vector2.ZERO
		body.angular_velocity = 0.0
		body.control_force = Vector2.ZERO
		body.control_torque = 0.0
		level.world.freeze(body)
	for path in ["Visual", "BottledInk", "Arm", "PlayerInput"]:
		var node := _player.get_node(path)
		_death_nodes.append({"node": node, "mode": node.process_mode,
			"visible": node.visible if node is CanvasItem else false})
		node.process_mode = Node.PROCESS_MODE_DISABLED
		if node is CanvasItem:
			node.visible = false


func _restore_death_state() -> void:
	var level := _level_root()
	for state in _death_bodies:
		state.body.collision_layer = state.layer
		state.body.collision_mask = state.mask
		if state.had_paused:
			state.body.tags["editor_physics_paused"] = state.paused
		else:
			state.body.tags.erase("editor_physics_paused")
		if not state.frozen:
			level.world.unfreeze(state.body)
	_death_bodies.clear()
	for state in _death_nodes:
		if is_instance_valid(state.node):
			state.node.process_mode = state.mode
			if state.node is CanvasItem:
				state.node.visible = state.visible
	_death_nodes.clear()
	if is_instance_valid(_death_effect):
		_death_effect.queue_free()
	_death_effect = null


func _respawn() -> void:
	_clear_revive_visual()
	_restore_death_state()
	_dead = false
	_death_layer.visible = false
	_peak_y = INF

	var spawn := _find_respawn_target()
	if _body == null:
		return

	if spawn != null:
		_player.teleport_to(spawn.global_position, spawn.global_rotation)
	else:
		_player.teleport_to(_initial_position, _initial_rotation)
	_refill_black_ink()
	_start_revive_visual.call_deferred()


func _start_revive_visual() -> void:
	if _dead or not _player.is_inside_tree():
		return
	var visual := _player.get_node("Visual") as Sprite2D
	visual._physics_process(0.0)
	_player.get_node("BottledInk")._physics_process(0.0)
	var foot := DeathEffect.foot_position(visual)
	_revive_effect = DeathEffect.spawn(_level_root(), DeathEffect.visible_sprites(_player),
		DeathEffect.Style.REVIVE, foot)
	for path in ["Visual", "BottledInk", "Arm"]:
		var node := _player.get_node(path) as Node2D
		_revive_nodes.append({"node": node, "mode": node.process_mode, "visible": node.visible})
		node.process_mode = Node.PROCESS_MODE_DISABLED
		node.visible = false
	_revive_effect.finished.connect(_finish_revive_visual, CONNECT_ONE_SHOT)


func _finish_revive_visual() -> void:
	if _dead:
		return
	_clear_revive_visual()


func _clear_revive_visual() -> void:
	for state in _revive_nodes:
		if is_instance_valid(state.node):
			state.node.process_mode = state.mode
			state.node.visible = state.visible
	_revive_nodes.clear()
	if is_instance_valid(_revive_effect):
		_revive_effect.queue_free()
	_revive_effect = null


func _on_ink_depleted(material_id: int) -> void:
	if material_id == InkPalette.material_id_of(InkPalette.BLACK) and not _editor_active():
		_die()


func _refill_black_ink() -> void:
	if _health == null:
		return
	var black_id: int = InkPalette.material_id_of(InkPalette.BLACK)
	_health.add(black_id, _health.max_of(black_id) - _health.ink_of(black_id))


## 暂停菜单也可调用。不回血、不更改普通死亡的最近复活点规则。
func escape_stuck(skipped: Array = [], search = null) -> bool:
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
	if search == null:
		search = SafeSpawnSearch.new()
		search.setup(self, level.world, _body, hand)
	var landing: Dictionary = await search.find(targets, skipped)
	var previous_position := level.to_global(_body.position)
	var previous_rotation: float = _body.rotation + level.global_rotation
	# 提交后等待一帧，重新读取当前物品和碎屑位置，而非只使用首次快照。
	while not landing.is_empty():
		_player.teleport_to(level.to_global(landing.position), landing.rotation + level.global_rotation)
		await get_tree().process_frame
		if await search.verify(_body.position, _body.rotation):
			break
		skipped.append(landing.position)
		landing = await search.find(targets, skipped)
		if landing.is_empty():
			_player.teleport_to(previous_position, previous_rotation)
	last_search_stats = {"candidates": search.candidates_checked, "pairs": search.pairs_checked, "yielded_frames": search.frames_yielded}
	if landing.is_empty():
		recovery_error = "未找到可用的安全落点，游戏已保持暂停。"
		recovering = false
		# 找不到安全位置时不自动恢复游戏，不强行把玩家塞进物品。
		return false
	_clear_revive_visual()
	_restore_death_state()
	_dead = false
	_death_timer = 0.0
	_death_layer.visible = false
	_peak_y = INF
	# 复位抓握后同步工具栏，避免手已启用但 UI 仍显示画笔。
	for canvas in get_tree().get_nodes_in_group(&"play_canvas"):
		if _level_root().is_ancestor_of(canvas) and canvas.active:
			canvas.activate_hand_tool()
	_pending_safety_check = {"position": landing.position, "skipped": skipped, "search": search}
	recovering = false
	get_tree().paused = was_paused
	return true


## 恢复游玩后的首个真实物理步再复查一次；只运行一次，不成为常驻碰撞扫描。
func _verify_after_resume() -> void:
	var pending := _pending_safety_check
	_pending_safety_check = {}
	recovering = true
	get_tree().paused = true
	var search = pending.search
	var safe: bool = await search.verify(_body.position, _body.rotation)
	last_search_stats = {"candidates": search.candidates_checked, "pairs": search.pairs_checked, "yielded_frames": search.frames_yielded}
	recovering = false
	if safe:
		get_tree().paused = false
		return
	var menu := get_tree().get_first_node_in_group(&"esc_menu")
	if menu != null:
		menu.open_menu()
	var succeeded := false
	var skipped: Array = pending.skipped
	skipped.append(pending.position)
	if search.candidates_checked < SafeSpawnSearch.MAX_CANDIDATES and search.pairs_checked < SafeSpawnSearch.MAX_PAIRS:
		if menu != null:
			succeeded = await menu._on_escape_stuck_button_pressed(skipped, search)
		else:
			succeeded = await escape_stuck(skipped, search)
			if succeeded:
				get_tree().paused = false
	if not succeeded:
		recovery_error = "未找到可用的安全落点，游戏已保持暂停。"
		if menu != null:
			menu.show_recovery_status(recovery_error)


func _level_root() -> Node:
	return _player.get_parent()


func _editor_active() -> bool:
	var creative := _level_root().get_node_or_null("Creative")
	return creative != null and creative.get("active") == true


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
