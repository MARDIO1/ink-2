@tool
extends Sprite2D
## 渲染子节点 —— 对标内置的 Sprite2D，负责把**兄弟形状节点**画出来。
##
## ## 为什么继承 Sprite2D 而不是自己 _draw
##
## 逐像素 draw_rect 在一个 800x40 的地面上就是 32000 次绘制调用，必然掉帧。
## 内置 Sprite2D 用一张贴图，硬件一次画完 —— 能使用内置的就使用内置的。
##
## ## 它和 PixelShape2D 的分工
##
##   PixelShape2D   决定**碰撞**形状
##   PixelSprite2D  决定**长什么样**
##
## 两者默认从同一批兄弟形状取像素（所以视觉与碰撞天然一致），
## 但它们可以分开：想给某个形状"只碰撞不显示"或"只显示不碰撞"，
## 就不给它挂对应的节点即可。
##
## ## 接口
##
## 本节点只认兄弟节点上的 build_shape() 方法，不检查类型 ——
## 和 PixelBody2D.collect_shapes() 是同一个约定。

const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")
const _PixelShading := preload("res://addons/pixel_destruction/render/pixel_shading.gd")
const PixelChunk := preload("res://addons/pixel_destruction/core/pixel_chunk.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")

@export_group("形状来源")
## 是否包含自己的形状？勾上则把本节点也算进形状来源（本节点一般没有形状，默认 false）
@export var include_self := false

@export_group("外观")
## 颜色表。留空则用 PixelWorld 的那张（保证和物理层同源）。
@export var palette: Array[Color] = []
## 覆盖透明度（<1 时半透明，做"虚影/未固化"之类效果）
@export_range(0.0, 1.0) var alpha := 1.0
## 逐像素着色（边沿压暗 + 顶面提亮 + 色调扰动）。见 PixelShading 的说明。
##
## ⚠️ **默认关闭** —— 见 PixelRenderer.shading 的说明（试过一版，读起来是噪点）。
## 它烘进贴图，运行时零开销，需要体积感时再打开。
@export var shading := false

var _tex: ImageTexture = null
var _sig := ""


func _ready() -> void:
	centered = false
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	texture = null
	rebuild()


## 重建贴图。只在实际内容变化时重做 —— 和 PixelRenderer 一样的脏标记思路：
## 位置/旋转不重建，形状变了才重建。
func rebuild() -> void:
	var shapes := _collect()
	var sig := _signature(shapes)
	if sig == _sig and _tex != null:
		return
	_sig = sig
	if shapes.is_empty():
		_tex = null
		texture = null
		visible = false
		return
	visible = true
	var box := Rect2i()
	var first := true
	for s: PixelShape in shapes:
		var b: Rect2i = s.local_aabb()
		if b.size.x <= 0:
			continue
		box = b if first else box.merge(b)
		first = false
	if box.size.x <= 0:
		_tex = null
		texture = null
		visible = false
		return
	# 贴图左上角贴在 box 的左上角
	offset = Vector2(box.position)
	var pal := palette
	if pal.is_empty():
		var w := _world_node()
		if w != null and "palette_for_render" in w:
			pal = w.palette_for_render()
	if pal.is_empty():
		pal = [Color(0, 0, 0, 0), Color(0.7, 0.7, 0.7)]
	var w2: int = box.size.x
	var h2: int = box.size.y
	var data := PackedByteArray()
	data.resize(w2 * h2 * 4)
	for s: PixelShape in shapes:
		for k: int in s.chunks:
			var c: PixelChunk = s.chunks[k]
			var bx := (PixelShape.key_x(k) << 3) - box.position.x
			var by := (PixelShape.key_y(k) << 3) - box.position.y
			var bits := c.occ
			while bits != 0:
				var i := Bits.first_bit_index(bits)
				bits &= bits - 1
				var gx := bx + (i & 7)
				var gy := by + (i >> 3)
				if gx < 0 or gx >= w2 or gy < 0 or gy >= h2:
					continue
				var mi: int = c.mat[i]
				if mi >= pal.size():
					mi = pal.size() - 1
				var col: Color = pal[mi]
				if shading:
					col = _PixelShading.shade(s, gx + box.position.x, gy + box.position.y, col)
				var o := (gy * w2 + gx) * 4
				data[o] = int(col.r * 255.0)
				data[o + 1] = int(col.g * 255.0)
				data[o + 2] = int(col.b * 255.0)
				data[o + 3] = int(col.a * 255.0 * alpha)
	var img := Image.create_from_data(w2, h2, false, Image.FORMAT_RGBA8, data)
	if _tex == null:
		_tex = ImageTexture.create_from_image(img)
	else:
		_tex.update(img)
	texture = _tex


## 收集兄弟里的形状（可选含自己）。
func _collect() -> Array:
	var out: Array = []
	var p := get_parent()
	if p == null:
		return out
	for c in p.get_children():
		if c == self and not include_self:
			continue
		if c.has_method("build_shape"):
			var s = c.build_shape()
			if s != null and not (s as PixelShape).is_empty():
				out.append(s)
	return out


## 签名：形状变了才重建贴图。用外接 + 像素数 + 材质和做粗指纹 ——
## 够便宜，且能抓住"挖了个洞""换了材质"这类变化。
func _signature(shapes: Array) -> String:
	# ⚠️⚠️ 必须带上 shape.revision。
	#    以前只用"外接 + 按材质像素数的加权和"做指纹 —— 那是**不完全**的：
	#    实测 8x8 实心块上"洞在 (2,2)"与"洞在 (6,6)"两个形状签名完全相同，
	#    于是 rebuild() 早退，精灵停在旧像素上（洞留在旧位置）。
	#    revision 是形状自己维护的，任何改动都 +1，不会漏。
	var parts := PackedStringArray()
	for s: PixelShape in shapes:
		var aabb: Rect2i = s.local_aabb()
		parts.append("%d,%d,%d,%d,r%d" % [aabb.position.x, aabb.position.y,
			aabb.size.x, aabb.size.y, s.revision])
	return "|".join(parts)


func _world_node() -> Node:
	var n: Node = get_parent()
	while n != null:
		if n.has_method("palette_for_render"):
			return n
		n = n.get_parent()
	return null
