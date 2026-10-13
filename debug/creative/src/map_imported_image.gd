extends Sprite2D
## 图片素材直接作为关卡子资源保存；不依赖导入时的磁盘路径。

const GROUP := &"map_imported_image"
const MIN_SCALE := 0.05
const MAX_SCALE := 12.0

@export var source_data := PackedByteArray()
@export_enum("png", "gif") var source_format := "png"
@export var original_filename := ""
var frames: Array[Texture2D] = []
var frame_delays := PackedFloat32Array()

var editor_selected := false:
	set(value):
		editor_selected = value
		queue_redraw()

var _frame := 0
var _elapsed := 0.0


func _enter_tree() -> void:
	add_to_group(GROUP, true)
	centered = false
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func _ready() -> void:
	if frames.is_empty():
		_load_source()
	_apply_frame()
	set_process(frames.size() > 1)


func _load_source() -> void:
	if source_data.is_empty():
		return
	var images: Array[Image] = []
	if source_format == "gif":
		var decoded: Dictionary = preload("res://debug/creative/src/gif_decoder.gd").decode(source_data)
		if decoded.has("error"):
			push_warning("地图 GIF 解码失败：" + str(decoded.error))
			return
		images = decoded.frames
		frame_delays = decoded.delays
	else:
		var image := Image.new()
		if image.load_png_from_buffer(source_data) != OK:
			push_warning("地图 PNG 解码失败：" + original_filename)
			return
		images.append(image)
		frame_delays = PackedFloat32Array([0.1])
	for image in images:
		frames.append(ImageTexture.create_from_image(image))


func _process(delta: float) -> void:
	if frames.size() < 2:
		return
	_elapsed += delta
	var changes := 0
	while _elapsed >= _delay(_frame) and changes < frames.size():
		_elapsed -= _delay(_frame)
		_frame = (_frame + 1) % frames.size()
		_apply_frame()
		changes += 1


func _apply_frame() -> void:
	if frames.is_empty():
		return
	_frame = mini(_frame, frames.size() - 1)
	texture = frames[_frame]
	queue_redraw()


func _delay(index: int) -> float:
	return maxf(0.02, frame_delays[index]) if index < frame_delays.size() else 0.1


func pick_rect() -> Rect2:
	if texture == null:
		return Rect2()
	return (global_transform * get_rect()).grow(8.0)


func contains_world_point(point: Vector2, margin: float) -> bool:
	if texture == null:
		return false
	var transform := global_transform
	var padding := Vector2(margin / transform.x.length(), margin / transform.y.length())
	return get_rect().grow_individual(padding.x, padding.y, padding.x, padding.y).has_point(to_local(point))


func resize_handle_hit(world_position: Vector2) -> bool:
	if texture == null:
		return false
	var corner := to_global(Vector2(texture.get_size()))
	return world_position.distance_to(corner) <= 16.0


func _draw() -> void:
	if not editor_selected or texture == null or not is_inside_tree():
		return
	var size := Vector2(texture.get_size())
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.1, 0.7, 1.0, 0.95), 2.0 / maxf(scale.x, 0.05))
	draw_circle(size, 7.0 / maxf(scale.x, 0.05), Color(0.1, 0.7, 1.0))
