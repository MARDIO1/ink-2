extends Control
## 常驻双描边和对勾；动画只绘制叠加层，不挤压按钮或改变实际颜色。
var selected := false
var pulse := 0.0:
	set(value):
		pulse = value
		queue_redraw()
var contrast := Color.WHITE
var _tween: Tween

static func install(button: Button, color: Color) -> Control:
	var indicator := preload("res://ui/theme/ink_selection_indicator.gd").new()
	indicator.name = "InkSelectionIndicator"
	indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	indicator.contrast = Color.WHITE if color.get_luminance() < 0.5 else Color.BLACK
	button.add_child(indicator)
	indicator.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	indicator.resized.connect(indicator.queue_redraw)
	return indicator

func set_selected(on: bool, animate := true) -> void:
	var changed := selected != on
	selected = on
	if _tween != null:
		_tween.kill()
	pulse = 0.0
	if on and changed and animate and is_inside_tree():
		pulse = 1.0
		_tween = create_tween()
		_tween.tween_property(self, "pulse", 0.0, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	queue_redraw()

func _draw() -> void:
	if not selected:
		return
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.5 + 2.0 + pulse * 3.0
	draw_arc(center, radius, 0.0, TAU, 48, Color.BLACK, 4.0, true)
	draw_arc(center, radius, 0.0, TAU, 48, Color.WHITE, 1.5, true)
	var check := PackedVector2Array([center + Vector2(-0.16, 0.0) * size,
		center + Vector2(-0.03, 0.14) * size, center + Vector2(0.2, -0.15) * size])
	draw_polyline(check, contrast, maxf(2.0, minf(size.x, size.y) * 0.065), true)
