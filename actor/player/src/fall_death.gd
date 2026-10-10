extends Node
## 掉落死亡：玩家连续下落超过阈值时显示"已死亡"，倒计时后回到最近出生点。
## 挂在 Player 节点下作为子节点；通过 PlayerInput.support 判断是否着地。

#region 配置
## 连续下落多少像素触发死亡。
@export var fall_death_threshold := 1000.0
## 死亡后多少秒重生。
@export var respawn_delay := 3.0
## 出生点 Marker2D 的名字前缀（支持 PlayerSpawn / PlayerSpawn2 等多个）。
const SPAWN_PREFIX := "PlayerSpawn"
#endregion


#region 状态
var _player: Node2D
var _player_input: Node
var _body = null # PBody，延迟到 _body 烘焙出来后取
## 本次下落轨迹的最高点（y 最小）；着地时重置为当前 y。
var _peak_y := INF
var _dead := false
var _death_timer := 0.0
var _death_layer: CanvasLayer
var _death_label: Label
#endregion


#region 生命周期
func _ready() -> void:
	_player = get_parent()
	_player_input = _player.get_node_or_null("PlayerInput")
	_build_death_ui()


func _physics_process(_delta: float) -> void:
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

	var spawn := _find_nearest_spawn()
	if spawn == null or _body == null:
		return

	var target := spawn.global_position
	# 与 creative.gd _reset_player_to_spawn 相同的传送方式。
	_player.global_position = target
	_player.global_rotation = spawn.global_rotation
	_body.position = target
	_body.rotation = spawn.global_rotation
	_body.linear_velocity = Vector2.ZERO
	_body.angular_velocity = 0.0
	_body.control_force = Vector2.ZERO
	_body.control_torque = 0.0
	_body.refresh_com()
	_body.update_aabb()

	var hand := _player.get_node_or_null("Arm/Hand/HandControl")
	if hand != null and hand.has_method("reset_after_player_teleport"):
		hand.reset_after_player_teleport()
#endregion


#region 出生点查找
## 找离玩家最近的出生点 Marker2D（名字以 PlayerSpawn 开头）。
func _find_nearest_spawn() -> Marker2D:
	var root := _player
	while root.get_parent() != null and root.get_parent().name != "Level":
		root = root.get_parent()
	var best: Marker2D = null
	var best_dist := INF
	for s in _collect_spawns(root):
		var d: float = s.global_position.distance_to(_player.global_position)
		if d < best_dist:
			best_dist = d
			best = s
	return best


## 递归收集 root 下所有出生点 Marker2D。
func _collect_spawns(root: Node) -> Array:
	var result: Array = []
	for child in root.get_children():
		if child is Marker2D and String(child.name).begins_with(SPAWN_PREFIX):
			result.append(child)
		result.append_array(_collect_spawns(child))
	return result
#endregion
