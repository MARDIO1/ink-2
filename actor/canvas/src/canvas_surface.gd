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

var _painting := false #状态机
var _paint_color := Color.TRANSPARENT
var _last_point := Vector2.ZERO
## 左键绘制的墨水颜色；固化材料由 CanvasSolid 决定。
@export var black_color := Color(0.04, 0.08, 0.05, 1.0)
## 中键放置的单像素钉子颜色；固化后使用 grey1 材料并固定所在连通块。
@export var nail_color := Color(0.12, 0.12, 0.12, 1.0)
## 中键放置的钉子场景；大贴图，只有中心像素起固定作用。
const NAIL_SCENE := preload("res://actor/nail/nail.tscn")
#左键落笔时写入的黑色墨水颜色
func _on_mouse_button(button: InputEventMouseButton) -> void:
	if button.button_index == MOUSE_BUTTON_MIDDLE:
		_painting = false
		if button.pressed:
			_spawn_nail()
		return
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


func _continue_stroke() -> void:
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


## 圆形笔刷半径，单位 px；绘制和擦除使用相同范围。
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


func _place_nail(point: Vector2) -> void:
	if not _inside(point):
		return
	black_image.set_pixelv(Vector2i(point.floor()), nail_color)
	black_texture.update(black_image)


# 中键在鼠标世界位置放一枚钉子（大贴图）。钉子自包含：直接把中心点所在的
# 已有刚体钉成静态，不再往画布写钉像素。_place_nail 仍保留给图纸预埋钉点用。
func _spawn_nail() -> void:
	var nail := NAIL_SCENE.instantiate()
	# 挂到世界上层（与 Canvas 同级），保证 global_position 即世界坐标。
	var host: Node = get_parent().get_parent()
	if host == null:
		host = get_tree().current_scene
	host.add_child(nail)
	nail.global_position = get_global_mouse_position()


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
	return 4 if nail_delta.length_squared() < ink_delta.length_squared() else 1
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
	print("CANVAS loaded: ", ProjectSettings.globalize_path(path))
	return OK
#endregion
