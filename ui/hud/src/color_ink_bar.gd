extends Control
## 黑墨保留在瓶身；横条四段分别显示灰、红、黄、白墨的独立余额。

const InkPalette := preload("res://ink/src/ink_palette.gd")
const MATERIALS := [InkPalette.GREY, InkPalette.RED, InkPalette.YELLOW, InkPalette.WHITE]
const NAMES := ["灰", "红", "黄", "白"]
const EMPTY_COLOR := Color(0.76, 0.75, 0.70, 0.62)
const BORDER_COLOR := Color(0.05, 0.045, 0.035, 0.55)

var ratios := PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
var remaining := PackedInt32Array([20000, 20000, 20000, 20000])
var _labels: Array[Label] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_layout_labels)
	for index in MATERIALS.size():
		var label := Label.new()
		label.name = "Ink%d" % index
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_size_override("font_size", 15)
		label.add_theme_color_override("font_color", Color(0.035, 0.03, 0.025))
		label.add_theme_color_override("font_outline_color", Color(1.0, 0.99, 0.92, 0.65))
		label.add_theme_constant_override("outline_size", 2)
		add_child(label)
		_labels.append(label)
	_layout_labels()
	_update_labels()


func set_health(health: Node) -> void:
	for index in MATERIALS.size():
		var material_id: int = MATERIALS[index].id
		if health == null:
			ratios[index] = 1.0
			remaining[index] = 20000
		else:
			ratios[index] = clampf(health.ratio_of(material_id), 0.0, 1.0)
			remaining[index] = maxi(0, roundi(health.ink_of(material_id)))
	_update_labels()
	queue_redraw()


func _layout_labels() -> void:
	var width: float = size.x / float(MATERIALS.size())
	for index in _labels.size():
		_labels[index].position = Vector2(index * width, 0.0)
		_labels[index].size = Vector2(width, size.y)
	queue_redraw()


func _update_labels() -> void:
	for index in _labels.size():
		_labels[index].text = "%s %d" % [NAMES[index], remaining[index]]


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	draw_rect(Rect2(Vector2.ZERO, size), EMPTY_COLOR)
	var width: float = size.x / float(MATERIALS.size())
	for index in MATERIALS.size():
		var amount_width: float = width * ratios[index]
		if amount_width <= 0.0:
			continue
		var color: Color = MATERIALS[index].color
		var start_color := color
		var end_color := color
		# 两侧都有颜色并且接缝连续时，将相邻颜色在接缝处混合。
		if index > 0 and ratios[index - 1] >= 0.999:
			start_color = MATERIALS[index - 1].color.lerp(color, 0.5)
		if index + 1 < MATERIALS.size() and ratios[index] >= 0.999 \
		and ratios[index + 1] > 0.0:
			end_color = color.lerp(MATERIALS[index + 1].color, 0.5)
		var x0: float = index * width
		var x1: float = x0 + amount_width
		draw_polygon(PackedVector2Array([
			Vector2(x0, 0.0), Vector2(x1, 0.0),
			Vector2(x1, size.y), Vector2(x0, size.y),
		]), PackedColorArray([start_color, end_color, end_color, start_color]))
	for index in range(1, MATERIALS.size()):
		var x: float = index * width
		draw_line(Vector2(x, 0.0), Vector2(x, size.y), BORDER_COLOR, 1.0)
