extends RefCounted
## 编辑操作层：拾取 / 绘制 / 擦除。
##
## 刻意不依赖 Godot 的输入与渲染，所以无头测试可以直接驱动同一套代码路径
## （Demo 里的鼠标只是把世界坐标喂进来而已）。

const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")
const Brush := preload("res://addons/pixel_destruction/core/brush.gd")

## 一笔最多画进多少块画布瓦片 —— 这只是**防病态输入**的阀门。
##
## ⚠️ 早先设成 16，而默认视角（zoom 3）下一帧的鼠标位移就有 ~320 世界单位，
## 加上半径外扩，bbox 轻松覆盖 20+ 块瓦片。超出预算的瓦片被**静默丢弃**，
## 于是笔画"变细甚至断掉"：实测一段 800 单位、半径 40 的笔画只剩 3 像素厚
## （应为 80）。现在把阀门放大到远超正常使用，并且把丢弃数记在
## last_dropped_tiles 里，让"被截断"这件事**可见**（测试断言它为 0）。
const MAX_TILES_PER_STROKE := 256
## 上一次 paint_canvas 因阀门丢掉的瓦片数
static var last_dropped_tiles := 0


## 像素级拾取：先过 AABB，再逐 chunk 做位测试。
static func body_at(bodies: Array, world_point: Vector2, dynamic_only: bool) -> PBody:
	for b: PBody in bodies:
		if dynamic_only and b.is_static:
			continue
		if not b.aabb.has_point(world_point):
			continue
		var lp: Vector2 = b.to_local(world_point)
		for s: PixelShape in b.shapes:
			for k: int in s.chunks:
				var c = s.chunks[k]
				var px := int(floor(lp.x)) - (PixelShape.key_x(k) << 3)
				var py := int(floor(lp.y)) - (PixelShape.key_y(k) << 3)
				if px < 0 or px >= 8 or py < 0 or py >= 8:
					continue
				if (c.occ & (1 << (px + (py << 3)))) != 0:
					return b
	return null


## 往一个 Body 的所有 Shape 上落笔（局部坐标）。返回新增像素数。
##
## ⚠️ world 是**可选但强烈建议传**：不传的话新像素的**质量**按"1 像素 1 质量"算
##    （世界的密度表用不上）—— 画上去的重物会轻得不对。传了就用世界的密度/摩擦/恢复三个表。
##    （摩擦/恢复不传也**不会**再被清成 0 了 —— 见 PBody.rebuild 的说明。）
##
## ⚠️ 笔触的脏范围是**算出来的**（线段包围盒 + 半径 + 2 余量），所以贴图只重画脏块。
##    刷子的判据是"像素中心到线段的距离 <= radius"（见 Brush.stroke_circle），
##    候选范围 = 线段包围盒外扩 r，所以这个矩形**可证**覆盖全部改动像素
##    （mark_dirty_range 的契约是"可以更大，不能更小"）。
static func paint_into(body: PBody, local_from: Vector2, local_to: Vector2, radius: float, material: int,
		clip: Rect2i = Rect2i(), world = null) -> int:
	var added := 0
	for s: PixelShape in body.shapes:
		added += Brush.stroke_circle(s, local_from, local_to, radius, material, clip)
	if added > 0:
		var pad := int(ceil(radius)) + 2
		var lo := Vector2i(floori(minf(local_from.x, local_to.x)), floori(minf(local_from.y, local_to.y))) - Vector2i(pad, pad)
		var hi := Vector2i(ceili(maxf(local_from.x, local_to.x)), ceili(maxf(local_from.y, local_to.y))) + Vector2i(pad, pad)
		var dr := Rect2i(lo, hi - lo)
		if world != null:
			body.rebuild(body.shapes, world.density_callable(), world.max_rects_per_shape, dr,
				world.friction_callable(), world.restitution_callable())
		else:
			body.rebuild(body.shapes, Callable(), 64, dr)
	return added


## 取得（或创建）一块静态画布瓦片。
static func canvas_tile(world, tiles: Dictionary, tx: int, ty: int, tile_size: int) -> PBody:
	var key := Vector2i(tx, ty)
	var existing = tiles.get(key)
	if existing != null:
		return existing
	var b := PBody.new()
	b.position = Vector2(tx * tile_size, ty * tile_size)
	b.make_static()
	world.add_body(b, [PixelShape.new()])
	tiles[key] = b
	return b


## 把一笔画进画布瓦片（可能横跨多块）。返回被修改的 Body 列表。
static func paint_canvas(world, tiles: Dictionary, from: Vector2, to: Vector2,
		radius: float, material: int, tile_size: int) -> Array:
	var touched: Array = []
	var lo := Vector2(minf(from.x, to.x), minf(from.y, to.y)) - Vector2(radius, radius)
	var hi := Vector2(maxf(from.x, to.x), maxf(from.y, to.y)) + Vector2(radius, radius)
	var t0x := int(floor(lo.x / tile_size))
	var t0y := int(floor(lo.y / tile_size))
	var t1x := int(floor(hi.x / tile_size))
	var t1y := int(floor(hi.y / tile_size))
	last_dropped_tiles = 0
	var budget := 0
	for ty in range(t0y, t1y + 1):
		for tx in range(t0x, t1x + 1):
			budget += 1
			if budget > MAX_TILES_PER_STROKE:
				# 记数并跳过，而不是 return —— return 会让笔画后半截凭空消失
				last_dropped_tiles += 1
				continue
			var origin := Vector2(tx * tile_size, ty * tile_size)
			var body := canvas_tile(world, tiles, tx, ty, tile_size)
			# 关键：把落笔裁剪到这块瓦片自己的范围内。
			# 以前没有裁剪，等于把**整笔**画进了每一个重叠瓦片里 ——
			# 一笔下去会多出好几份重叠的像素和好几个 Body（实测一笔变 4 块）。
			var clip := Rect2i(0, 0, tile_size, tile_size)
			if paint_into(body, from - origin, to - origin, radius, material, clip, world) > 0:
				touched.append(body)
	return touched


## 擦除一笔：对区域内每个 Body 施加线段破坏并做连通性分裂。
## 返回 Array[Dictionary{ body, removed, spawned }]。
static func erase(world, from: Vector2, to: Vector2, radius: float, burst: float) -> Array:
	var results: Array = []
	var lo := Vector2(minf(from.x, to.x), minf(from.y, to.y)) - Vector2(radius, radius)
	var hi := Vector2(maxf(from.x, to.x), maxf(from.y, to.y)) + Vector2(radius, radius)
	var region := Rect2(lo, hi - lo)
	for b: PBody in world.bodies.duplicate():
		if b.shapes.is_empty():
			continue
		if not b.aabb.intersects(region, true):
			continue
		var before := 0
		for s: PixelShape in b.shapes:
			before += s.pixel_count()
		var d := Destruction.Damage.segment(b.to_local(from), b.to_local(to), radius)
		var spawned: Array = world.fracture(b, d, burst)
		var after := 0
		for s2: PixelShape in b.shapes:
			after += s2.pixel_count()
		# fracture 会把大部分像素"搬"到碎片 Body 上，那不是被擦掉的。
		# 真正被销毁的像素 = 擦前 - 原体剩余 - 碎片带走
		var moved := 0
		for f: PBody in spawned:
			for sf: PixelShape in f.shapes:
				moved += sf.pixel_count()
		var destroyed := before - after - moved
		if destroyed <= 0 and spawned.is_empty():
			continue
		results.append({"body": b, "removed": destroyed, "moved": moved, "spawned": spawned})
	return results
