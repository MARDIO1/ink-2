#画布表面：负责黑色墨水的像素缓冲、鼠标绘制/擦除与渲染
#1 像素 = 1 世界单位，本版本只做可见像素，不进入物理世界

#region 依赖
@tool
extends Area2D

const InkPalette := preload("res://Ink/src/ink_palette.gd")
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
	if Engine.is_editor_hint():
		return
	if _shaping:
		_update_shape()
	elif _painting:
		_continue_stroke()

## 工具：普通手不落笔；画笔/橡皮擦/钉子按笔刷落笔；矩形与圆形画**外框**；墨水桶灌满封闭空区。
enum Tool { HAND, BRUSH, ERASER, NAIL, RECT, CIRCLE, BUCKET }

var _painting := false #状态机
var _paint_color := Color.TRANSPARENT
var _last_point := Vector2.ZERO
## 形状拖拽中：起点、预览期间被改过的像素（原色）、本次新增的墨水量。
var _shaping := false
var _shape_origin := Vector2.ZERO
var _shape_saved := {}
var _shape_delta := 0
## 当前工具；切换时中断正在进行的笔画或形状。
@export var tool: Tool = Tool.HAND:
	set(value):
		if _shaping:
			_revert_shape()
		tool = value
		_painting = false
		_shaping = false
## 当前选中的墨水（`Ink/src/ink_palette.gd` 的 INKS 下标）；右侧面板改它。
@export var selected_ink: int = 0


## 当前墨水的画布颜色。
func ink_color() -> Color:
	return InkPalette.color_at(selected_ink)


## 当前墨水的材质 id。
func ink_material_id() -> int:
	return InkPalette.material_id_of(InkPalette.ink_at(selected_ink))


## 钉子像素颜色。钉子不是墨水，只有这一种。
func nail_color() -> Color:
	return InkPalette.nail_color()


func _is_nail(color: Color) -> bool:
	return color == nail_color()


func _on_mouse_button(button: InputEventMouseButton) -> void:
	if button.button_index == MOUSE_BUTTON_MIDDLE:
		_painting = false
		if button.pressed:
			_place_nail(_mouse_point())
		return
	if button.button_index != MOUSE_BUTTON_LEFT:
		return
	if not button.pressed:
		if _shaping:
			_end_shape()
		_painting = false
		return
	var point := _mouse_point()
	if not _inside(point):
		return
	#墨水桶是点击工具：按下即灌满所在空区。
	if tool == Tool.BUCKET:
		_bucket_fill(point)
		return
	#矩形/圆形是拖拽工具：按下定起点，拖拽出形状，松手定型。
	if tool == Tool.RECT or tool == Tool.CIRCLE:
		_shaping = true
		_shape_origin = point
		_update_shape()
		return
	var color = _stroke_color()
	if color == null:
		return
	_painting = true
	_paint_color = color
	_last_point = point
	_stroke(point, point, color)


## 当前工具左键落笔的颜色；null 表示这个工具不落笔。
func _stroke_color():
	match tool:
		Tool.BRUSH:
			return ink_color()
		Tool.ERASER:
			return Color.TRANSPARENT
		Tool.NAIL:
			return nail_color()
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
	_refund_all_ink()                  # 画布被重建：把还挂在画布上的墨水还给瓶子
	black_image = Image.create_empty(canvas_size.x, canvas_size.y, false, Image.FORMAT_RGBA8)
	black_image.fill(Color.TRANSPARENT)
	black_texture = ImageTexture.create_from_image(black_image)
	nail_layer.clear()


#清空画布。
#refund = true：把画布上剩的墨水还回瓶子（"重绘"按钮）。
#refund = false：这些墨水已经随固化变成刚体带走了，不能再还。
func clear(refund := true) -> void:
	if refund:
		_refund_all_ink()
	else:
		_flush_ink()                   # 这些墨已经随固化带走了，不能再还
		ink_px_by_material = {}
	black_image.fill(Color.TRANSPARENT)
	black_texture.update(black_image)
	nail_layer.clear()
	queue_redraw()


## 直接写入一个画布像素（"重新回到画布"用）；越界返回 false，批量写入后调 refresh()。
##
## ⚠️ 这里**不碰瓶子**：这些墨水在固化那一刻就已经从瓶里扣过了，再扣一次就是重复记账。
##    但它必须把**画布自己的**账补上 —— 否则这些像素对账本是隐形的，
##    "重绘"就退不回它们（这正是之前的 bug：抓回来的物品，墨水永远回不来）。
func write_pixel(pixel: Vector2i, color: Color) -> bool:
	if pixel.x < 0 or pixel.y < 0 or pixel.x >= canvas_size.x or pixel.y >= canvas_size.y:
		return false
	var before: int = material_at(pixel.x, pixel.y)
	black_image.set_pixelv(pixel, color)
	_bump_ink(before, -1, false)
	_bump_ink(InkPalette.material_id_at_color(color), 1, false)
	return true


## 把 CPU 像素缓冲刷到贴图；批量写入后调用一次。
func refresh() -> void:
	black_texture.update(black_image)
	_flush_ink()


#两点之间插值补点，避免鼠标移动过快断线
func _stroke(from: Vector2, to: Vector2, color: Color) -> void:
	#画之前先看瓶里还剩多少 px；擦除不设上限，钉子不花墨水。
	var room := 1 << 30
	if color.a > 0.5 and not _is_nail(color):
		room = _ink_room(ink_material_id())
	var delta := 0
	var steps := maxi(1, int(ceil(from.distance_to(to))))
	for i in range(steps + 1):
		delta += _stamp(from.lerp(to, float(i) / float(steps)), color, room - delta)
	black_texture.update(black_image)
	_flush_ink()


## 笔触直径，单位 px；圆形笔刷，绘制和擦除使用同一尺寸。
## 1 = 单像素；偶数直径按半整数半径铺（见 `_stamp`）。
@export var brush_size := 7:
	set(value):
		brush_size = maxi(1, value)
#落一个圆形笔刷；钉子不铺笔刷，只落单像素。
func _stamp(center: Vector2, color: Color, allowance: int) -> int:
	var pixels := {}
	if _is_nail(color):
		pixels[Vector2i(center.floor())] = true
	else:
		_collect_stamp(pixels, center)
	var delta := 0
	for pixel: Vector2i in pixels:
		delta += _write_pixel(pixel, color, allowance - delta)
	return delta


#把笔刷圆盘覆盖到的像素收进 out（只收，不写）。
func _collect_stamp(out: Dictionary, center: Vector2) -> void:
	#直径 1 直接取"点所在的那一格"。
	#⚠️ 不能走下面的距离判定：采样点正好落在**格角**上时（x、y 都是整数），
	#   半径 0.5 够不到任何格心 —— 1px 的线会随机缺格、1px 的圆环会开口，
	#   而开了口的封闭区域会被墨水桶灌满整张画布。
	if brush_size <= 1:
		out[Vector2i(center.floor())] = true
		return
	#⚠️ 半径下限 0.5：直径 1 的笔刷若用半径 0，只有圆心正好压在格心上才落笔，
	#   而鼠标坐标是小数 —— 实测 1px 笔触会"什么都画不出来"。
	var radius := maxf(0.5, (brush_size - 1) * 0.5)
	var r2 := radius * radius
	#⚠️ 边界必须按**真实圆心**推，不能按 roundi(center)：半径是半整数（偶数直径）时
	#   roundi 会把整圈偏一格，实测 3px 笔触只铺出 2x2。
	var x0 := floori(center.x - radius)
	var x1 := ceili(center.x + radius)
	var y0 := floori(center.y - radius)
	var y1 := ceili(center.y + radius)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if x < 0 or y < 0 or x >= canvas_size.x or y >= canvas_size.y:
				continue
			var dx := float(x) + 0.5 - center.x
			var dy := float(y) + 0.5 - center.y
			if dx * dx + dy * dy <= r2:
				out[Vector2i(x, y)] = true


#只改像素 + 同步钉子外观层，不碰任何账本。
func _set_pixel_raw(pixel: Vector2i, color: Color) -> void:
	var before: int = material_at(pixel.x, pixel.y)
	black_image.set_pixelv(pixel, color)
	if _is_nail(color):
		nail_layer.add(pixel)
	else:
		nail_layer.remove(pixel)
	_bump_ink(before, -1)
	_bump_ink(InkPalette.material_id_at_color(color), 1)


#写一个像素并记账，返回**墨水净变化**：+1 新画、-1 擦掉、0 没变或墨水不够。
#allowance 是本笔还剩多少 px 可画（擦除传大数）。
func _write_pixel(pixel: Vector2i, color: Color, allowance: int) -> int:
	if pixel.x < 0 or pixel.y < 0 or pixel.x >= canvas_size.x or pixel.y >= canvas_size.y:
		return 0
	var had: bool = black_image.get_pixelv(pixel).a > 0.5
	var want: bool = color.a > 0.5
	if want and not had and allowance <= 0:
		return 0
	_set_pixel_raw(pixel, color)
	if want and not had:
		return 1
	if had and not want:
		return -1
	return 0


## 在画布上放一枚钉子：写一个材质 4 的像素，外观由 NailLayer 画。
func _place_nail(point: Vector2) -> void:
	if not _inside(point):
		return
	#钉子不是墨水，不花瓶子里的墨。
	var delta := _write_pixel(Vector2i(point.floor()), nail_color(), 1 << 30)
	if delta == 0:
		return
	black_texture.update(black_image)
	_flush_ink()


#该像素是否为黑色墨水，供固化时采样
func is_solid(x: int, y: int) -> bool:
	return black_image.get_pixel(x, y).a > 0.5


## 透明=空；其余按色表认（认不出来返回 0）。
func material_at(x: int, y: int) -> int:
	return InkPalette.material_id_at_color(black_image.get_pixel(x, y))
#endregion


#region 矩形 / 圆形
#拖拽预览：每动一次先把上一帧改过的像素还原，再按新位置重画一圈。
#松手才记账，所以拖拽过程不会反复扣墨水。
func _update_shape() -> void:
	_revert_shape()
	var to: Vector2 = _mouse_point().clamp(Vector2.ZERO, Vector2(canvas_size))
	var pixels := _shape_pixels(_shape_origin, to)
	var room := _ink_room(ink_material_id())
	var delta := 0
	for pixel: Vector2i in pixels:
		var had: bool = black_image.get_pixelv(pixel).a > 0.5
		if not had and delta >= room:
			continue                      # 墨水不够：剩下的格子不落笔
		_shape_saved[pixel] = black_image.get_pixelv(pixel)
		_set_pixel_raw(pixel, ink_color())
		if not had:
			delta += 1
	_shape_delta = delta
	black_texture.update(black_image)
	_flush_ink()


#把上一帧的预览还原成原样并清空记录。
func _revert_shape() -> void:
	if _shape_saved.is_empty():
		return
	for pixel: Vector2i in _shape_saved:
		var prior: Color = _shape_saved[pixel]
		_set_pixel_raw(pixel, prior)
	_shape_saved.clear()
	_shape_delta = 0
	black_texture.update(black_image)


#松手定型：像素已经落在画布上了，这里只把这一笔的账记到瓶子上。
func _end_shape() -> void:
	_shaping = false
	_update_shape()
	_shape_saved.clear()
	_flush_ink()
	_shape_delta = 0


#形状外框 = 拿笔刷沿边界扫一圈，所以线宽就是笔刷直径。
func _shape_pixels(from: Vector2, to: Vector2) -> Dictionary:
	var out := {}
	if tool == Tool.CIRCLE:
		#圆心 = 按下点，半径 = 拖出的距离；永远是正圆。
		_brush_circle(out, from, from.distance_to(to))
	else:
		#按下点是一角，拖到对角。
		_brush_line(out, from, Vector2(to.x, from.y))
		_brush_line(out, Vector2(to.x, from.y), to)
		_brush_line(out, to, Vector2(from.x, to.y))
		_brush_line(out, Vector2(from.x, to.y), from)
	return out


#沿线段撒笔刷脚印；步长 ≤ 笔刷半径，保证圈与圈之间不留缝。
func _brush_line(out: Dictionary, from: Vector2, to: Vector2) -> void:
	var steps := maxi(1, int(ceil(from.distance_to(to) / _brush_step())))
	for i in range(steps + 1):
		_collect_stamp(out, from.lerp(to, float(i) / float(steps)))


func _brush_circle(out: Dictionary, center: Vector2, radius: float) -> void:
	if radius < 0.5:
		_collect_stamp(out, center)
		return
	var steps := maxi(8, int(ceil(TAU * radius / _brush_step())))
	for i in steps:
		_collect_stamp(out, center + Vector2.from_angle(TAU * float(i) / float(steps)) * radius)


func _brush_step() -> float:
	return maxf(1.0, brush_size * 0.5)
#endregion


#region 墨水桶
#把点所在的**连通空区**一次灌满。
#
#⚠️ 用 4 邻接，不是 8 邻接：数字拓扑里"8 连通的边界"正好困住"4 连通的填充"。
#   圆形的 1px 外框是斜着走的（8 连通），4 邻接的填充才不会从斜缝里漏出去。
#
#⚠️ 整块区域要么全灌、要么不动：瓶里不够就什么都不画（半灌的封闭区看着像坏了）。
#   所以先数够不够，再落笔；数的时候一旦超就提前退出。
#
#⚠️ 必须**封口**：一旦漫到画布边缘就说明这片区域是敞开的（点在了开阔处），
#   直接放弃。否则创造模式免墨水、没有余额上限，一下就把整张图灌满 ——
#   2048x1024 = 200 万格，既没用又会卡死。
#   顺带这也是最快的退出路径：栈是后进先出，DFS 会顺着一个方向一路走到边，
#   几步就撞线，不用扫完整张图。
#
#⚠️ 入栈和标记必须**内联**：`PackedByteArray` / `PackedInt32Array` 在 GDScript 里是
#   **值拷贝**，塞进 helper 里改，改的是副本 —— 会变成永远推同一个像素的死循环。
func _bucket_fill(point: Vector2) -> void:
	var w := canvas_size.x
	var h := canvas_size.y
	var start := Vector2i(point.floor())
	var data := black_image.get_data()
	var seen := PackedByteArray()
	seen.resize(w * h)
	var stack := PackedInt32Array()
	var targets := PackedInt32Array()
	var room := _ink_room(ink_material_id())

	var first := start.y * w + start.x
	if data[first * 4 + 3] > 127:
		return                       # 点在实心像素上：什么都不做
	seen[first] = 1
	stack.append(first)
	while not stack.is_empty():
		var top := stack.size() - 1
		var idx := stack[top]
		stack.resize(top)
		targets.append(idx)
		var x := idx % w
		var y := idx / w
		if x == 0 or y == 0 or x == w - 1 or y == h - 1:
			print("墨水桶：这片区域没封口（漫到画布边缘），不灌")
			return
		if targets.size() > room:
			print("墨水不足：这一片灌不下（瓶里 %d px）" % room)
			return
		if x > 0 and seen[idx - 1] == 0 and data[(idx - 1) * 4 + 3] <= 127:
			seen[idx - 1] = 1
			stack.append(idx - 1)
		if x + 1 < w and seen[idx + 1] == 0 and data[(idx + 1) * 4 + 3] <= 127:
			seen[idx + 1] = 1
			stack.append(idx + 1)
		if y > 0 and seen[idx - w] == 0 and data[(idx - w) * 4 + 3] <= 127:
			seen[idx - w] = 1
			stack.append(idx - w)
		if y + 1 < h and seen[idx + w] == 0 and data[(idx + w) * 4 + 3] <= 127:
			seen[idx + w] = 1
			stack.append(idx + w)

	var pixel := PackedByteArray([
		int(ink_color().r * 255.0), int(ink_color().g * 255.0),
		int(ink_color().b * 255.0), 255])
	for idx: int in targets:
		var at := idx * 4
		data[at] = pixel[0]
		data[at + 1] = pixel[1]
		data[at + 2] = pixel[2]
		data[at + 3] = pixel[3]
	black_image.set_data(canvas_size.x, canvas_size.y, false, Image.FORMAT_RGBA8, data)
	black_texture.update(black_image)
	_bump_ink(ink_material_id(), targets.size())
	_flush_ink()
#endregion


#region 墨水账
## 瓶中墨水的真源（玩家身上的 InkHealth）；接不到就当成无限墨水。
@export var health_path := NodePath("../../Player/InkHealth")

var _health = null
## 画布上各墨水的实心像素数：材质 id -> 数量。**这是画布自己的账**，和瓶子无关：
## 画布上写着多少墨，"重绘"就还多少。钉子不算墨水，不进这本账。
var ink_px_by_material := {}
## 本笔还没记到瓶子上的净变化：材质 id -> ±像素数。一笔只和瓶子对一次账。
var _pending_ink := {}
## 免墨水模式（创造模式）：整张画布不和瓶子对账 —— 画、擦、重绘都不动墨水。
## ⚠️ 关掉时画布上的墨算"免费"，所以进入时要把已经欠的账先结清（见 setter）。
@export var ink_free := false:
	set(value):
		if value == ink_free:
			return
		if value:
			_refund_all_ink()           # 先把画布上的墨还给瓶子，之后画布上的墨算免费
		ink_free = value


## 某墨水在画布上有多少像素。
func ink_px_of(material_id: int) -> int:
	return ink_px_by_material.get(material_id, 0)


#本笔还能新增多少像素（按当前墨水的余量）。
func _ink_room(material_id: int) -> int:
	var health = _health_node()
	if health == null:
		return 1 << 30
	return maxi(0, int(health.ink_of(material_id)))


#惰性解析墨水源：Player 可能比画布晚就绪。
func _health_node():
	if _health == null:
		_health = get_node_or_null(health_path)
	return _health


#画布自己的账：某墨水的像素数变化。钉子不是墨水，不进账。
#charge = false 只改画布自己的账、不记到瓶子上（"重新回到画布"那条路）。
func _bump_ink(material_id: int, delta: int, charge := true) -> void:
	if delta == 0 or ink_free:
		return
	if not InkPalette.is_ink(material_id):
		return
	ink_px_by_material[material_id] = ink_px_of(material_id) + delta
	if not charge:
		return
	_pending_ink[material_id] = _pending_ink.get(material_id, 0) + delta


#把本笔的净变化记到瓶子上；一次笔画只发一次信号。
func _flush_ink() -> void:
	var pending := _pending_ink
	_pending_ink = {}
	if ink_free or pending.is_empty():
		return
	var health = _health_node()
	if health == null:
		return
	for material_id in pending:
		var delta: int = pending[material_id]
		if delta > 0:
			health.reduce(material_id, float(delta))
		elif delta < 0:
			health.add(material_id, float(-delta))


#把画布上现有各墨水的库存全部还给瓶子（重建画布 / 重绘 / 进创造模式前）。
func _refund_all_ink() -> void:
	_flush_ink()
	var book := ink_px_by_material
	ink_px_by_material = {}
	if ink_free:
		return
	var health = _health_node()
	if health == null:
		return
	for material_id in book:
		var count: int = book[material_id]
		if count > 0:
			health.add(material_id, float(count))
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


## 保存整张透明 PNG：黑=空、颜色=材质 id。
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
	recount_ink_px()
	print("CANVAS loaded: ", ProjectSettings.globalize_path(path))
	return OK


#按像素重新数一遍画布自己的账 —— 读盘、以及怀疑账本漂了的时候用。
#⚠️ 会全图扫一遍，只走一次性路径，别塞进热循环。
func recount_ink_px() -> void:
	ink_px_by_material = {}
	_pending_ink = {}
	for y in range(canvas_size.y):
		for x in range(canvas_size.x):
			if black_image.get_pixel(x, y).a > 0.5:
				var material_id := material_at(x, y)
				if InkPalette.is_ink(material_id):
					ink_px_by_material[material_id] = ink_px_of(material_id) + 1


#按像素颜色重建钉子外观层；只在读盘时走一次。
func _rebuild_nails() -> void:
	nail_layer.clear()
	for y in range(canvas_size.y):
		for x in range(canvas_size.x):
			if material_at(x, y) == InkPalette.nail_material_id():
				nail_layer.add(Vector2i(x, y))
#endregion
