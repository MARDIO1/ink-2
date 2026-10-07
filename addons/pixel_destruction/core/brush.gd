extends RefCounted
## 画笔：在 Shape 局部像素空间里成圆/成线地增删像素。
##
## 绘制 = 加像素；擦除复用 destruction 的 keep-mask 路径（擦完自动做连通性分裂）。
## 拖动时按"上一帧位置 -> 当前位置"落笔，Demo 每帧调一次，所以**多段必须拼得连续**。

const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")
const PixelChunk := preload("res://addons/pixel_destruction/core/pixel_chunk.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")


## 圆盘 = 退化成一个点的胶囊。
static func stamp_circle(shape: PixelShape, center: Vector2, radius: float, material: int,
		clip: Rect2i = Rect2i()) -> int:
	return stroke_circle(shape, center, center, radius, material, clip)


## 沿线段 from->to 画一条**精确胶囊**（from == to 时就是圆盘）。
## 返回新增（原本为空）的像素数。
##
## 判据只有一条：**像素中心到线段的距离 <= radius**。
##
## ⚠️ 这里换掉了"沿线段按间距补点、每个点盖一个圆盘"的老写法。老写法有两个后果：
##   1. 补点间距被 MAX_STEPS 截断后会超过笔刷直径 —— 细笔刷直接画成**虚线**
##      （开发日志坑 7：MAX_STEPS 看着像性能保护，实际是个间距参数）；
##   2. 就算间距正常，圆盘并集的边缘也是**扇形起伏**的 —— 实测 r=20 时
##      同一笔的厚度在 38~40 之间波动，肉眼看就是"变细"。
## 直接按"到线段的距离"光栅化，两个问题一起消失；而且更快：
## 省掉了逐行 sqrt，也省掉了把整笔在每个瓦片里重算一遍。
static func stroke_circle(shape: PixelShape, from: Vector2, to: Vector2, radius: float, material: int,
		clip: Rect2i = Rect2i()) -> int:
	var r := maxf(0.5, radius)
	var r2 := r * r
	var d := to - from
	var len2 := d.length_squared()
	var has_clip := clip.size.x > 0 and clip.size.y > 0
	# 候选范围 = 线段包围盒外扩 r，再按瓦片裁剪
	var x0 := int(floor(minf(from.x, to.x) - r))
	var x1 := int(floor(maxf(from.x, to.x) + r))
	var y0 := int(floor(minf(from.y, to.y) - r))
	var y1 := int(floor(maxf(from.y, to.y) + r))
	if has_clip:
		# x 和 y 都要裁！只裁 y 会让每一块瓦片把整笔的宽度都写满（坑 6）。
		x0 = maxi(x0, clip.position.x)
		x1 = mini(x1, clip.end.x - 1)
		y0 = maxi(y0, clip.position.y)
		y1 = mini(y1, clip.end.y - 1)
	if x0 > x1 or y0 > y1:
		return 0
	var added := 0
	for y in range(y0, y1 + 1):
		var py := float(y) + 0.5 - from.y
		for x in range(x0, x1 + 1):
			var px := float(x) + 0.5 - from.x
			# 投影到线段取参数 t，再看残差长度
			var t := 0.0
			if len2 > 1e-12:
				t = clampf((px * d.x + py * d.y) / len2, 0.0, 1.0)
			var ex := px - d.x * t
			var ey := py - d.y * t
			if ex * ex + ey * ey > r2:
				continue
			if shape.add_pixel(x, y, material):
				added += 1
	return added


## 擦除：对可能的多个 Shape 施加同一破坏源。返回删除的像素数。
static func erase_at(shapes: Array, center: Vector2, radius: float) -> int:
	var d := Destruction.Damage.circle(center, radius)
	var removed := 0
	for s: PixelShape in shapes:
		removed += Destruction.apply_damage(s, d)
	return removed


static func erase_stroke(shapes: Array, from: Vector2, to: Vector2, radius: float) -> int:
	var d := Destruction.Damage.segment(from, to, radius)
	var removed := 0
	for s: PixelShape in shapes:
		removed += Destruction.apply_damage(s, d)
	return removed
