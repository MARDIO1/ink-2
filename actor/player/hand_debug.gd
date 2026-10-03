extends Node2D

@export var trail_max_points := 120
@export var force_scale := 0.0005

var hand = null
var target_trail: Line2D
var hand_trail: Line2D
var error_line: Line2D
var force_line: Line2D


func _ready() -> void:
	hand = get_parent()
	top_level = true
	z_index = 100

	target_trail = _create_line(Color(0.2, 1.0, 0.25, 0.85), 2.0)
	hand_trail = _create_line(Color(1.0, 0.85, 0.1, 0.85), 2.0)
	error_line = _create_line(Color(1.0, 0.12, 0.1, 0.9), 1.5)
	force_line = _create_line(Color(0.15, 0.55, 1.0, 0.9), 1.5)


func _process(_delta: float) -> void:
	if hand == null or hand.player_body == null:
		return

	var hand_position: Vector2 = hand.body.position if hand.body != null else hand.global_position
	_append_point(target_trail, hand.debug_target_position)
	_append_point(hand_trail, hand_position)
	error_line.points = PackedVector2Array([hand_position, hand.debug_target_position])
	force_line.points = PackedVector2Array([hand_position, hand_position + hand.debug_force * force_scale])
	queue_redraw()


func _draw() -> void:
	if hand == null or hand.player_body == null:
		return

	var pivot: Vector2 = hand.player_body.position
	draw_arc(pivot, hand.max_radius, 0.0, TAU, 96, Color(0.85, 0.25, 0.6, 0.7), 1.0, true)
	draw_arc(pivot, hand.min_radius, 0.0, TAU, 64, Color(0.4, 0.7, 1.0, 0.5), 1.0, true)


func _create_line(color: Color, width: float) -> Line2D:
	var line := Line2D.new()
	line.width = width
	line.default_color = color
	line.joint_mode = Line2D.LINE_JOINT_ROUND
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(line)
	return line


func _append_point(line: Line2D, point: Vector2) -> void:
	line.add_point(point)
	while line.get_point_count() > trail_max_points:
		line.remove_point(0)
