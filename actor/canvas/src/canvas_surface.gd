#画布表面：负责黑色墨水的像素缓冲、鼠标绘制/擦除与渲染
#1 像素 = 1 世界单位，本版本只做可见像素，不进入物理世界

#region 依赖
@tool
extends Area2D
#endregion

#region 初始化
var black_texture: ImageTexture
@onready var black_sprite: Sprite2D = $BlackSprite
@onready var bounds: CollisionShape2D = $Bounds
func _ready() -> void:
	black_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_resize()
#endregion


#region 外观
#画布宽高，单位是世界单位，也决定底层贴图分辨率
@export var canvas_size := Vector2i(256, 256):
	set(value):
		canvas_size = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
		if is_node_ready():
			_resize()
#纸底颜色
@export var background_color := Color(0.86, 0.85, 0.80, 1.0):
	set(value):
		background_color = value
		queue_redraw()
#边框颜色
@export var border_color := Color(0.12, 0.12, 0.12, 1.0):
	set(value):
		border_color = value
		queue_redraw()
#边框线宽
@export var border_width := 2.0

#纸底和边框由表面画，黑色墨水由 BlackSprite 盖在上面
func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, Vector2(canvas_size))
	draw_rect(rect, background_color, true)
	draw_rect(rect, border_color, false, border_width)
#endregion


#region 输入
#原生引擎回调，处理鼠标左键右键
func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseButton:
		_on_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_on_mouse_motion()

var _painting := false #状态机
var _paint_color := Color.TRANSPARENT
var _last_point := Vector2.ZERO
@export var black_color := Color(0.04, 0.08, 0.05, 1.0)
#左键落笔时写入的黑色墨水颜色
func _on_mouse_button(button: InputEventMouseButton) -> void:
	if button.button_index != MOUSE_BUTTON_LEFT and button.button_index != MOUSE_BUTTON_RIGHT:
		return
	if button.pressed:
		var point := _mouse_point()
		if _inside(point):
			_painting = true
			_paint_color = black_color if button.button_index == MOUSE_BUTTON_LEFT else Color.TRANSPARENT
			_last_point = point
			_stroke(point, point, _paint_color)
	else:
		_painting = false


func _on_mouse_motion() -> void:
	if not _painting:
		return
	var point := _mouse_point()
	#移出画布时停笔，避免从外侧拖回时突然补一条线
	if not _inside(point):
		_painting = false
		return
	_stroke(_last_point, point, _paint_color)
	_last_point = point


##世界坐标转画布本地坐标，之后可直接当像素坐标用
func _mouse_point() -> Vector2:
	return to_local(get_global_mouse_position())

##检测是否在画布内
func _inside(point: Vector2) -> bool:
	return (
		point.x >= 0.0
		and point.y >= 0.0
		and point.x < float(canvas_size.x)
		and point.y < float(canvas_size.y)
	)
#endregion


#region 绘制
var black_image: Image
func _resize() -> void:
	# Area 只表达可编辑的画布范围，不参与游戏刚体碰撞。
	bounds.shape.size = Vector2(canvas_size)
	bounds.position = Vector2(canvas_size) * 0.5
	_reset()
	black_sprite.texture = black_texture
	queue_redraw()


#重建透明画布，透明像素在 BlackSprite 下露出纸底
func _reset() -> void:
	black_image = Image.create_empty(canvas_size.x, canvas_size.y, false, Image.FORMAT_RGBA8)
	black_image.fill(Color.TRANSPARENT)
	black_texture = ImageTexture.create_from_image(black_image)


#清空画布上的黑色墨水（固化后调用）
func clear() -> void:
	black_image.fill(Color.TRANSPARENT)
	black_texture.update(black_image)
	queue_redraw()


#两点之间插值补点，避免鼠标移动过快断线
func _stroke(from: Vector2, to: Vector2, color: Color) -> void:
	var steps := maxi(1, int(ceil(from.distance_to(to))))
	for i in range(steps + 1):
		_stamp(from.lerp(to, float(i) / float(steps)), color)
	black_texture.update(black_image)


#笔刷半径，单位与画布像素一致
@export var brush_radius := 3.0
#落一个圆形笔刷，只有落在半径内的像素才写
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
				black_image.set_pixelv(Vector2i(x, y), color)


#该像素是否为黑色墨水，供固化时采样
func is_solid(x: int, y: int) -> bool:
	return black_image.get_pixel(x, y).a > 0.5
#endregion


#region 画布复现文件
## 保存 CPU 像素缓冲，包含颜色、透明度和尺寸；不读取 GPU，不触发固化。
func save_ink(path: String) -> Error:
	var error: Error = ResourceSaver.save(black_image, path)
	if error == OK:
		print("CANVAS saved: ", ProjectSettings.globalize_path(path))
	else:
		push_error("Canvas save failed: %s (%d)" % [path, error])
	return error


func load_ink(path: String) -> Error:
	if not ResourceLoader.exists(path):
		push_error("Canvas file missing: " + path)
		return ERR_FILE_NOT_FOUND
	var image: Image = ResourceLoader.load(path, "Image", ResourceLoader.CACHE_MODE_IGNORE) as Image
	if image == null or image.is_empty():
		push_error("Canvas file is not an Image: " + path)
		return ERR_INVALID_DATA
	_painting = false
	get_parent().canvas_size = image.get_size()
	black_image = image
	black_image.convert(Image.FORMAT_RGBA8)
	black_texture.update(black_image)
	print("CANVAS loaded: ", ProjectSettings.globalize_path(path))
	return OK
#endregion
