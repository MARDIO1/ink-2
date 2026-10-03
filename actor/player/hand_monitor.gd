extends Node

@export var log_interval := 0.5
@export var radius_margin := 0.5
@export var player_angular_limit := 8.0
@export var max_logged_speed := 2000.0

var _elapsed := 0.0
var hand = null
var control = null


func _ready() -> void:
	hand = get_parent()
	control = get_node_or_null("../HandControl")


func _physics_process(delta: float) -> void:
	if hand == null or control == null or control.get("player_body") == null:
		return

	_elapsed += delta
	if _elapsed < log_interval:
		return
	_elapsed = 0.0

	var player_body = control.get("player_body")
	var hand_body = hand.get("body")
	var hand_position: Vector2 = hand_body.position if hand_body != null else hand.global_position
	var radius: float = hand_position.distance_to(player_body.position)
	var target_position: Vector2 = control.get("debug_target_position")

	print(
		"[HandMonitor] hand=", snappedf(hand_position.x, 0.1), ",", snappedf(hand_position.y, 0.1),
		" r=", snappedf(radius, 0.1),
		" target=", snappedf(target_position.x, 0.1), ",", snappedf(target_position.y, 0.1),
		" pv=", snappedf(player_body.linear_velocity.length(), 0.1),
		" pw=", snappedf(player_body.angular_velocity, 0.01)
	)

	if radius > control.get("max_radius") + radius_margin:
		print("[Anomaly] radius_outside_limit radius=", radius, " max=", control.get("max_radius"))
	if absf(player_body.angular_velocity) > player_angular_limit:
		print("[Anomaly] player_angular_high value=", player_body.angular_velocity)
	if player_body.linear_velocity.length() > max_logged_speed:
		print("[Anomaly] speed_high player=", player_body.linear_velocity.length())
