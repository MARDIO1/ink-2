extends RefCounted
## 形状（Shape）级的操作集合。
##
## 引擎里 `PixelShape` 只负责"像素数据"本身；这一层放的是**跨对象的操作** ——
## 创建/清空/复制、按连通性切分与合并、相邻判定、最近点、按材质查询。
## 全部用世界坐标或"形状自身的局部像素坐标"，不会混。
##
## 命名与引擎其它部分一致（snake_case），不照搬外部 API 的名字。

const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const PixelChunk := preload("res://addons/pixel_destruction/core/pixel_chunk.gd")
const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")
const Query := preload("res://addons/pixel_destruction/physics/query.gd")


## 新建一个形状；给了 ref 就连内容一起复制。给了 body 就挂上去。
static func create(body = null, ref = null) -> PixelShape:
	var s := PixelShape.new()
	if ref is PixelShape:
		copy_content(ref, s)
	if body != null:
		attach_to(s, body)
	return s


## 清空所有像素（形状对象本身保留）。
static func clear(shape: PixelShape) -> void:
	shape.chunks.clear()
	var ob = shape.owner_body
	if ob != null:
		ob.rebuild(ob.shapes)


## **替换**目标的内容（会先清空 dst）。名字就是它的语义 ——
## 合并请用 union_into，用错会把目标原有的像素全丢掉。
static func copy_content(src: PixelShape, dst: PixelShape) -> void:
	dst.chunks.clear()
	for k in src.chunks:
		dst.chunks[k] = (src.chunks[k] as PixelChunk).clone()
	dst.density_scale = src.density_scale


## 把 src 的像素**并进** dst（保留 dst 原有的）。同一 chunk 内按位取并集，
## 只覆盖 src 新增的那些位。
static func union_into(src: PixelShape, dst: PixelShape) -> void:
	for k in src.chunks:
		var sc: PixelChunk = src.chunks[k]
		if sc.occ == 0:
			continue
		var dc: PixelChunk = dst.chunks.get(k)
		if dc == null:
			dst.chunks[k] = sc.clone()
			continue
		var bits := sc.occ & ~dc.occ
		while bits != 0:
			var i := Bits.first_bit_index(bits)
			bits &= bits - 1
			dc.occ |= 1 << i
			dc.mat[i] = sc.mat[i]


## 把形状挂到刚体上（会从原刚体上摘下来）。
static func attach_to(shape: PixelShape, body) -> void:
	var old = shape.owner_body
	if old != null and old != body:
		old.shapes.erase(shape)
		old.rebuild(old.shapes)
	shape.owner_body = body
	if body != null and not body.shapes.has(shape):
		body.shapes.append(shape)
		body.rebuild(body.shapes)


static func body_of(shape: PixelShape):
	return shape.owner_body


## 形状的**世界变换**。注意本引擎的形状没有独立局部变换 ——
## 像素直接活在刚体局部空间里，所以世界变换就等于刚体变换。
static func world_transform(shape: PixelShape) -> Transform2D:
	var ob = shape.owner_body
	return Transform2D(ob.rotation, ob.position) if ob != null else Transform2D.IDENTITY


static func bounds(shape: PixelShape) -> Rect2i:
	return shape.local_aabb()


static func size(shape: PixelShape) -> Vector2i:
	return shape.local_aabb().size


static func voxel_count(shape: PixelShape) -> int:
	return shape.pixel_count()


static func density(shape: PixelShape) -> float:
	return shape.density_scale


## 形状级密度倍率（质量 = Σ 材质密度 * density_scale）。
static func set_density(shape: PixelShape, d: float) -> void:
	shape.density_scale = d
	var ob = shape.owner_body
	if ob != null:
		ob.rebuild(ob.shapes)


## 局部像素坐标处的材质 id（0 = 空）。
static func material_at_index(shape: PixelShape, x: int, y: int) -> int:
	return shape.get_pixel(x, y)


## **世界坐标**处的材质 id（0 = 空）。
static func material_at_position(shape: PixelShape, world_point: Vector2) -> int:
	var ob = shape.owner_body
	if ob == null:
		return 0
	var l: Vector2 = ob.to_local(world_point)
	return shape.get_pixel(int(floor(l.x)), int(floor(l.y)))


## 用矩形填一段像素（material = 0 等价于擦除）。
static func draw_box(shape: PixelShape, rect: Rect2i, material: int = 1) -> void:
	shape.fill_rect(rect, material)


## 按连通性切块。**最大的那块留在原形状**，其余作为新形状挂到同一个刚体上并返回。
## 这是 `PWorld.fracture` 的"只切分、不破坏"版本。
static func split(shape: PixelShape) -> Array:
	var parts: Array = Destruction.split(shape, 1)
	if parts.size() <= 1:
		return []
	var best := 0
	var best_n := -1
	for i in parts.size():
		var n: int = (parts[i] as PixelShape).pixel_count()
		if n > best_n:
			best_n = n
			best = i
	var rest: Array = []
	for i in parts.size():
		if i != best:
			rest.append(parts[i])
	copy_content(parts[best], shape)
	var ob = shape.owner_body
	if ob != null:
		for s in rest:
			attach_to(s, ob)
	return rest


## 把同一刚体里**与本形状相邻**的形状并进来，返回本形状。
static func merge(shape: PixelShape) -> PixelShape:
	var ob = shape.owner_body
	if ob == null:
		return shape
	var merged := false
	for other: PixelShape in ob.shapes.duplicate():
		if other == shape or not is_touching(shape, other):
			continue
		# ⚠️ 这里必须是**并集**。第一版用了 copy_content（替换语义），
		# 结果合并后原形状的像素被整个丢掉，只剩对方那半。
		union_into(other, shape)
		ob.shapes.erase(other)
		merged = true
	if merged:
		ob.rebuild(ob.shapes)
	return shape


## 形状内部是否有孤岛（引擎的不变量要求每个形状连通，所以正常永远是 false）。
static func is_disconnected(shape: PixelShape) -> bool:
	return Destruction.split(shape, 1).size() > 1


## 两个形状在世界空间里是否相邻或重叠（含对角接触）。
static func is_touching(a: PixelShape, b: PixelShape) -> bool:
	var ba = a.owner_body
	var bb = b.owner_body
	if ba == null or bb == null:
		return false
	var ma := Transform2D(ba.rotation, ba.position)
	var mb_inv := Transform2D(bb.rotation, bb.position).affine_inverse()
	for k in a.chunks:
		var c: PixelChunk = a.chunks[k]
		if c.occ == 0:
			continue
		var bx := PixelShape.key_x(k) << 3
		var by := PixelShape.key_y(k) << 3
		var bits := c.occ
		while bits != 0:
			var i := Bits.first_bit_index(bits)
			bits &= bits - 1
			var wp := ma * Vector2(float(bx + (i & 7)) + 0.5, float(by + (i >> 3)) + 0.5)
			var lp := mb_inv * wp
			var lx := int(floor(lp.x))
			var ly := int(floor(lp.y))
			for oy in range(-1, 2):
				for ox in range(-1, 2):
					if b.get_pixel(lx + ox, ly + oy) != 0:
						return true
	return false


## 形状上离 world_point 最近的实心像素。返回 Query.Hit。
static func closest_point(shape: PixelShape, world_point: Vector2) -> Query.Hit:
	return Query.closest_point_on_shape(shape, world_point)


## 每像素的**连通分量序号**（-1 = 空）。
##
## 返回 { "count": n, "chunks": { chunk_key: PackedInt32Array(64) } }。
## 一次算好之后，"这个像素属于哪个连通体"就是 O(1) ——
## 比每次重跑一遍连通性判定便宜得多。
##
## ⚠️ 为什么放在这里而不是 PixelShape：PixelShape 不能 preload Destruction
## （Destruction 已经 preload 了 PixelShape，反向再加一条就成环，
##  编辑器会因无限递归无声段错误）。本文件同时依赖两边，是放它的正确位置。
##
## 底层走的是 Destruction.components()，也就是 split() 用的**同一份**计算。
static func component_map(shape: PixelShape) -> Dictionary:
	var groups := Destruction.components(shape)
	var out := {}
	var ci := 0
	for idx in groups:
		var g: Dictionary = groups[idx]
		for k: int in g:
			var arr: PackedInt32Array
			if out.has(k):
				arr = out[k]
			else:
				arr = PackedInt32Array()
				arr.resize(Bits.PIXELS)
				arr.fill(-1)
				out[k] = arr
			var mask: int = g[k]
			while mask != 0:
				var i := Bits.first_bit_index(mask)
				mask &= mask - 1
				arr[i] = ci
		ci += 1
	return {"count": ci, "chunks": out}
