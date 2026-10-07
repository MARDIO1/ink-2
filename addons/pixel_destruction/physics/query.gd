extends RefCounted
## Teardown 的 **Scene queries** 分类。
##
## 核心是`QueryRaycast` —— 对破坏类游戏来说这是最要紧的一个查询。
## 这里走的是**体素网格的 DDA**，所以打在像素画上能精确到单个像素，
## 而不是拿 OBB 近似（拿 OBB 近似的话，一个 24x24 的像素人形会被当成一个方块）。
##
## 约定与 Teardown 一致：
##   · 坐标一律**世界空间**；
##   · 返回的 normal 由被击中的表面**指向射线来向**（即"表面外法线"）；
##   · 距离是沿射线方向的距离，不是射线长度。
##
## 过滤器（一直生效到 clear_filters）：
##   · reject_body(b)  排除某些刚体
##   · require(mask)   只查这些碰撞层（刚体 collision_layer 与它有交集才被看见）
##   · include(mask)   在已有要求上追加层

## ⚠️ 这里必须用 src/ 路径：addon 里的同名脚本是**另一份资源**，
## 用 addon 路径做类型标注会让"类型 pbody.gd 赋值给类型 pbody.gd"直接报错
## （构建脚本负责在生成 addon 时把这几行改写成 addon 路径）。
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")
const PixelChunk := preload("res://addons/pixel_destruction/core/pixel_chunk.gd")


## 一次射线/最近点查询的结果。字段名对齐 Teardown 的多返回值。
class Hit:
	var hit := false
	var distance := 0.0            ## 沿射线的距离
	var point := Vector2.ZERO      ## 世界坐标命中点
	var normal := Vector2.ZERO     ## 世界坐标表面法线
	var material := 0              ## 命中像素的材质 id（0 = 空）
	var body = null                ## 命中的刚体
	var shape = null               ## 命中的形状


static func _hit_none() -> Hit:
	return Hit.new()


## Teardown 的 `QueryRaycast(origin, direction, maxDist, radius?, rejectTransparent?)`。
##
## `radius > 0` 时是"加粗射线"（扫掠一个半径 radius 的圆）。
## 两种实现路径：
##   · radius == 0 -> 体素 DDA，O(射线穿过的像素数)，很快；
##   · radius > 0  -> 扫掠圆 vs 像素网格，O(包围盒面积)，慢一些但精确。
## `reject` 是要跳过的刚体数组（Teardown 的 QueryRejectBody）。
static func raycast(origin: Vector2, dir: Vector2, max_dist: float,
		radius := 0.0, reject: Array = _reject) -> Hit:
	var best := _hit_none()
	if dir == Vector2.ZERO or max_dist <= 0.0:
		return best
	var d := dir.normalized()
	# 射线的世界包围盒（含 radius），用来快速剔除刚体
	# ⚠️ 至少要留 1 像素的厚度：轴对齐的射线（比如纯水平）会让包围盒在另一轴上
	# **宽度为 0**，而 Rect2.intersects 对零面积的矩形一律返回 false ——
	# 于是所有水平/垂直射线都会静默打空。
	var pad := Vector2(maxf(radius, 1.0), maxf(radius, 1.0))
	var lo := origin - pad
	var hi := origin + d * max_dist + pad
	var bounds := Rect2(Vector2(minf(lo.x, hi.x), minf(lo.y, hi.y)),
		Vector2(maxf(absf(hi.x - lo.x), 1.0), maxf(absf(hi.y - lo.y), 1.0)))
	best.distance = max_dist
	for b: PBody in _candidates(bounds, reject):
		var h := _ray_vs_body(b, origin, d, max_dist, radius)
		if h.hit and h.distance < best.distance:
			best = h
	return best


## Teardown 的 `QueryClosestPoint(origin, maxDist)`：找最近的**实心像素**。
static func closest_point(origin: Vector2, max_dist: float,
		reject: Array = _reject) -> Hit:
	var best := _hit_none()
	var best_d2 := max_dist * max_dist
	for b: PBody in _candidates(Rect2(origin - Vector2(max_dist, max_dist),
			Vector2(max_dist, max_dist) * 2.0), reject):
		var h := _closest_vs_body(b, origin, max_dist)
		if h.hit:
			var d2 := origin.distance_squared_to(h.point)
			if d2 < best_d2:
				best_d2 = d2
				best = h
	if best.hit:
		best.distance = sqrt(best_d2)
	return best


## Teardown 的 `QueryAabbShapes(min, max)`。
static func aabb_shapes(bounds: Rect2) -> Array:
	var out: Array = []
	for b: PBody in _candidates(bounds, []):
		for s in b.shapes:
			out.append(s)
	return out


## Teardown 的 `QueryAabbBodies(min, max)`。
static func aabb_bodies(bounds: Rect2) -> Array:
	return _candidates(bounds, [])


static func _candidates(bounds: Rect2, reject: Array) -> Array:
	var out: Array = []
	for b: PBody in _bodies:
		if b.rects.is_empty():
			continue
		if reject.has(b):
			continue
		if not _passes_layers(b):
			continue
		if not bounds.intersects(b.aabb):
			continue
		out.append(b)
	return out


## 层过滤：刚体的 collision_layer 与查询要求的层**有交集**才算候选。
##
## ⚠️ 这是**单向**判据（查询自己不在任何层上），和 Rapier 的 InteractionGroups
##    （双方都要同意）不是一回事 —— 查询只是"在挑东西"，没有"自己被挑"的语义。
##    所以这里不能复用刚体那套 layer/mask 双向判据。
static func _passes_layers(b: PBody) -> bool:
	return (b.collision_layer & _require_mask) != 0


## 当前世界（由 Query.attach 设置）。Teardown 的查询是全局的，
## 这里显式挂一个世界，避免用全局单例。
static var _bodies: Array = []

static var _reject: Array = []

## 查询要求命中的层（位掩码）。默认全 1 = 不限。
## 见 require() / include()。
static var _require_mask := 0xFFFFFFFF

static func attach(world) -> void:
	_bodies = world.bodies
	_reject.clear()
	_require_mask = 0xFFFFFFFF


## 注销。**必须在世界销毁时调用** —— 否则这个静态数组会一直持有刚体引用，
## Godot 退出时会报 "resources still in use at exit" / "Orphan StringName"。
static func detach(world = null) -> void:
	if world == null or _bodies == world.bodies:
		_bodies = []
	_reject.clear()


## 查询时排除某些刚体（一直生效到 clear_filters）。
static func reject_body(b) -> void:
	if not _reject.has(b):
		_reject.append(b)


## 只查询这些层（位掩码）。默认全 1 = 不限。
##
## 典型用法：
##     Query.require(LAYER_TERRAIN)          # 这一枪只打地形
##     Query.require(LAYER_ENEMY | LAYER_WALL)
##
## ⚠️ 掩码是"要求命中的层"，不是"排除的层"：刚体的 collision_layer 与它有交集才被看见。
##    collision_layer = 0 的刚体永远查不到（它不在任何层上）。
static func require(mask: int) -> void:
	_require_mask = mask


## 追加可命中的层（并集）。用于"在已有要求上再加一类"。
static func include(mask: int) -> void:
	_require_mask |= mask


## 清掉查询过滤器（reject + 层要求）。
static func clear_filters() -> void:
	_reject.clear()
	_require_mask = 0xFFFFFFFF


## ---------------- 单刚体：细射线（体素 DDA） ----------------

static func _ray_vs_body(b: PBody, origin: Vector2, d: Vector2, max_dist: float,
		radius: float) -> Hit:
	if radius > 0.0:
		return _swept_circle_vs_body(b, origin, d, max_dist, radius)
	# 转到刚体局部系：像素坐标就活在这里
	var lo := b.to_local(origin)
	var ld := d.rotated(-b.rotation)
	var best := _hit_none()
	var best_t := max_dist
	for s in b.shapes:
		var h := _dda(s, lo, ld, best_t)
		if h.hit and h.distance < best_t:
			best_t = h.distance
			best = h
			best.shape = s
			best.body = b
	if best.hit:
		# 局部 -> 世界
		best.point = b.to_world(best.point)
		best.normal = best.normal.rotated(b.rotation)
	return best


## Amanatides-Woo 体素 DDA。只穿**实心像素**，所以像素画的空洞是真的能穿过去的。
static func _dda(shape: PixelShape, o: Vector2, d: Vector2, max_t: float) -> Hit:
	var res := _hit_none()
	if d == Vector2.ZERO:
		return res
	var x := int(floor(o.x))
	var y := int(floor(o.y))
	# 起点已经在实心像素里：直接命中，法线取射线来向的反方向
	if shape.get_pixel(x, y) != 0:
		res.hit = true
		res.distance = 0.0
		res.point = o
		res.normal = -d
		res.material = shape.get_pixel(x, y)
		return res
	var step_x := 1 if d.x > 0.0 else -1
	var step_y := 1 if d.y > 0.0 else -1
	var t_max_x := INF
	var t_max_y := INF
	var t_delta_x := INF
	var t_delta_y := INF
	if d.x != 0.0:
		var nx := float(x + (1 if d.x > 0.0 else 0))
		t_max_x = (nx - o.x) / d.x
		t_delta_x = absf(1.0 / d.x)
	if d.y != 0.0:
		var ny := float(y + (1 if d.y > 0.0 else 0))
		t_max_y = (ny - o.y) / d.y
		t_delta_y = absf(1.0 / d.y)
	var normal := Vector2.ZERO
	var t := 0.0
	# 上限保护：极端细长步进时也不会死循环
	var guard := 0
	var limit := int(max_t * 4.0) + 8
	while t <= max_t and guard < limit:
		guard += 1
		if t_max_x < t_max_y:
			t = t_max_x
			t_max_x += t_delta_x
			x += step_x
			normal = Vector2(-float(step_x), 0.0)
		else:
			t = t_max_y
			t_max_y += t_delta_y
			y += step_y
			normal = Vector2(0.0, -float(step_y))
		if t > max_t:
			break
		var m: int = shape.get_pixel(x, y)
		if m != 0:
			res.hit = true
			res.distance = t
			res.point = o + d * t
			res.normal = normal
			res.material = m
			return res
	return res


## ---------------- 单刚体：加粗射线（扫掠圆） ----------------

static func _swept_circle_vs_body(b: PBody, origin: Vector2, d: Vector2, max_dist: float,
		radius: float) -> Hit:
	var lo := b.to_local(origin)
	var ld := d.rotated(-b.rotation)
	var best := _hit_none()
	var best_t := max_dist
	# 只扫"射线走过的包围盒 + 半径"范围内的像素
	var pad := radius + 1.0
	var x0 := int(floor(minf(lo.x, lo.x + ld.x * max_dist) - pad))
	var x1 := int(ceil(maxf(lo.x, lo.x + ld.x * max_dist) + pad))
	var y0 := int(floor(minf(lo.y, lo.y + ld.y * max_dist) - pad))
	var y1 := int(ceil(maxf(lo.y, lo.y + ld.y * max_dist) + pad))
	for s in b.shapes:
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var m: int = s.get_pixel(x, y)
				if m == 0:
					continue
				var c := Vector2(float(x) + 0.5, float(y) + 0.5)
				# 像素中心到射线的最近参数 t（夹在 [0, max_dist]）
				var t := clampf((c - lo).dot(ld), 0.0, max_dist)
				var cp := lo + ld * t
				var off := c - cp
				var dist := off.length()
				if dist > radius + 0.7071:      # 半个像素对角
					continue
				if t < best_t:
					best_t = t
					best.hit = true
					best.distance = t
					best.point = cp
					# 法线：从像素指向射线（再转回世界）
					best.normal = (-off).normalized() if dist > 1e-6 else -ld
					best.material = m
					best.shape = s
					best.body = b
	if best.hit:
		best.point = b.to_world(best.point)
		best.normal = best.normal.rotated(b.rotation)
	return best


## 单个形状上的最近实心像素（Teardown 的 GetShapeClosestPoint）。
##
## ⚠️ 不能直接遍历整个 AABB —— 一块 4000x40 的地面就是 16 万次像素检查。
## 先用"AABB 上的最近点"求出距离下界，把搜索半径收紧到 d0+2，
## 再按 chunk 级剔除（稀疏形状这一步就把绝大部分块跳掉了）。
## **法向厚度**：从世界坐标某点出发、沿给定方向穿过材料，最厚的一段有多少像素。
##
## 用途是破坏判据：同一种材料**抗压远强于抗剪** —— 矛尖正面顶在盾面上是压缩，
## 盾牌边缘横向切矛杆是剪切/弯曲。要区分这两者就得知道「法向穿过了多厚」。
##
## 做法就是沿射线逐像素走一遍数连续实心（体素数据现成的，不用建任何加速结构）。
## 返回 0 表示这条线上没有材料。
##
## ⚠️ 从 point - dir*back 开始走而不是从 point 开始 —— 接触点可能落在
##    表面外侧半个像素，直接从它出发会得到 0。
static func thickness_at(body, world_point: Vector2, normal: Vector2,
		max_steps: int = 96, back: int = 4) -> float:
	if body == null or normal.length_squared() < 1.0e-12:
		return 0.0
	var n := normal.normalized()
	# 局部方向：形状活在刚体局部空间，只有旋转没有缩放
	var lp: Vector2 = body.to_local(world_point)
	var ld: Vector2 = body.to_local(world_point + n) - lp
	if ld.length_squared() < 1.0e-12:
		return 0.0
	ld = ld.normalized()
	var shapes: Array = body.shapes
	var best := 0
	var run := 0
	for i in range(-back, max_steps):
		var q := lp + ld * float(i)
		var solid := false
		for s: PixelShape in shapes:
			if s.get_pixel(int(floor(q.x)), int(floor(q.y))) != 0:
				solid = true
				break
		if solid:
			run += 1
			if run > best:
				best = run
		else:
			run = 0
	return float(best)


## **真实接触宽度**：沿接触切向从接触点向两侧走，数「两个形状都实心」的像素数。
##
## ⚠️ 不要用「两个刚体 AABB 在切向上的重叠」来近似 —— 我第一版就是这么写的，
##    结果**看不出矛是尖的**：矛的 AABB 高 16、盾也是 16，算出来宽度相同，
##    而宽体的质量大 16 倍，于是「盾的应力反而更大」，与物理完全相反。
##
##    这个量是破坏判据的分母，必须反映**真实接触面积**，所以直接数体素。
##    矛尖只有几像素宽 → 应力大 → 破盾；盾面贴上来几十像素宽 → 应力小 → 不破。
##
## ⚠️ 代价：沿切向走 2*half+1 步、每步查两个形状的像素（实测 60~110 us/接触，
##    窗口随两者 AABB 的重叠跨度涨）。所以**调用方必须惰性** ——
##    PWorld.Contact.contact_width 就是惰性的：只有真去读它才算这一次。
##
## ⚠️ 它只喂 Contact 事件的应力（σ = impulse / width），**从不进求解器**
##    （见 collide.gd 的同名说明）—— 改它不会影响物理结果。
##
## ⚠️ separation 是"两个刚体还没真正重叠"时的分离距离（投机接触）。当前唯一调用方
##    （PWorld._fill_contact_stress）传的是 0 —— 见下面的 push 说明，那一支还没被接上。
static func contact_width(a, b, world_point: Vector2, normal: Vector2,
		separation: float = 0.0) -> float:
	var t := Vector2(-normal.y, normal.x)
	# ⚠️⚠️ 采样要各自往自己身体里挪，而且挪的距离必须**大于分离距离**。
	#
	#    接触点恰好落在两者界面上时，floor() 会对两边都判"空" → 宽度恒 0。
	#    更要命的是**投机接触**：那时两个刚体还没真正重叠（separation > 0），
	#    接触点悬在空隙里，固定挪 0.5 根本够不着任何一侧 ——
	#    于是"最狠的那一击"（第一次撞上、冲量最大的那一帧）宽度报 0，
	#    σ = impulse/0 直接失效。实测验収：矛尖撞墙那帧 separation 0.73~1.44，
	#    挪 0.5 → 宽度 0；挪 1.0/1.5 → 宽度 1，σ 立刻从 0 变成 1539133。
	var push := maxf(0.5, separation + 0.5)
	var ea := world_point - normal * push
	var eb := world_point + normal * push
	# ⚠️ 窗口不能写死：以前固定 ±24，于是 60 px 宽和 200 px 宽的接触都算出 49，
	#    应力分别被高估 1.2 倍和 4 倍，"宽接触应力小"的分级整个失效。
	#    改成覆盖两者 AABB 在切向上的**重叠跨度**（那才是宽度的物理上限）。
	var sa := project_span(a.aabb, t)
	var sb := project_span(b.aabb, t)
	var overlap := maxf(0.0, minf(sa.y, sb.y) - maxf(sa.x, sb.x))
	var half := clampi(int(ceil(overlap * 0.5)) + 4, 8, 4096)
	var n := 0
	for i in range(-half, half + 1):
		var off := t * float(i)
		if solid_at(a, ea + off) and solid_at(b, eb + off):
			n += 1
	return float(n)


## 世界坐标这一点在某刚体上是**实心像素**吗（不看碰撞层/掩码，也不看 Query 的过滤器）。
static func solid_at(body, world_point: Vector2) -> bool:
	var lp: Vector2 = body.to_local(world_point)
	var x := int(floor(lp.x))
	var y := int(floor(lp.y))
	for s: PixelShape in body.shapes:
		if s.get_pixel(x, y) != 0:
			return true
	return false


## 把世界 AABB 投影到方向 t 上，返回 [min, max] 区间。
static func project_span(box: Rect2, t: Vector2) -> Vector2:
	var c := box.get_center()
	var e := box.size * 0.5
	var h := absf(t.x) * e.x + absf(t.y) * e.y
	var m := c.dot(t)
	return Vector2(m - h, m + h)


static func closest_point_on_shape(shape: PixelShape, origin: Vector2) -> Hit:
	var res := _hit_none()
	var ob: PBody = shape.owner_body
	if ob == null:
		return res
	var box := shape.local_aabb()
	if box.size.x <= 0 or box.size.y <= 0:
		return res
	var lo := ob.to_local(origin)
	var lb := Vector2(
		clampf(lo.x, float(box.position.x), float(box.position.x + box.size.x)),
		clampf(lo.y, float(box.position.y), float(box.position.y + box.size.y)))
	var r := lo.distance_to(lb) + 2.0
	var best_d2 := INF
	for k in shape.chunks:
		var c: PixelChunk = shape.chunks[k]
		if c.occ == 0:
			continue
		var bx := PixelShape.key_x(k) << 3
		var by := PixelShape.key_y(k) << 3
		if float(bx) > lo.x + r or float(bx + 8) < lo.x - r:
			continue
		if float(by) > lo.y + r or float(by + 8) < lo.y - r:
			continue
		var bits := c.occ
		while bits != 0:
			var i := Bits.first_bit_index(bits)
			bits &= bits - 1
			var px := float(bx + (i & 7)) + 0.5
			var py := float(by + (i >> 3)) + 0.5
			var dx := lo.x - px
			var dy := lo.y - py
			var d2 := dx * dx + dy * dy
			if d2 < best_d2:
				best_d2 = d2
				res.hit = true
				res.point = Vector2(px, py)
				res.material = c.mat[i]
				res.shape = shape
				res.body = ob
	if res.hit:
		res.distance = sqrt(best_d2)
		res.normal = (lo - res.point).normalized() if best_d2 > 1e-12 else Vector2.UP
		res.point = ob.to_world(res.point)
		res.normal = res.normal.rotated(ob.rotation)
	return res


## ---------------- 最近点 ----------------

static func _closest_vs_body(b: PBody, origin: Vector2, max_dist: float) -> Hit:
	var lo := b.to_local(origin)
	var res := _hit_none()
	var best_d2 := max_dist * max_dist
	var r := int(ceil(max_dist)) + 1
	var ox := int(floor(lo.x))
	var oy := int(floor(lo.y))
	for s in b.shapes:
		for y in range(oy - r, oy + r + 1):
			for x in range(ox - r, ox + r + 1):
				var m: int = s.get_pixel(x, y)
				if m == 0:
					continue
				var c := Vector2(float(x) + 0.5, float(y) + 0.5)
				var d2 := lo.distance_squared_to(c)
				if d2 < best_d2:
					best_d2 = d2
					res.hit = true
					res.point = c
					res.normal = (lo - c).normalized() if d2 > 1e-12 else Vector2.UP
					res.material = m
					res.shape = s
					res.body = b
	if res.hit:
		res.distance = sqrt(best_d2)
		res.point = b.to_world(res.point)
		res.normal = res.normal.rotated(b.rotation)
	return res
