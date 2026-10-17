extends Control
## 与画布相同的像素滤镜，缩略图另加淡网格，让白墨也能辨认。
var image: Image
var _texture: ImageTexture

func set_image(value: Image, shared_texture: ImageTexture = null) -> void:
	if value == image:
		return
	image = value
	_texture = null
	if value != null:
		_texture = shared_texture if shared_texture != null else ImageTexture.create_from_image(value)
	queue_redraw()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	resized.connect(queue_redraw)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.86, 0.85, 0.80))
	for x in range(0, int(size.x), 16):
		draw_line(Vector2(x, 0), Vector2(x, size.y), Color(0.15, 0.14, 0.12, 0.08))
	for y in range(0, int(size.y), 16):
		draw_line(Vector2(0, y), Vector2(size.x, y), Color(0.15, 0.14, 0.12, 0.08))
	if _texture != null:
		var extent := Vector2(_texture.get_size())
		var ratio := minf((size.x - 12) / extent.x, (size.y - 12) / extent.y)
		extent *= maxf(0.01, ratio)
		draw_texture_rect(_texture, Rect2((size - extent) * 0.5, extent), false)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.15, 0.14, 0.12), false, 1.0)
