@tool
extends Node2D
class_name InkFill2D

const TOP_Y := -105.0
const BOTTOM_Y := 132.0
static var INNER_SHAPE := PackedVector2Array([
	Vector2(-58, -105), Vector2(58, -105),
	Vector2(78, -94), Vector2(105, -76),
	Vector2(116, -48), Vector2(116, 112),
	Vector2(106, 126), Vector2(88, 132),
	Vector2(-88, 132), Vector2(-106, 126),
	Vector2(-116, 112), Vector2(-116, -48),
	Vector2(-105, -76), Vector2(-78, -94),
])

@export_range(0.0, 1.0, 0.01) var amount := 0.72:
	set(value):
		amount = clampf(value, 0.0, 1.0)
		queue_redraw()
@export var ink_color := Color("15171c"):
	set(value):
		ink_color = value
		queue_redraw()


func _ready() -> void:
	queue_redraw()


func _draw() -> void:
	if amount <= 0.001:
		return
	var top_y := lerpf(BOTTOM_Y, TOP_Y, amount)
	var clipped := _clip_below(INNER_SHAPE, top_y)
	if clipped.size() < 3:
		return
	draw_colored_polygon(clipped, ink_color)
	var x_range := _x_range_at_y(top_y)
	draw_line(Vector2(x_range.x, top_y), Vector2(x_range.y, top_y), ink_color.lightened(0.28), 4.0, true)


func _clip_below(source: PackedVector2Array, min_y: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	if source.is_empty():
		return result
	for index in range(source.size()):
		var current := source[index]
		var next := source[(index + 1) % source.size()]
		var current_inside := current.y >= min_y
		var next_inside := next.y >= min_y
		if current_inside:
			result.append(current)
		if current_inside != next_inside:
			var denominator := next.y - current.y
			if absf(denominator) > 0.0001:
				result.append(current.lerp(next, (min_y - current.y) / denominator))
	return result


func _x_range_at_y(y: float) -> Vector2:
	var intersections: Array[float] = []
	for index in range(INNER_SHAPE.size()):
		var current := INNER_SHAPE[index]
		var next := INNER_SHAPE[(index + 1) % INNER_SHAPE.size()]
		if is_equal_approx(current.y, next.y):
			continue
		var low := minf(current.y, next.y)
		var high := maxf(current.y, next.y)
		if y < low or y > high:
			continue
		var t := (y - current.y) / (next.y - current.y)
		intersections.append(lerpf(current.x, next.x, t))
	if intersections.size() < 2:
		return Vector2(-6.0, 6.0)
	intersections.sort()
	return Vector2(intersections.front(), intersections.back())
