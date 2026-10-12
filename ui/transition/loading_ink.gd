extends Control
## 纯绘制的墨水瓶加载动画，无物理体或额外图片依赖。

var elapsed := 0.0
var dark := false

func _process(delta: float) -> void:
	elapsed += delta
	queue_redraw()

func _draw() -> void:
	var ink := Color(0.12, 0.13, 0.17) if not dark else Color(0.94, 0.92, 0.85)
	var center := size * 0.5 + Vector2(0, sin(elapsed * 3.0) * 3.0)
	draw_set_transform(center, sin(elapsed * 2.0) * 0.07)
	draw_style_box(_bottle_style(ink), Rect2(-22, -16, 44, 43))
	draw_rect(Rect2(-14, -27, 28, 10), ink, false, 3)
	for x in [-7, 0, 7]:
		draw_line(Vector2(x, -25), Vector2(x, -19), ink, 2)
	var height := 12.0 + sin(elapsed * 2.4) * 4.0
	draw_rect(Rect2(-17, 22 - height, 34, height), ink)
	draw_circle(Vector2(-7, -2), 2, ink)
	draw_circle(Vector2(7, -2), 2, ink)
	draw_arc(Vector2(0, 2), 5, 0, PI, 12, ink, 2)
	for i in 3:
		var alpha := 0.25 + 0.75 * (0.5 + 0.5 * sin(elapsed * 4.0 - i * 1.2))
		draw_circle(Vector2(-10 + i * 10, 43), 2.5, Color(ink, alpha))

func _bottle_style(ink: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color.TRANSPARENT
	box.set_border_width_all(3)
	box.border_color = ink
	box.set_corner_radius_all(9)
	return box
