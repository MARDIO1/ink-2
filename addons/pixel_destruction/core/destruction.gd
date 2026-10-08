extends RefCounted
## 破坏管线：破坏形状 -> 掩码 -> 应用 -> 连通性分片。
##
## 与参考实现（VoxelEngineExperiments）的对应关系：
##   DestructionShapeChunkOverlapJob -> 这里直接按 AABB 逐 chunk 求交
##   DestructionMaskGenerationJob   -> make_keep_mask()
##   ShapeVoxelRemovePackJob         -> 同一目标 chunk 的掩码按位与合并（吸收上游的"未来优化"）
##   ShapeVoxelRemoveJob             -> PixelChunk.apply_keep_mask()
##   ShapeChunkFragmentJob           -> Bits.flood() 逐分量泛洪
##   ShapeChunkCheckMaskJob + ConnectivityJob -> 交界列/行按位与
##   ShapeFragmentUnionJob           -> union-find
##   ShapeBuildJob                   -> 组装新 Shape

const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")
const PixelChunk := preload("res://addons/pixel_destruction/core/pixel_chunk.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")

## 破坏源类型
enum Kind { CIRCLE, SEGMENT, RECT }

## 一个破坏源。坐标是"目标 Shape 本地像素空间"。
class Damage:
	var kind: int = Kind.CIRCLE
	var a: Vector2 = Vector2.ZERO
	var b: Vector2 = Vector2.ZERO
	var radius: float = 4.0
	var half: Vector2 = Vector2.ONE
	var material_delta: int = 0

	static func circle(center: Vector2, r: float) -> Damage:
		var d := Damage.new()
		d.kind = Kind.CIRCLE
		d.a = center
		d.radius = r
		return d

	static func segment(from: Vector2, to: Vector2, r: float) -> Damage:
		var d := Damage.new()
		d.kind = Kind.SEGMENT
		d.a = from
		d.b = to
		d.radius = r
		return d

	static func rect(center: Vector2, half_size: Vector2) -> Damage:
		var d := Damage.new()
		d.kind = Kind.RECT
		d.a = center
		d.half = half_size
		return d

	func bounds() -> Rect2:
		match kind:
			Kind.CIRCLE:
				return Rect2(a - Vector2(radius, radius), Vector2(radius, radius) * 2.0)
			Kind.SEGMENT:
				var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2(radius, radius)
				var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + Vector2(radius, radius)
				return Rect2(lo, hi - lo)
			_:
				return Rect2(a - half, half * 2.0)

	func hits(px: float, py: float) -> bool:
		## px/py 是像素中心（+.5 已在调用侧加好）。
		match kind:
			Kind.CIRCLE:
				var dx := px - a.x
				var dy := py - a.y
				return dx * dx + dy * dy <= radius * radius
			Kind.SEGMENT:
				var ab := b - a
				var len2 := ab.length_squared()
				var t := 0.0
				if len2 > 0.000001:
					t = clampf(((Vector2(px, py) - a).dot(ab)) / len2, 0.0, 1.0)
				return (Vector2(px, py) - (a + ab * t)).length_squared() <= radius * radius
			_:
				return absf(px - a.x) <= half.x and absf(py - a.y) <= half.y


## 生成一个 chunk 的 keep 掩码（bit 1 = 保留，bit 0 = 删除）。
## 把一次碰撞的**多个接触点**变成多个**损伤入口**，并按各点冲量分配这次碰撞的预算。
##
## ⚠️⚠️ 为什么需要它：面-面接触有多个点（通常 2 个），而整对的冲量是**一个预算**。
##    对每个点都用同一个半径打洞 = 总损伤面积是单点的 N 倍 = **预算被重复领取**。
##    这里让**面积**按份额走：radius_i = base_radius * sqrt(share_i)，
##    于是 Σ 面积 ≈ 单点面积（预算守恒）。
##
## ⚠️ 重叠区域：本引擎的伤害是**二值**的（make_keep_mask 只决定"这个像素留不留"），
##    所以两个入口覆盖同一像素**不会**被扣两次 —— 那部分天然安全。
##    要防的只是上面那条"预算被重复领取"。
##    ⚠️ 但游戏层若用 aux 表做**逐像素血量**，重复扣减要游戏层自己记账 —— 引擎不替它决定
##    （"多猛算高速""高速要怎样"是游戏规则，见 PWorld.Contact 的说明）。
##
## ⚠️ penetrating 只在 dist < 0（真穿透）时为 true：推测接触（dist > 0）虽然也有冲量，
##    但那是在**阻止接近** —— 照着它打洞就是"擦身而过也打洞"。
##
## points: [{position, dist, impulse}, ...]（来自 PWorld.Contact.points）
## total_impulse: 整对总冲量（来自 Contact.total_impulse，实测各点之和 = 它）
## 返回 [{point, impulse, share, radius, penetrating}, ...]
static func contact_entries(points: Array, total_impulse: float, base_radius: float,
		min_share: float = 0.05) -> Array:
	var out: Array = []
	if total_impulse <= 0.0 or base_radius <= 0.0:
		return out
	for p in points:
		var share: float = absf(float(p["impulse"])) / total_impulse
		if share < min_share:
			continue          # 份额太小：不打洞，免得拖出一串微小入口
		out.append({
			"point": p["position"],
			"impulse": float(p["impulse"]),
			"share": share,
			"radius": base_radius * sqrt(share),
			"penetrating": float(p["dist"]) < 0.0,
		})
	return out


static func make_keep_mask(chunk_key: int, damage: Damage, force_keep: int = 0) -> int:
	# ⚠️⚠️ **判据按 kind 内联，不要逐像素调 damage.hits()**：
	#    · 方法调用本身约 0.3 us/像素；
	#    · segment 还会**每像素重算** ab 与 length_squared()（各一次向量运算）；
	#    · match kind 也每像素走一遍。
	#    实测 768x100 一刀 r=60（14400 像素）**8.8 ms**，内联 + 提公因式后 ~2 ms。
	#    这是每一笔破坏都在付的钱（擦除/画笔/碎片生成都走这里）。
	#
	# ⚠️⚠️ **表达式与 hits() 里逐字相同**（同一个浮点运算顺序）—— 这是位等价的前提：
	#    所以 radius*radius、ab = b-a、len2、dot 的展开都**原样保留**，不能"顺手化简"。
	#    位等价由 tests/validation_damage_mask.gd 拿冻结的旧实现逐位对拍。
	var bx := PixelShape.key_x(chunk_key) << 3
	var by := PixelShape.key_y(chunk_key) << 3
	var kind := damage.kind
	var ax := damage.a.x
	var ay := damage.a.y
	var rr := damage.radius * damage.radius
	var abx := damage.b.x - ax
	var aby := damage.b.y - ay
	var len2 := abx * abx + aby * aby
	var hx := damage.half.x
	var hy := damage.half.y
	var keep := 0
	for y in 8:
		var py := float(by + y) + 0.5
		for x in 8:
			var bit := 1 << (x + (y << 3))
			if (force_keep & bit) != 0:
				keep |= bit
				continue
			var px := float(bx + x) + 0.5
			var hit := false
			if kind == Kind.CIRCLE:
				var dx := px - ax
				var dy := py - ay
				hit = dx * dx + dy * dy <= rr
			elif kind == Kind.SEGMENT:
				var t := 0.0
				if len2 > 0.000001:
					t = clampf(((px - ax) * abx + (py - ay) * aby) / len2, 0.0, 1.0)
				var qx := px - (ax + abx * t)
				var qy := py - (ay + aby * t)
				hit = qx * qx + qy * qy <= rr
			else:
				hit = absf(px - ax) <= hx and absf(py - ay) <= hy
			if not hit:
				keep |= bit
	return keep


## 对整个 Shape 应用一个破坏源。返回被删除的像素数。
## 采用"每个目标 chunk 只产生一条最终 keep 掩码"的合并策略。
static func apply_damage(shape: PixelShape, damage: Damage) -> int:
	var bounds := damage.bounds()
	var cx0 := int(floor(bounds.position.x / 8.0))
	var cy0 := int(floor(bounds.position.y / 8.0))
	var cx1 := int(floor((bounds.end.x - 0.0001) / 8.0))
	var cy1 := int(floor((bounds.end.y - 0.0001) / 8.0))
	var removed := 0
	for cy in range(cy0, cy1 + 1):
		for cx in range(cx0, cx1 + 1):
			var k := PixelShape.make_key(cx, cy)
			var c: PixelChunk = shape.chunks.get(k)
			if c == null or c.occ == 0:
				continue
			var keep := make_keep_mask(k, damage, ~c.occ)
			var before := c.count()
			c.apply_keep_mask(keep)
			removed += before - c.count()
			if c.is_empty():
				shape.chunks.erase(k)
	return removed


## 连通性分片：把 Shape 拆成若干 4 邻域连通的子 Shape。
## 返回 Array[PixelShape]，每个都已剔除空 chunk。
## min_pixels 以下的分量直接丢弃（Teardown 里小碎块会消失）。
## 伤害是否**碰到形状边界 ∂S**。
##
## ⚠️ 这是一个**可证明成立**的"不可能断开"判据：
##    对**凸**的伤害集 R（圆 / 线段 / 矩形都是凸的），
##    若 R 严格在形状 S 内部（R ∩ ∂S = ∅），则 S\R 必然仍连通。
##    直观：S\R 若被分成两块，R 就得是一条"割"，
##    而凸集要成为割必须触及边界。（环形管子里放一个凸块，S\R 仍连通。）
##
## ⚠️⚠️ 判据是"**碰到边界**"，**不是**"包围盒离边界有余量"。
##    后者是错的：细杆在中间被擦断时，包围盒离形状外边界很远，
##    但它确实断开了 —— 那种情况下被擦的像素**贴着杆的边界**。
##
## 为什么值得做：split 要跑全量连通分量标记（768x100 = 1248 个 chunk，
## 实测 **31 ms**），而绝大多数笔画都是内部挖洞 —— 这一条能省掉它们。
static func touches_boundary(shape: PixelShape, rect: Rect2i) -> bool:
	var y0: int = rect.position.y
	var x0: int = rect.position.x
	# ⚠️⚠️ 八邻域**内联**判断，不要调 shape.neighbors() ——
	#    那个函数每次都**分配一个 Array**（8 个 Vector2i），
	#    而这里对 40x40 的探测框要跑 1600 次，实测 **5.4 ms**。
	#    内联之后只是一串 get_pixel，没有分配。
	#
	#    这一条本身是"花 5.4 ms 去省一次 33 ms 的 split"，净赚；
	#    但 5.4 ms 太贵了 —— 它出现在**每一笔**擦除里。
	# ⚠️⚠️ **整块跳过**：一个 occ 全满、且八邻域也全满的 chunk，
	#    它里面的任何像素都不可能邻接空像素 -> 不可能是边界像素 -> 整块跳过。
	#
	#    为什么需要：上面那个逐像素版本对 28x28 的探测框要跑 784 x 9 次
	#    get_pixel，实测 **4.7 ms**，而且**每一笔擦除都要付**。
	#    实心地面的大多数 chunk 都是全满的，跳过它们之后只剩边缘那一圈。
	#
	#    判据是**可靠**的（不是启发式）：全满块 + 八邻域全满 =>
	#    块内每个像素的八邻域都在占用集合内 => 没有边界像素。
	#    反过来，任何一块不满（或邻域有缺口）就退回逐像素查 —— 宁可多查，不能漏。
	#
	#    形状最外圈的 chunk 一定不满足（邻域缺失），所以外边界照常能查到。
	var FULL := -1
	var cx0 := x0 >> 3
	var cy0 := y0 >> 3
	var cx1 := (x0 + rect.size.x - 1) >> 3
	var cy1 := (y0 + rect.size.y - 1) >> 3
	for cy in range(cy0, cy1 + 1):
		for cx in range(cx0, cx1 + 1):
			var c: PixelChunk = shape.chunks.get(PixelShape.make_key(cx, cy))
			if c == null or c.occ == 0:
				continue                       # 整块空，本块内没有占用像素
			if c.occ == FULL:
				var solid := true
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if dx == 0 and dy == 0:
							continue
						var n: PixelChunk = shape.chunks.get(
							PixelShape.make_key(cx + dx, cy + dy))
						if n == null or n.occ != FULL:
							solid = false
							break
					if not solid:
						break
				if solid:
					continue                   # 全满且邻域全满 -> 不可能有边界像素
			# 本块内逐像素查（只查这一块，不是整个探测框）
			var px0 := maxi(x0, cx << 3)
			var py0 := maxi(y0, cy << 3)
			var px1 := mini(x0 + rect.size.x, (cx << 3) + 8)
			var py1 := mini(y0 + rect.size.y, (cy << 3) + 8)
			for y in range(py0, py1):
				for x in range(px0, px1):
					if shape.get_pixel(x, y) == 0:
						continue
					if shape.get_pixel(x - 1, y) == 0 or shape.get_pixel(x + 1, y) == 0 							or shape.get_pixel(x, y - 1) == 0 or shape.get_pixel(x, y + 1) == 0 							or shape.get_pixel(x - 1, y - 1) == 0 or shape.get_pixel(x + 1, y - 1) == 0 							or shape.get_pixel(x - 1, y + 1) == 0 or shape.get_pixel(x + 1, y + 1) == 0:
						return true
	return false


## adopt：调用方**保证母形状会被丢掉**（fracture / detach / fracture_pixels / ensure_connected
## 都是"用分片替换母形状"的语义）—— 那时整块拷贝可以**直接搬 PixelChunk 对象**，
## 不分配、不拷表。实测（768x100 一刀两半）：_assemble 的拷贝 7.3 -> 2.5 ms。
##
## ⚠️⚠️ adopt 是**所有权转移**的声明，不是优化开关：传 true 之后母形状**不能再被使用**
##    （它的 chunk 对象现在同时挂在分片上）。`ShapeOps.split` 那条公开路径**必须传 false**
##    （它要保留母形状的残余内容）。
## ⚠️ 逐块 mark_dirty_key **故意保留**（实测 1.27 ms / 1248 块）：那是给游戏层
##    `take_dirty_keys` 用的，省掉它会变成静默的行为变化。
static func split(shape: PixelShape, min_pixels: int = 1, adopt := false) -> Array:
	var keys: Array = shape.chunks.keys()
	if keys.is_empty():
		return []
	var parts := _components_cpu(shape, keys)
	return _assemble(shape, keys, parts, min_pixels, adopt)



## 便宜的"破坏后仍然连通"判据 —— **可证明**，不是启发式。三态返回。
##
## 记号：R = 这一笔**被删掉**的像素；N = 破坏**之后**仍占用、且与 R 四邻接的像素；
##      N' = 破坏之后仍占用、且落在"伤害包围盒外扩 1"里的像素。
##      **N ⊆ N'**，所以用 N' 判是保守的（判据更强 -> 更不容易误判连通）。
##
## ⚠️⚠️ 定理：若 S 在破坏前连通，且 N' 全部落在 S\R 的**同一个连通分量**里，
##    则 S\R 必然只有一个连通分量。
##    证明：反设 S\R = C ⊔ D 两个分量。S 连通 => 存在从 C 到 D 的路径，
##    该路径必须离开 C、进入 R、再离开 R 进入 D。离开 C 前最后一个像素属于 C
##    且与 R 四邻接 => 它属于 N ⊆ N'。同理 D 也含 N' 的像素。
##    于是 N' 不可能全在同一个分量里，矛盾。∎
##
## 所以只要在**探测框内**验证"N' 彼此连通"（框内连通 => 在 S\R 里连通，
## 因为框内没有别的障碍），就能免掉一次全量连通分量标注
## （768x100 实测 7.8 ms，而一笔内部擦除本身才 ~2.8 ms）。
## 代价随**伤害大小**走，不再随物体尺寸走 —— 这正是"贴着边界挖小洞"卡的原因。
##
## ⚠️ 判不出来就返回 LOCAL_UNKNOWN 走全量 —— 宁可慢，不能错。
##    细杆被切断正是这种情况：R 横跨杆宽，N' 被 R 分成左右两截，局部连不上。
##
## ⚠️⚠️ 依赖一条引擎不变量：**body 的 shape 在破坏前一定连通**。
##    它由"每一笔破坏要么保连通、要么做分裂"维持 —— 本函数就是前者的判据。
##    如果游戏层**手工**造了一个多岛屿的 shape，这条不变量不成立，
##    此时可能给出"连通"而跳过分裂；那是"今天会被顺手修好"的行为差异，
##    不是正确性契约（多岛屿刚体本身是合法的，只是不会被这一笔拆开）。
const LOCAL_UNKNOWN := -1
const LOCAL_DROPPED := 0
const LOCAL_CONNECTED := 1
## 探测框像素上限。
##
## ⚠️ 这是**代价交叉点**，不是随手取的数：局部判据约 1.5 us/像素（探测框逐像素取占用 +
##    框内泛洪），而它要替代的全量连通分量标注在 768x100 上是 **13.5 ms** —— 交叉点约
##    9000 像素。原来取 1024 太小：一笔 90px 的 segment 探测框就有 1456 像素，
##    于是**长笔画全部退回全量**（实测贴边界拖一笔 15.7 ms，而单点小洞只要 7.3 ms，
##    差的正是这一趟）。取 4096 让长笔画也走快路径，同时保证最坏情况仍比全量便宜。
const LOCAL_MAX_PROBE := 4096

static func local_connectivity(shape: PixelShape, box: Rect2i, min_pixels: int) -> int:
	var grow := Rect2i(box.position - Vector2i(1, 1), box.size + Vector2i(2, 2))
	var probe := Rect2i(box.position - Vector2i(3, 3), box.size + Vector2i(6, 6))
	var w: int = probe.size.x
	var h: int = probe.size.y
	if w <= 0 or h <= 0 or w * h > LOCAL_MAX_PROBE:
		return LOCAL_UNKNOWN
	var occ := PackedByteArray()
	occ.resize(w * h)
	var n_idx := PackedInt32Array()
	var gx0: int = grow.position.x - probe.position.x
	var gy0: int = grow.position.y - probe.position.y
	for yy in h:
		var wy: int = probe.position.y + yy
		var row := yy * w
		for xx in w:
			if not shape.get_pixel(probe.position.x + xx, wy):
				continue
			occ[row + xx] = 1
			if xx >= gx0 and xx < gx0 + grow.size.x and yy >= gy0 and yy < gy0 + grow.size.y:
				n_idx.append(row + xx)
	if n_idx.is_empty():
		return LOCAL_UNKNOWN       # 没有 N'（整块被删光？）—— 不猜
	# 探测框内泛洪（四邻域，只走占用像素）
	var seen := PackedByteArray()
	seen.resize(w * h)
	var stack := PackedInt32Array()
	stack.append(n_idx[0])
	seen[n_idx[0]] = 1
	while stack.size() > 0:
		var i: int = stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		var x := i % w
		var y := i / w
		if x > 0:
			var j1 := i - 1
			if seen[j1] == 0 and occ[j1] == 1:
				seen[j1] = 1
				stack.append(j1)
		if x < w - 1:
			var j2 := i + 1
			if seen[j2] == 0 and occ[j2] == 1:
				seen[j2] = 1
				stack.append(j2)
		if y > 0:
			var j3 := i - w
			if seen[j3] == 0 and occ[j3] == 1:
				seen[j3] = 1
				stack.append(j3)
		if y < h - 1:
			var j4 := i + w
			if seen[j4] == 0 and occ[j4] == 1:
				seen[j4] = 1
				stack.append(j4)
	for j in n_idx:
		if seen[j] == 0:
			return LOCAL_UNKNOWN    # N' 没全连通 -> 判不出来，走全量
	# 定理成立 => 破坏后仍然连通。剩下只是 min_pixels 的语义，与 _assemble 的单分量路径一致。
	if shape.pixel_count() >= min_pixels:
		return LOCAL_CONNECTED
	return LOCAL_DROPPED


## ---------- GPU 加速路径 ----------
## 一次 dispatch 同时算出"破坏后的占用"和"每个 chunk 的分量掩码"，
## 回读后复用与 CPU 完全相同的接缝归并 / 组装代码。
## 返回 {"removed": int, "parts": Array}；返回空字典表示应退回 CPU
## （设备不可用 / 规模太小 / 分量溢出）。
static func apply_damage_and_split_gpu(shape: PixelShape, damage: Damage, min_pixels: int = 1, force: bool = false) -> Dictionary:
	# ⚠️⚠️ **先判开关，再取后端。**
	#
	#    gpu_backend() 第一次调用会建 RenderingDevice 后端 + 编译 compute pipeline，
	#    实测 **5.5 ms**（带窗口时是 126 ms）—— 然后才发现 GPU 破坏路径是关的
	#    （gpu_destruction.gd: const ENABLED := false），白做一场。
	#
	#    后果不只是慢：这 5.5 ms 只出现在**第一笔**上，之后每一笔只要 0.12 ms。
	#    于是第一笔和其余各笔的手感不一样 —— 用户说的"影响擦除手感"。
	#    这就是"预热"要解决的东西：**把一次性成本从热路径上挪走**。
	#
	#    force=true 是显式要求（测试会用），那种情况仍然走完整流程。
	if not force and not _gpu_enabled():
		return {}
	var keys: Array = shape.chunks.keys()
	if keys.is_empty():
		return {}
	var gpu = gpu_backend()
	if gpu == null or not gpu.available:
		return {}
	var n := keys.size()
	if not force and not gpu.should_use_gpu(n):
		return {}

	var occ_pairs := PackedInt32Array()
	var anchors := PackedInt32Array()
	occ_pairs.resize(n * 2)
	anchors.resize(n * 2)
	for i in n:
		var k: int = keys[i]
		var c: PixelChunk = shape.chunks[k]
		occ_pairs[i * 2] = c.occ & 0xFFFFFFFF
		occ_pairs[i * 2 + 1] = (c.occ >> 32) & 0xFFFFFFFF
		anchors[i * 2] = PixelShape.key_x(k) << 3
		anchors[i * 2 + 1] = PixelShape.key_y(k) << 3

	var res: Dictionary = gpu.process(occ_pairs, anchors, _pack_damage(damage))
	if not bool(res.get("ok", false)):
		return {}
	var counts: PackedInt32Array = res.get("counts", PackedInt32Array())
	var occ_out: PackedInt32Array = res.get("occ", PackedInt32Array())
	var comps: PackedInt32Array = res.get("comp", PackedInt32Array())
	if counts.size() != n or occ_out.size() != n * 2 or comps.size() != n * GpuMaxComp * 2:
		return {}
	for i2 in n:
		# count == 0 是合法的：这个 chunk 被完全炸空了。
		# 只有"分量数超过 GPU 侧上限"才需要退回 CPU，保证结果一致。
		if (counts[i2] & GpuOverflowFlag) != 0:
			return {}

	# 写回占用，并同步材质表（GPU 不管材质，材质留在 CPU）
	var removed_total := 0
	for i3 in n:
		var k3: int = keys[i3]
		var c3: PixelChunk = shape.chunks[k3]
		var old_occ := c3.occ
		var lo := occ_out[i3 * 2] & 0xFFFFFFFF
		var hi := occ_out[i3 * 2 + 1] & 0xFFFFFFFF
		var new_occ := lo | (hi << 32)
		if new_occ == old_occ:
			continue
		c3.occ = new_occ
		var gone := old_occ & ~new_occ
		while gone != 0:
			var bi := Bits.first_bit_index(gone)
			c3.mat[bi] = 0
			gone &= gone - 1
		removed_total += Bits.popcount(old_occ & ~new_occ)
		if c3.is_empty():
			shape.chunks.erase(k3)

	# 从 GPU 的分量掩码组装 node 表
	var parts := {"comp_masks": {}, "node_of": {}, "node_chunk": [], "node_mask": []}
	var node_chunk: Array = parts["node_chunk"]
	var node_mask: Array = parts["node_mask"]
	var comp_masks: Dictionary = parts["comp_masks"]
	var node_of: Dictionary = parts["node_of"]
	for i4 in n:
		var k4: int = keys[i4]
		if not shape.chunks.has(k4):
			continue
		var cnt: int = counts[i4]
		var masks: Array = []
		var nodes: Array = []
		for s in cnt:
			var lo2 := comps[(i4 * GpuMaxComp + s) * 2] & 0xFFFFFFFF
			var hi2 := comps[(i4 * GpuMaxComp + s) * 2 + 1] & 0xFFFFFFFF
			var mask := lo2 | (hi2 << 32)
			if mask == 0:
				continue
			masks.append(mask)
			nodes.append(node_chunk.size())
			node_chunk.append(k4)
			node_mask.append(mask)
		if masks.is_empty():
			return {}
		comp_masks[k4] = masks
		node_of[k4] = nodes
	if node_chunk.is_empty():
		return {"removed": removed_total, "parts": []}
	# adopt=true：调用方（fracture）会用 parts 替换母形状 —— 见 split() 的说明。
	return {"removed": removed_total, "parts": _assemble(shape, keys, parts, min_pixels, true)}


const GpuOverflowFlag := 0x80000000
const GpuMaxComp := 16

static var _gpu_backend_cache = null

## GPU 破坏路径是否启用（缓存一次）。
##
## ⚠️ 存在的理由是**避免一次性成本落在热路径上**：
##    gpu_backend() 第一次调用会建 RenderingDevice 后端 + 编译 compute pipeline，
##    实测 5.5 ms（带窗口时 126 ms）—— 然后才发现 ENABLED 是 false，白做一场。
##    这 5.5 ms 只出现在**第一笔**上，于是第一笔和其余各笔手感不一样。
##    用这个函数在取后端**之前**判掉，一次性成本就不会落在第一笔上。
static var _gpu_enabled_cache := -1

static func _gpu_enabled() -> bool:
	if _gpu_enabled_cache < 0:
		var script = load("res://addons/pixel_destruction/gpu/gpu_destruction.gd")
		_gpu_enabled_cache = 0
		if script != null and script.get("ENABLED") != null and script.ENABLED:
			_gpu_enabled_cache = 1
	return _gpu_enabled_cache == 1


static func gpu_backend():
	if _gpu_backend_cache == null:
		var script = load("res://addons/pixel_destruction/gpu/gpu_destruction.gd")
		if script == null:
			return null
		_gpu_backend_cache = script.new()
		_gpu_backend_cache.setup()
	return _gpu_backend_cache


static func _pack_damage(d: Damage) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(8)
	out[0] = float(d.kind)
	out[1] = d.radius
	out[2] = d.a.x
	out[3] = d.a.y
	out[4] = d.b.x
	out[5] = d.b.y
	out[6] = d.half.x
	out[7] = d.half.y
	return out


## ---------- CPU 分量提取 ----------
## 刻意不建"每像素 -> 分量"的标签数组：576 个 chunk 各分配一个 64B PackedByteArray
## 的开销在 GDScript 里比泛洪本身还贵。接缝只需反查少量 bit，直接对掩码做位测试。
## 多线程阈值：chunk 太少时线程调度开销 > 收益
const PARALLEL_MIN_CHUNKS := 96
const MAX_COMPONENT_THREADS := 16
static var threads_enabled := true
static var last_component_threads := 1

static func _components_cpu(shape: PixelShape, keys: Array) -> Dictionary:
	var n := keys.size()
	if n == 0:
		return {"comp_masks": {}, "node_of": {}, "node_chunk": [], "node_mask": []}
	var nthreads := 1
	if threads_enabled and n >= PARALLEL_MIN_CHUNKS:
		nthreads = clampi(int(n / PARALLEL_MIN_CHUNKS), 2, MAX_COMPONENT_THREADS)
	last_component_threads = nthreads

	var slices: Array = []
	if nthreads <= 1:
		slices.append(_component_slice(shape, keys, 0, n))
	else:
		# 每个任务处理一段**连续**的 chunk，结果按段序合并 ——
		# 这样 node id 的分配顺序与串行完全一致，结果逐位可复现。
		var per := int(ceil(float(n) / float(nthreads)))
		var slots: Array = []
		slots.resize(nthreads)
		var mtx := Mutex.new()
		var worker := func(t: int) -> void:
			var lo := t * per
			var hi := mini(lo + per, n)
			if lo >= hi:
				return
			var local := _component_slice(shape, keys, lo, hi)
			mtx.lock()
			slots[t] = local
			mtx.unlock()
		# 保持低优先级（= 原始行为）。物理侧实测过高优先级反而更慢，
		# 见 pworld.parallel_high_priority 的注释；这条路径没有单独量过，不冒险改。
		var gid := WorkerThreadPool.add_group_task(worker, nthreads, -1, false, "pixel_components")
		WorkerThreadPool.wait_for_group_task_completion(gid)
		slices = slots

	# 合并（串行，但只是拼装，没有泛洪）
	var comp_masks := {}
	var node_of := {}
	var node_chunk: Array = []
	var node_mask: Array = []
	for si in slices.size():
		var local: Array = slices[si]
		if local == null:
			continue
		for ci in local.size():
			var entry: Array = local[ci]      # [chunk_key, comp_masks]
			var k: int = entry[0]
			var masks: Array = entry[1]
			var nodes: Array = []
			for m in masks:
				nodes.append(node_chunk.size())
				node_chunk.append(k)
				node_mask.append(m)
			comp_masks[k] = masks
			node_of[k] = nodes
	return {"comp_masks": comp_masks, "node_of": node_of, "node_chunk": node_chunk, "node_mask": node_mask}


## 处理 keys[lo, hi) 这一段，返回 [[chunk_key, [分量掩码...]], ...]
static func _component_slice(shape: PixelShape, keys: Array, lo: int, hi: int) -> Array:
	var out: Array = []
	for ci in range(lo, hi):
		var k: int = keys[ci]
		var c: PixelChunk = shape.chunks[k]
		var masks: Array = []
		if c.occ == -1:
			# 满 chunk：1 个分量，省掉泛洪与逐位扫描
			masks.append(-1)
		else:
			var remaining := c.occ
			while remaining != 0:
				var comp := Bits.flood(1 << Bits.first_bit_index(remaining), c.occ)
				masks.append(comp)
				remaining &= ~comp
		out.append([k, masks])
	return out


## ---------- 接缝归并 + 组装（CPU / GPU 两条路径共用） ----------
## 连通分量归组：返回 { 分组序号: { chunk_key: 掩码 } }。
##
## 这是 split() 内部用的那份计算 —— **不要另写一份**。连通性判定的细节
## （对角不算连接、跨 chunk 只查 +X/+Y 避免重复）一旦分叉，两边会给出不同的答案，
## 而这个项目在"同一规则写两处"上栽过太多次（坑 18/31/36）。
static func _group(shape: PixelShape, keys: Array, parts: Dictionary) -> Dictionary:
	var comp_masks: Dictionary = parts["comp_masks"]
	var node_of: Dictionary = parts["node_of"]
	var node_chunk: Array = parts["node_chunk"]
	var node_mask: Array = parts["node_mask"]
	var node_count := node_chunk.size()
	if node_count == 0:
		return {}

	# union-find（Array 在 GDScript 里按引用传递，PackedInt32Array 是值拷贝）
	var parent: Array = []
	parent.resize(node_count)
	for i in node_count:
		parent[i] = i

	# 只查 +X / +Y 两个正方向，避免重复与跨线程反向写
	var col0 := Bits.col_mask(0)
	var col7 := Bits.col_mask(7)
	var row0 := Bits.row_mask(0)
	var row7 := Bits.row_mask(7)
	for k: int in keys:
		if not shape.chunks.has(k):
			continue
		var c: PixelChunk = shape.chunks[k]
		var masks: Array = comp_masks[k]
		var nodes: Array = node_of[k]
		var cx := PixelShape.key_x(k)
		var cy := PixelShape.key_y(k)

		var rk := PixelShape.make_key(cx + 1, cy)
		if shape.chunks.has(rk):
			var rc: PixelChunk = shape.chunks[rk]
			var rmasks: Array = comp_masks[rk]
			var rnodes: Array = node_of[rk]
			var common := (c.occ & col7) & ((rc.occ & col0) << 7)
			# ⚠️⚠️ **两边都只有 1 个分量时，所有连通的 bit 连的都是同一对 node** ——
			#    逐 bit 跑一遍 union 是纯重复。实心地面每块都是 8 个水平 + 8 个垂直
			#    接缝 bit，1248 块 = 2 万次 union，实测 _group 27.1 ms 里九成在这里。
			#    多分量的块（少见）照旧逐 bit 跑，行为不变。
			if common != 0:
				if masks.size() == 1 and rmasks.size() == 1:
					_union(parent, nodes[0], rnodes[0])
				else:
					while common != 0:
						var bi := Bits.first_bit_index(common)
						_union(parent, nodes[_mask_index(masks, 1 << bi)], rnodes[_mask_index(rmasks, 1 << (bi - 7))])
						common &= common - 1

		var dk := PixelShape.make_key(cx, cy + 1)
		if shape.chunks.has(dk):
			var dc: PixelChunk = shape.chunks[dk]
			var dmasks: Array = comp_masks[dk]
			var dnodes: Array = node_of[dk]
			var common2 := (c.occ & row7) & ((dc.occ & row0) << 56)
			if common2 != 0:
				if masks.size() == 1 and dmasks.size() == 1:
					_union(parent, nodes[0], dnodes[0])
				else:
					while common2 != 0:
						var b2 := Bits.first_bit_index(common2)
						_union(parent, nodes[_mask_index(masks, 1 << b2)], dnodes[_mask_index(dmasks, 1 << (b2 - 56))])
						common2 &= common2 - 1

	# 按 root 归组并组装 Shape（同一 chunk 的多个 node 需要按位 OR）
	var groups := {}
	for i2 in node_count:
		var root := _find(parent, i2)
		var g = groups.get(root)
		if g == null:
			g = {}
			groups[root] = g
		var k2: int = node_chunk[i2]
		g[k2] = g.get(k2, 0) | int(node_mask[i2])
	return groups


## ---- 原生连通分量标注（GDExtension 的 PixelRaster op 3）----
##
## ⚠️ 为什么值得搬进原生：这条路径是**纯位运算 + 数组**（块内泛洪是 uint64 迭代、
##    接缝是 union-find、归组是拼装），没有任何 GDScript 特有的语义。
##    而参照实现 768x100（1248 块）要 13.5 ms —— 那还是**已经开了
##    WorkerThreadPool 并行之后**的数字。C++ 那边单线程，赢在每步没有函数调用开销。
##
## ⚠️⚠️ 结果必须与 _components_cpu + _group 的产物**逐位相同**：同样的分组、
##    同样的顺序、同样的掩码 —— **顺序不同也是不同**（它会进 Rapier 的碰撞体顺序）。
##    闸门 tests/validation_components_native.gd。
## ⚠️ 拿不到原生时**吵闹地**退回参照实现：连通分量标注**有**一条正确的慢路径，
##    所以这里只 push_warning / push_error，不 assert。
static var _raster: Object = null
static var _raster_checked := false
## 原生调用 / 回退计数。闸门靠它确认"真的走了原生"—— 否则"悄悄退回 GDScript"
## 会让逐位对拍变成同义反复（结果当然一样）。
static var native_calls := 0
static var native_fallbacks := 0
## 第一次调用给的结果段容量（按 (分组, 块) 对的个数算）。**这不是上限**：
## 放不下时原生只写头（8 字节）把 total_pairs 报回来，按它精确重开一次。
const NATIVE_PAIRS0 := 256


## 懒加载原生标注器。返回 null 表示扩展不可用（调用方退回参照实现）。
static func _ensure_raster() -> Object:
	if not _raster_checked:
		_raster_checked = true
		if ClassDB.class_exists("PixelRaster"):
			_raster = ClassDB.instantiate("PixelRaster")
			# ⚠️ 与 PixelRenderer / GreedyRects 同一套：GDExtension 实例化出来的
			#    RefCounted 引用计数是 2，多出来的那份没人还（Godot issue #111075）。
			if _raster != null and _raster.get_reference_count() > 1:
				_raster.unreference()
			# ⚠️ 老 DLL（还没编进 op 3）要能安全回退：has_method 是判"扩展是不是太旧"
			#    的正式手段 —— 否则每次调用都刷 "Nonexistent function"，
			#    而错误信息指不到"DLL 太旧"。
			if _raster != null and not _raster.has_method("components"):
				_raster = null
				push_warning("PixelRaster 扩展没有 components（DLL 太旧）—— 连通分量标注退回 GDScript。" +
					"跑 python tools/build_native.py 重编 fastphys.dll。")
		if _raster == null:
			push_warning("PixelRaster 扩展不可用 —— 连通分量标注退回 GDScript（慢一个量级）。" +
				"跑 python tools/build_native.py 重编 fastphys.dll。")
	return _raster


## 走一趟原生，返回**结果段本身**（不含 4 字节 written 头）。失败返回空数组。
static func _call_components(r: Object, cmds: PackedByteArray, cap: int) -> PackedByteArray:
	var inp := PackedByteArray()
	inp.resize(8)
	inp.encode_s32(0, cap)
	inp.encode_s32(4, cmds.size())
	inp.append_array(cmds)
	var tmpl := PackedByteArray()
	tmpl.resize(4 + cap)
	var res: PackedByteArray = r.components(inp, tmpl)
	if res.size() < 4 + cap:
		push_error("PixelRaster.components 返回长度不对（res=%d 期望=%d）—— 退回 GDScript 参照实现"
				% [res.size(), 4 + cap])
		return PackedByteArray()
	var written := res.decode_s32(0)
	if written < 0 or written > cap:
		push_error("PixelRaster.components written=%d 越界（cap=%d）—— 退回 GDScript" % [written, cap])
		return PackedByteArray()
	return res.slice(4, 4 + written)


## 原生连通分量标注。返回 null = 没走原生（调用方退回参照实现）。
## 协议见 gdext/fastphys.cpp 的 PixelRaster op 3。
static func _components_native(shape: PixelShape, keys: Array) -> Variant:
	var r := _ensure_raster()
	if r == null or keys.is_empty():
		return null
	var n := keys.size()
	var cmds := PackedByteArray()
	cmds.resize(5 + n * 16)
	cmds.encode_u8(0, 3)                 # op 3 = components
	cmds.encode_s32(1, n)
	var off := 5
	for k: int in keys:
		var c: PixelChunk = shape.chunks[k]
		# cx / cy 是 PixelShape.key_x / key_y 的内联（这个循环要跑 n 次）
		cmds.encode_s32(off, k >> 32)
		cmds.encode_s32(off + 4, (k << 32) >> 32)
		cmds.encode_s64(off + 8, c.occ)
		off += 16
	var body := _call_components(r, cmds, 8 + 16 * NATIVE_PAIRS0)
	if body.size() < 8:
		native_fallbacks += 1
		push_error("PixelRaster.components 结果太短（size=%d）—— 退回 GDScript 参照实现" % body.size())
		return null
	var n_groups := body.decode_s32(0)
	var total := body.decode_s32(4)
	if n_groups < 0 or total < 0:
		native_fallbacks += 1
		push_error("PixelRaster.components 头非法（groups=%d pairs=%d）—— 退回 GDScript"
				% [n_groups, total])
		return null
	# ⚠️ 头是 8 字节，但**每个分组还各有一个 i32 的块数** —— 漏掉它就会永远差
	#    4*n_groups 字节，症状是 written 恒比 cap 大 4，然后静默退回参照实现。
	#    （闸门"768x100 满实心"用例抓到的：written=18444 vs cap=18440。）
	var need := 8 + n_groups * 4 + total * 16
	if body.size() < need:
		# 结果段放不下：原生只写了头，按 need 精确重开一次（与 decompose 同一条约定）
		body = _call_components(r, cmds, need)
		if body.size() < need:
			native_fallbacks += 1
			push_error("PixelRaster.components 重开之后仍然不够（need=%d got=%d）—— 退回 GDScript"
					% [need, body.size()])
			return null
	# 组装：分组顺序 = 原生写出的顺序（= 节点首次出现的顺序），组内块顺序同理
	var out := {}
	var o := 8
	for gi in n_groups:
		var np := body.decode_s32(o)
		o += 4
		var g := {}
		for j in np:
			g[PixelShape.make_key(body.decode_s32(o), body.decode_s32(o + 4))] = body.decode_s64(o + 8)
			o += 16
		out[gi] = g
	native_calls += 1
	return out


## 连通分量标注（公共入口）。返回 { 分量序号: { chunk_key: 掩码 } }，序号重排为 0..n-1
## —— union-find 的 root 是内部编号，不适合外露。
##
## 游戏层拿它做"这条蓝线是哪一条""哪些体素属于同一个连通体"。
static func components(shape: PixelShape) -> Dictionary:
	var keys: Array = shape.chunks.keys()
	if keys.is_empty():
		return {}
	# 原生优先（拿不到就退回参照实现）—— 见 _components_native 的说明
	var nat = _components_native(shape, keys)
	if nat != null:
		return nat
	var groups := _group(shape, keys, _components_cpu(shape, keys))
	var out := {}
	var i := 0
	for root: int in groups:
		out[i] = groups[root]
		i += 1
	return out


static func _assemble(shape: PixelShape, keys: Array, parts: Dictionary, min_pixels: int,
		adopt := false) -> Array:
	var groups := _group(shape, keys, parts)


	# 快路径：只有一个连通分量 => 破坏没有把东西切开。
	# 直接返回原 Shape，省掉整趟逐像素拷贝（实测是最贵的一步）。
	if groups.size() == 1:
		return [shape] if shape.pixel_count() >= min_pixels else []

	var out: Array = []
	for root: int in groups:
		var g2: Dictionary = groups[root]
		var s := PixelShape.new()
		# ⚠️⚠️ **继承母形状的按块分解缓存**。分片保留局部坐标系与 chunk key，
		#    所以"块内像素没被这一笔碰过"的块，它的分解结果与母形状**完全相同** ——
		#    而按块缓存是**自校验**的（比对每块 64 个 chunk 的占用字），
		#    所以只有被伤害真正碰到的块会重算（切口穿过的那 2~4 个）。
		#    没有这一条：每个分片（**包括留在原 body 的那块**）都要从零分解，
		#    768x100 切成两半 = 两块各 ~10 个块 × ~0.5 ms = ~10 ms，
		#    而其中真正需要重算的只有切口那几个 —— 这就是"生成新实体那一下"的卡顿。
		#
		#    ⚠️ 块 key 列表必须按**本分片自己拥有的块**重建（从 g2 推），
		#    不能直接继承：继承过来会多出"别的部分的块"，它们在本分片里是空块，
		#    指纹一变就得跑一次 _decompose_block（每个空块 ~0.5 ms）—— 白付。
		#    末尾 sort 一次是为了让矩形输出顺序与母形状一致（确定性）。
		s._rect_blocks = shape._rect_blocks.duplicate()
		s._grid_sigs = shape._grid_sigs.duplicate()
		# ⚠️⚠️ 块 key 列表必须**去重**再排序。我第一版按"相邻 key 相同就跳过"去重，
		#    那是**错的**：chunk 的迭代顺序不保证按块聚簇（Dictionary.keys() 是内部
		#    顺序，分片的 chunks 还是按 split 的分组顺序插进去的）—— 同一个块会反复
		#    出现，于是同一个块的矩形被 append 多次。
		#    症状：768x100 切开后每片 380 个矩形里**每个像素被覆盖 2 次**
		#    （实测 33198 处 overlap）= 分片的碰撞体成对重叠 = 幻影接触。
		#    ⚠️ 8 条基准没抓到（它们不走 split），像素覆盖闸门也没抓到
		#    （它测的是独立形状，不是分片）—— 所以补了 tests/validation_fragment_cover.gd。
		var seen := {}
		for k3: int in g2:
			seen[((k3 >> 35) << 32) | (((k3 << 32) >> 35) & 0xFFFFFFFF)] = true
		s._grid_keys = seen.keys()
		s._grid_keys.sort()
		var total := 0
		for k3: int in g2:
			var mask: int = g2[k3]
			var n := Bits.popcount(mask)
			if n == 0:
				continue
			total += n
			var src_chunk: PixelChunk = shape.chunks[k3]
			# adopt 且这一块**整块属于本分片**（mask 覆盖了它的全部占用）-> 直接搬对象。
			# ⚠️ 判据是 mask == src_chunk.occ（不是 mask == -1）：占用不满的块只要
			#    "本分片拿走了它的全部像素"，搬对象同样是精确的。
			if adopt and mask == src_chunk.occ:
				s.chunks[k3] = src_chunk
				s.mark_dirty_key(k3)
				continue
			s.blit_mask_from(src_chunk, k3, mask)
		if total >= min_pixels and total > 0:
			out.append(s)
	return out


## 在分量掩码列表里找出包含指定 bit 的分量序号（通常只有 1~2 个分量）。
static func _mask_index(masks: Array, bit: int) -> int:
	for i in masks.size():
		if (int(masks[i]) & bit) != 0:
			return i
	return 0


static func _find(parent: Array, i: int) -> int:
	var root := i
	while parent[root] != root:
		root = parent[root]
	while parent[i] != root:
		var next: int = parent[i]
		parent[i] = root
		i = next
	return root


static func _union(parent: Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra == rb:
		return
	if ra < rb:
		parent[rb] = ra
	else:
		parent[ra] = rb


## 把 damage **命中的像素**收集成一个新形状（**不修改**原形状）。
##
## ⚠️ 与 apply_damage 互补：那个把命中的像素删掉，这个把它们捡起来。
##    配合 split 就能做到"被打掉的那一块变成碎片" —— **体素个数守恒**（Teardown 那样）。
##    笔刷擦除该继续用 apply_damage/fracture（擦掉就是擦掉），
##    撞击/切断该用 PWorld.detach（碎片留下来）。
##
## ⚠️⚠️ 实现上有个关键取巧：**不自己实现一遍伤害判据**。
##    先按伤害包围盒把像素原样拷进一个临时形状，再对**它**跑同一个 apply_damage ——
##    范围外的像素被剔掉，剩下的正好是命中的像素。
##    这样判据只有 make_keep_mask 一份（抄一份出来迟早会漂移），
##    而且不需要知道 chunk key 怎么算。
##    代价只是拷贝伤害包围盒那一小片像素。
static func extract_damage(shape: PixelShape, damage: Damage) -> PixelShape:
	var out := PixelShape.new()
	var b: Rect2 = damage.bounds()
	# 余量 1：伤害边界可能落在一个像素内部，取整会漏掉最外那一列/行。
	# ⚠️ 这个余量会让结果**可能多捡 1 个像素**（实测 40x40 挖 112 -> 捡到 113），
	#    所以**不能**拿它去和别处算的判据对总数 —— 见 PWorld.detach 的说明：
	#    detach 只用**这一个**集合去删，碎片和洞按构造完全一致，守恒是恒等式。
	# ⚠️ 也不要试图"按 chunk 对齐"来消除这个差：apply_damage 对**完全未被伤害覆盖**
	#    的 chunk 不做处理，对齐后反而会捡到一大堆（实测 464 个）。
	var x0 := floori(b.position.x) - 1
	var y0 := floori(b.position.y) - 1
	var x1 := ceili(b.position.x + b.size.x) + 1
	var y1 := ceili(b.position.y + b.size.y) + 1
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var m := shape.get_pixel(x, y)
			if m != 0:
				out.set_pixel(x, y, m)
	apply_damage(out, damage)
	return out
