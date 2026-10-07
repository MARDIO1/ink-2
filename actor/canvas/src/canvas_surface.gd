#画布表面：负责黑色墨水的像素缓冲、鼠标绘制/擦除与渲染
#1 像素 = 1 世界单位，本版本只做可见像素，不进入物理世界

#region 依赖
@tool
extends Area2D
#endregion

#region 初始化
var black_texture: ImageTexture
@onready var black_sprite: Sprite2D = $BlackSprite
@onready var nail_layer: Node2D = $NailLayer
@onready var bounds: CollisionShape2D = $Bounds
func _ready() -> void:
	black_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_resize()
#endregion


#region 外观
## 表面宽高，单位 px；由父 Canvas 的 canvas_size 同步，直接修改父节点即可。
@export var canvas_size := Vector2i(256, 256):
	set(value):
		canvas_size = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
		if is_node_ready():
			_resize()
## 纸底颜色；只影响显示，不属于可固化墨水。
@export var background_color := Color(0.86, 0.85, 0.80, 1.0):
	set(value):
		background_color = value
		queue_redraw()
## 画布边框颜色；只影响显示。
@export var border_color := Color(0.12, 0.12, 0.12, 1.0):
	set(value):
		border_color = value
		queue_redraw()
## 画布边框线宽，单位 px。
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


#摄像机移动不会产生 MouseMotion，因此按住画笔时每帧按世界坐标补线。
func _process(_delta: float) -> void:
	if not Engine.is_editor_hint() and _painting:
		_continue_stroke()

## 工具：普通手不参与画布绘制，画笔写黑墨，橡皮擦擦除，钉子写静态锚点。
enum Tool { HAND, BRUSH, ERASER, NAIL }

var _painting := false #状态机
var _paint_color := Color.TRANSPARENT
var _last_point := Vector2.ZERO
## 当前工具；切换时中断正在进行的笔画。
@export var tool: Tool = Tool.HAND:
	set(value):
		tool = value
		_painting = false
## 左键绘制的墨水颜色；固化材料由 CanvasSolid 决定。
@export var black_color := Color(0.04, 0.08, 0.05, 1.0)
## 钉子像素颜色；固化后使用 grey1 材料并固定所在连通块（材质 4）。
@export var nail_color := Color(0.12, 0.12, 0.12, 1.0)
## 钉子对应的材料 id；与 CanvasSolid / CollisionDamage 里的 grey1 一致。
const NAIL_MATERIAL_ID := 4


func _on_mouse_button(button: InputEventMouseButton) -> void:
	if button.button_index == MOUSE_BUTTON_MIDDLE:
		_painting = false
		if button.pressed:
			_place_nail(_mouse_point())
		return
	if button.button_index != MOUSE_BUTTON_LEFT and button.button_index != MOUSE_BUTTON_RIGHT:
		return
	if not button.pressed:
		_painting = false
		return
	var color = _stroke_color(button.button_index)
	if color == null:
		return
	var point := _mouse_point()
	if not _inside(point):
		return
	_painting = true
	_paint_color = color
	_last_point = point
	_stroke(point, point, color)


## 当前工具下该鼠标键的落笔颜色；null 表示不绘制。
func _stroke_color(button_index: int):
	if tool == Tool.BRUSH:
		if button_index == MOUSE_BUTTON_LEFT:
			return black_color
		if button_index == MOUSE_BUTTON_RIGHT:
			return Color.TRANSPARENT
	elif tool == Tool.NAIL:
		if button_index == MOUSE_BUTTON_LEFT:
			return nail_color
		if button_index == MOUSE_BUTTON_RIGHT:
			return Color.TRANSPARENT
	elif tool == Tool.ERASER and button_index == MOUSE_BUTTON_LEFT:
		return Color.TRANSPARENT
	return null


func _continue_stroke() -> void:
	if tool == Tool.HAND:
		_painting = false
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
	nail_layer.clear()


#清空画布上的黑色墨水（固化后调用）
func clear() -> void:
	black_image.fill(Color.TRANSPARENT)
	black_texture.update(black_image)
	nail_layer.clear()
	queue_redraw()


## 直接写入一个画布像素；越界返回 false。批量写入后调 refresh()。
func write_pixel(pixel: Vector2i, color: Color) -> bool:
	if pixel.x < 0 or pixel.y < 0 or pixel.x >= canvas_size.x or pixel.y >= canvas_size.y:
		return false
	black_image.set_pixelv(pixel, color)
	return true


## 把 CPU 像素缓冲刷到贴图；批量写入后调用一次。
func refresh() -> void:
	black_texture.update(black_image)


#两点之间插值补点，避免鼠标移动过快断线
func _stroke(from: Vector2, to: Vector2, color: Color) -> void:
	var steps := maxi(1, int(ceil(from.distance_to(to))))
	for i in range(steps + 1):
		_stamp(from.lerp(to, float(i) / float(steps)), color)
	black_texture.update(black_image)


## 圆形笔刷半径，单位 px；绘制和擦除使用相同范围。
@export var brush_radius := 3.0
#落一个圆形笔刷；钉子不铺笔刷，只落单像素。
func _stamp(center: Vector2, color: Color) -> void:
	if color == nail_color:
		_write_pixel(Vector2i(center.floor()), color)
		return
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
				_write_pixel(Vector2i(x, y), color)


#写一个像素并同步钉子外观层：写钉色就记上，写别的就摘掉。
func _write_pixel(pixel: Vector2i, color: Color) -> void:
	if pixel.x < 0 or pixel.y < 0 or pixel.x >= canvas_size.x or pixel.y >= canvas_size.y:
		return
	black_image.set_pixelv(pixel, color)
	if color == nail_color:
		nail_layer.add(pixel)
	else:
		nail_layer.remove(pixel)


## 在画布上放一枚钉子：写一个材质 4 的像素，外观由 NailLayer 画。
func _place_nail(point: Vector2) -> void:
	if not _inside(point):
		return
	var pixel := Vector2i(point.floor())
	_write_pixel(pixel, nail_color)
	black_texture.update(black_image)


#该像素是否为黑色墨水，供固化时采样
func is_solid(x: int, y: int) -> bool:
	return black_image.get_pixel(x, y).a > 0.5


## 透明=空，普通墨水=1，灰色钉子=4。
func material_at(x: int, y: int) -> int:
	var color: Color = black_image.get_pixel(x, y)
	if color.a <= 0.5:
		return 0
	var nail_delta: Vector3 = Vector3(color.r, color.g, color.b) - Vector3(nail_color.r, nail_color.g, nail_color.b)
	var ink_delta: Vector3 = Vector3(color.r, color.g, color.b) - Vector3(black_color.r, black_color.g, black_color.b)
	return NAIL_MATERIAL_ID if nail_delta.length_squared() < ink_delta.length_squared() else 1
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


## 保存供 BakedMap 同时用于编辑器预览和物理烘焙的透明 PNG。
func save_png(path: String) -> Error:
	var error: Error = black_image.save_png(ProjectSettings.globalize_path(path))
	if error == OK:
		print("MAP saved: ", ProjectSettings.globalize_path(path))
	else:
		push_error("Map save failed: %s (%d)" % [path, error])
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
	_rebuild_nails()
	print("CANVAS loaded: ", ProjectSettings.globalize_path(path))
	return OK


#按像素颜色重建钉子外观层；只在读盘时走一次。
func _rebuild_nails() -> void:
	nail_layer.clear()
	for y in range(canvas_size.y):
		for x in range(canvas_size.x):
			if material_at(x, y) == NAIL_MATERIAL_ID:
				nail_layer.add(Vector2i(x, y))
#endregion
