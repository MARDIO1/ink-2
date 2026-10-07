extends RefCounted

const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
## 逐像素着色 —— 给"每个材质一块纯色"加上体积感。
##
## ## 为什么放在渲染层而不是物理层
##
## 这三样全是**视觉**：边沿压暗、顶面提亮、色调扰动。
## 它们不参与任何物理计算，也不改变形状 —— 只是**烘进贴图时**把颜色算一遍。
## 所以代价是**零运行时开销**：贴图只在内容变化时重建（见 PixelShape.revision），
## 重建时多算几十纳秒/像素，之后每帧都是硬件贴图采样。
##
## ## 三件事各自解决什么
##
##   边沿压暗   和空像素相邻的面压暗，暗多少取决于开了几面 —— 方块立刻有厚度
##   顶面提亮   上方是空的面提亮 —— 假装光从上方来（2D 像素画的通用做法）
##   色调扰动   每个像素有极小的确定性明暗抖动 —— 打破"整块死平"的塑料感
##
## 扰动必须是**确定性**的：同一个像素每次算出来必须一样，
## 否则贴图重建（破坏之后）会让整块地面的噪点位置整体跳一下，非常刺眼。

## 光照方向偏好：顶面提亮多少（1.0 = 不提亮）
const TOP_GAIN := 1.10
## 每个暴露面压暗多少
const EDGE_LOSS := 0.085
## 色调扰动幅度（±）
const TONE_JITTER := 0.030
## 底边额外压暗（地面接触处的"重"感）
const BOTTOM_LOSS := 0.05


## 算一个像素的最终颜色。
##
## [param shape] 形状，用来查四邻域
## [param x] [param y] 局部像素坐标
## [param base] 材质基色
static func shade(shape: PixelShape, x: int, y: int, base: Color) -> Color:
	if base.a <= 0.0:
		return base
	var up := shape.get_pixel(x, y - 1) == 0
	var down := shape.get_pixel(x, y + 1) == 0
	var left := shape.get_pixel(x - 1, y) == 0
	var right := shape.get_pixel(x + 1, y) == 0
	var open_n := (1 if up else 0) + (1 if down else 0) + (1 if left else 0) + (1 if right else 0)
	if open_n == 0:
		# 内部像素：只加色调扰动
		return _jitter(base, x, y)
	var k := 1.0 - EDGE_LOSS * float(open_n)
	if up:
		k *= TOP_GAIN
	if down:
		k *= (1.0 - BOTTOM_LOSS)
	var c := Color(base.r * k, base.g * k, base.b * k, base.a)
	return _jitter(c, x, y)


## 确定性色调扰动。
##
## ⚠️ 不能用 randf()：贴图在每次形状变化时重建，随机数会让整片地面的
##    噪点位置整体重排 —— 破坏一下，地面"闪"一次，非常明显。
##    这里用坐标的整数哈希，同一像素永远同一个值。
static func _jitter(c: Color, x: int, y: int) -> Color:
	# 32 位整数混合（xorshift 风格），取低 16 位当 0..1
	var h := (x * 73856093) ^ (y * 19349663)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	var t := float(h & 0xFFFF) / 65535.0 * 2.0 - 1.0
	var k := 1.0 + TONE_JITTER * t
	return Color(c.r * k, c.g * k, c.b * k, c.a)


## 给整张调色板做一版"预制"的深色/亮色变体，方便需要更廉价着色时用。
static func darken(c: Color, amount: float) -> Color:
	return Color(c.r * (1.0 - amount), c.g * (1.0 - amount), c.b * (1.0 - amount), c.a)
