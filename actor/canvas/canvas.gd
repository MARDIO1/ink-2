extends Node2D
## 世界空间画布：左键拖动绘制，右键拖动擦除。
## 1 像素 = 1 世界单位；本版本只产出可见像素，不进入物理世界。

@export var canvas_size := Vector2i(256, 256)
@export var brush_radius := 3.0
@export var ink_color := Color(0.04, 0.08, 0.05, 1.0)
@export var background_color := Color(0.86, 0.85, 0.80, 1.0)
@export var border_color := Color(0.12, 0.12, 0.12, 1.0)
@export var border_width := 2.0

var ink_image: Image
var ink_texture: ImageTexture
var _painting := false
var _paint_color := Color.TRANSPARENT
var _last_point := Vector2.ZERO

@onready var ink_sprite: Sprite2D = $InkSprite


func _ready() -> void:
	ink_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_reset()
	ink_sprite.texture = ink_texture
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, Vector2(canvas_size))
	draw_rect(rect, background_color, true)
	draw_rect(rect, border_color, false, border_width)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_on_mouse_motion()


func _on_mouse_button(button: InputEventMouseButton) -> void:
	if button.button_index != MOUSE_BUTTON_LEFT and button.button_index != MOUSE_BUTTON_RIGHT:
		return
	if button.pressed:
		var point := _mouse_point()
		if _inside(point):
			_painting = true
			_paint_color = ink_color if button.button_index == MOUSE_BUTTON_LEFT else Color.TRANSPARENT
			_last_point = point
			_stroke(point, point, _paint_color)
	else:
		_painting = false


func _on_mouse_motion() -> void:
	if not _painting:
		return
	var point := _mouse_point()
	if not _inside(point):
		_painting = false
		return
	_stroke(_last_point, point, _paint_color)
	_last_point = point


func _mouse_point() -> Vector2:
	return to_local(get_global_mouse_position())


func _inside(point: Vector2) -> bool:
	return (
		point.x >= 0.0
		and point.y >= 0.0
		and point.x < float(canvas_size.x)
		and point.y < float(canvas_size.y)
	)


func _reset() -> void:
	ink_image = Image.create_empty(canvas_size.x, canvas_size.y, false, Image.FORMAT_RGBA8)
	ink_image.fill(Color.TRANSPARENT)
	ink_texture = ImageTexture.create_from_image(ink_image)


func _stroke(from: Vector2, to: Vector2, color: Color) -> void:
	var steps := maxi(1, int(ceil(from.distance_to(to))))
	for i in range(steps + 1):
		_stamp(from.lerp(to, float(i) / float(steps)), color)
	ink_texture.update(ink_image)


func _stamp(center: Vector2, color: Color) -> void:
	var r := ceili(brush_radius)
	var r2 := brush_radius * brush_radius
	var cx := roundi(center.x)
	var cy := roundi(center.y)
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			if x < 0 or y < 0 or x >= canvas_size.x or y >= canvas_size.y:
				continue
			var dx := float(x) + 0.5 - center.x
			var dy := float(y) + 0.5 - center.y
			if dx * dx + dy * dy <= r2:
				ink_image.set_pixelv(Vector2i(x, y), color)
