extends RefCounted
## 一个"形状"= 一组局部 chunk 坐标下的 8x8 像素块。
## 对应 Teardown 的 Shape：体素块，属于某个 Body。
##
## 关键不变量（与 Teardown 官方规则一致）：
##   Shape 内部必须 4 邻域连通，不能有孤岛；出现孤岛时必须拆成多个 Shape。
##   对角接触不算连接。

const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")
const PixelChunk := preload("res://addons/pixel_destruction/core/pixel_chunk.gd")
# ⚠️ **绝对不要**在这里 preload destruction.gd。
# destruction.gd 已经 preload 了本文件，再加一条反向 preload 就成环 ——
# GDScript 运行时能容忍，但**编辑器的脚本扫描器会无限递归然后无声段错误**
# （实测：编辑器启动 17 秒后消失，退出码 0xC0000005，没有任何报错信息）。
# 需要 Destruction 的功能（连通分量）放在 ShapeOps 里，它同时依赖两边、不成环。

## local chunk 坐标 -> PixelChunk
var chunks: Dictionary = {}

## ---- 脏区域跟踪 ----
##
## 记录"本 tick 哪些 chunk 被写过"。元胞自动机这类逐体素模拟**不能每 tick 扫全部体素**
## （240 个碎片 × 16 像素 = 3840 个体素，全扫必崩），必须只处理变过的地方。
##
## ⚠️ 直接改 chunk.mat / chunk.occ（批量写入，性能需要）时**不会自动标记**，
##    那种路径要自己调 mark_dirty()。逐像素的 set_pixel / set_aux 会自动标记。
## **内容版本号**：任何一次像素改动都 +1。
##
## ## 为什么需要它（而不是靠调用方标记"脏了"）
##
## 渲染器曾经用 `_dirty.get(body.id, true)` + `erase()` 判断要不要重建贴图 ——
## 那是个**恒真**的表达式（默认 true，erase 之后又变回默认 true），
## 于是每帧都在重建 800x40 的贴图，掉帧"修"了个寂寞，而且不报任何错。
##
## 靠调用方调 mark_dirty() 也不行：全仓库根本没人调（只有定义）。
## 唯一可靠的做法是**让数据自己带着版本走** —— 谁改了内容谁就 +1，
## 读取方只比版本号，既不漏也不误。
var revision := 0

## **记录了块的**那部分版本号 —— 只有 mark_dirty* 会 bump 它，touch() 不会。
##
## ⚠️⚠️ 为什么必须区分这两个：
##    渲染器想"只重建脏块"，但脏块信息只在 mark_dirty* 路径上是完整的。
##    touch() 的语义是"内容变了，但**不知道哪里**"（原生破坏、split 换形状、
##    rebuild 的收尾都会调它）。
##
##    只比 revision 的话：fracture 先 mark_dirty_range（记了块），
##    紧接着 PBody.rebuild 又 touch()（没记块）—— 渲染器看到脏集合非空，
##    就**只重建那几块**，而 touch() 带来的改动（比如 split 把像素搬到了
##    碎片上、shape 对象整个被换掉）全被漏掉。
##    症状就是"擦出来的图形缺一块"。
##
##    判据：revision != range_revision  =>  有**未记录**的改动  =>  必须全量重建。
var range_revision := 0
# ⚠️ 这里曾经有 _rect_grid / _rect_grid_rev（GreedyRects 的网格缓存）。
#    **已删除 —— 实测无效**：脏集合太大（逐像素 mark_dirty，一个半径 6 的圆
#    就标了约 113 个 chunk），增量 9.13 ms vs 全量 9.36 ms，只快 1.0 倍。
#    它只增加复杂度和"缓存可能过期"的风险面，没有收益。
#    详见 GreedyRects._build_grid 顶部的墓碑注释。

var _dirty: Dictionary = {}

## ---- 位网格缓存（GreedyRects._build_grid 用）----
##
## ⚠️ 为什么要有它：网格构建的代价随**物体尺寸**走，而一笔擦除只动一小块 ——
##    2048x128 地面实测 **15.8 ms**，占整笔擦除（38.2 ms）的 41%，
##    而它跟"这一笔改了哪里"完全无关。
##
## ⚠️ 失效判据**不依赖任何脏标记**（见 GreedyRects._build_grid 的说明）：
##    按块比对该块 64 个 chunk 的占用字，指纹变了才重写那几行。
##    网格布局跟着 AABB 走，所以 AABB 一变就整块重建 —— 那正是"擦到边界"
##    那一笔，与优化前同价，不倒退。
var _grid_words := PackedInt64Array()
var _grid_wq := 0
var _grid_w := 0
var _grid_h := 0
var _grid_origin := Vector2i.ZERO
var _grid_sigs: Dictionary = {}
var _grid_keys: Array = []
var _grid_ready := false
## 块 key -> 该块的矩形列表（形状局部像素坐标）—— GreedyRects._block_rects 用。
## 与 _grid_words 的区别：那个是"全形状的位网格"，这个是"每块的分解结果"。
var _rect_blocks: Dictionary = {}


## 标记一个 chunk 为脏（chunk 坐标）。已经脏了就早退，热路径上只有一次查表。
func mark_dirty(cx: int, cy: int) -> void:
	revision += 1
	range_revision += 1
	_bounds_rev += 1          # 逐像素写入：不知道动了哪里 -> AABB 可能变
	var k := make_key(cx, cy)
	if not _dirty.has(k):
		_dirty[k] = true


## 内容变了，但**不是从 set_pixel 走的** —— 只 bump 版本号，不动块脏标记。
##
## ⚠️⚠️ 为什么必须有这个：
##
## 破坏（fracture / apply_damage）走的是**原生路径** —— C++ 里直接改块位图，
## **不经过 PixelShape.set_pixel**，而 mark_dirty() 是在 set_pixel 里调的。
## 于是 revision 不变，渲染器 sync() 一看
##     _bounds 没变 且 _rev 没变  ->  跳过贴图重建
## 表现就是：**右键擦掉了像素，画面上却还在** —— 直到生成新碎片（新 body id，
## _rev.get(新id, -1) != rev 必然成立）才刷新。
##
## 这和 P0-1（冲量回填在原生路径下空转）是同一个模式：
## **原生路径做了事，但没有通知 GDScript 侧。**
##
## 什么时候调：任何绕过 set_pixel 的批量修改之后（破坏、paint、换 shape……）。
## 它不是"标某块脏"，是"告诉渲染器这块内容变了，重建贴图"。
func touch() -> void:
	revision += 1
	_bounds_rev += 1          # 同上：不知道改了哪里，保守作废


func mark_dirty_key(k: int) -> void:
	revision += 1
	range_revision += 1
	_bounds_rev += 1
	if not _dirty.has(k):
		_dirty[k] = true


## 把一个**局部像素矩形**覆盖到的所有块标脏（revision 只自增一次）。
##
## ⚠️ 为什么需要它：破坏 / 擦除走的是**原生路径**（C++ 里直接改块位图），
##    不经过 set_pixel，所以拿不到"到底哪一块变了"。以前只能 touch() ——
##    那是"整块都脏"的信号，渲染器只能把**整个形状**的贴图重画一遍
##    （768x100 的地面实测约 44 ms/笔，这就是擦除卡顿的来源）。
##
##    而伤害本身**知道自己的局部包围盒**（Damage.bounds()），
##    顺手把覆盖到的块标出来，渲染器就能只重建那几块。
##
## ⚠️⚠️ **契约：rect 必须覆盖本次改动的全部像素**（可以更大，不能更小）。
##    这不只是"标脏"的契约 —— _aabb_survives() 也拿它当依据：
##    rect 严格落在 AABB 内部 => AABB 一定不变 => 保留缓存。
##    实际改动的像素一旦溢出 rect，AABB 缓存就会**静默**过期，
##    表现是形状与碰撞体错位（用户报过两次，两次都很像"只差一点点"）。
##
##    当前唯一的调用方 PWorld.fracture() 传的是 dmg_rect ——
##    damage.bounds() 向外取整 +1；而 make_keep_mask（CPU）和
##    destruction.glsl（GPU）都只在 damage.hits(像素中心) 为真时删除，
##    hits 的范围恰好就是 bounds()，所以"被删像素 ⊆ dmg_rect"是**可证的**。
##    两条路径都逐行核过，不是"看起来差不多"。
##
## 用法见 PWorld.fracture()。
func mark_dirty_range(rect: Rect2i) -> void:
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	revision += 1
	range_revision += 1
	# ⚠️ 这里**不能**无脑 bump：擦除的改动矩形绝大多数时候严格落在 AABB 内部，
	#    那种情况下 AABB 一定不变，而无脑 bump 会让 decompose() 白扫 1248 个
	#    chunk（实测 3.3 ms/笔）。见 _bounds_rev 的说明。
	if not _aabb_survives(rect):
		_bounds_rev += 1
	# >> 3 是"除以 8 并向下取整"，对负数也成立（算术右移）
	var cx0 := rect.position.x >> 3
	var cy0 := rect.position.y >> 3
	var cx1 := (rect.position.x + rect.size.x - 1) >> 3
	var cy1 := (rect.position.y + rect.size.y - 1) >> 3
	for cy in range(cy0, cy1 + 1):
		for cx in range(cx0, cx1 + 1):
			var k := make_key(cx, cy)
			if not _dirty.has(k):
				_dirty[k] = true


## 有没有待处理的脏块。世界层靠它快速跳过干净的形状。
func has_dirty() -> bool:
	return not _dirty.is_empty()


## 本 tick 被写过的 chunk key（PackedInt64Array，可直接拿去遍历）。
func dirty_chunks() -> PackedInt64Array:
	var out := PackedInt64Array()
	out.resize(_dirty.size())
	var i := 0
	for k: int in _dirty:
		out[i] = k
		i += 1
	return out


func clear_dirty() -> void:
	_dirty.clear()


## 读/写逐体素辅助表。引擎不解释语义（见 PixelChunk.aux 的说明）。
func get_aux(x: int, y: int) -> int:
	var cx := x >> 3
	var cy := y >> 3
	var c: PixelChunk = chunks.get(make_key(cx, cy))
	if c == null:
		return 0
	return c.aux[(y - (cy << 3)) * Bits.SIZE + (x - (cx << 3))]


func set_aux(x: int, y: int, v: int) -> void:
	var cx := x >> 3
	var cy := y >> 3
	var c: PixelChunk = chunks.get(make_key(cx, cy))
	if c == null:
		return
	c.aux[(y - (cy << 3)) * Bits.SIZE + (x - (cx << 3))] = v
	mark_dirty(cx, cy)

## 这个 Shape 的密度倍率（Teardown 的 SetShapeDensity / GetShapePalette 那一套）。
## 质量 = Σ(材质密度) * density_scale。默认 1.0，不影响既有行为。
var density_scale := 1.0
## 拥有它的刚体，由 PBody.rebuild 写入（Teardown 的 GetShapeBody）。
## ⚠️ 一个 Shape 只应属于一个刚体；如果同一个 Shape 被塞进两个刚体，
##    这里只会记住最后一个。
var owner_body = null

static func make_key(cx: int, cy: int) -> int:
	return (cx << 32) | (cy & 0xFFFFFFFF)

static func key_x(k: int) -> int:
	return k >> 32

static func key_y(k: int) -> int:
	return (k << 32) >> 32

func is_empty() -> bool:
	return chunks.is_empty()

func chunk_at(cx: int, cy: int) -> PixelChunk:
	return chunks.get(make_key(cx, cy))

func chunk_or_create(cx: int, cy: int) -> PixelChunk:
	var k := make_key(cx, cy)
	var c: PixelChunk = chunks.get(k)
	if c == null:
		c = PixelChunk.new()
		chunks[k] = c
	return c

func set_pixel(x: int, y: int, material: int) -> void:
	## 全局局部像素坐标（可为负）。
	var cx := x >> 3
	var cy := y >> 3
	chunk_or_create(cx, cy).set_pixel(x - (cx << 3), y - (cy << 3), material)
	mark_dirty(cx, cy)

## 只在像素原本为空时写入，返回是否真的新增（画笔需要统计"新增了多少像素"）。
func add_pixel(x: int, y: int, material: int) -> bool:
	var cx := x >> 3
	var cy := y >> 3
	var c := chunk_or_create(cx, cy)
	var lx := x - (cx << 3)
	var ly := y - (cy << 3)
	if (c.occ & Bits.bit(lx, ly)) != 0:
		return false
	c.set_pixel(lx, ly, material)
	mark_dirty(cx, cy)
	return true


func clear_pixel(x: int, y: int) -> void:
	var cx := x >> 3
	var cy := y >> 3
	var c: PixelChunk = chunks.get(make_key(cx, cy))
	if c != null:
		c.clear_pixel(x - (cx << 3), y - (cy << 3))
		mark_dirty(cx, cy)
		if c.is_empty():
			chunks.erase(make_key(cx, cy))

func pixel_count() -> int:
	var n := 0
	for c: PixelChunk in chunks.values():
		n += c.count()
	return n


## 读一个像素的**材质 id**（== 渲染调色板里的下标）。0 表示空。
## 坐标是 Shape 的局部像素坐标（可为负）。
func get_pixel(x: int, y: int) -> int:
	var cx := x >> 3
	var cy := y >> 3
	var c: PixelChunk = chunks.get(make_key(cx, cy))
	if c == null:
		return 0
	return c.get_material(x - (cx << 3), y - (cy << 3))


## 用矩形填一段像素。**material == 0 等价于清空**（与 get_pixel 的 0=空 一致）。
## rect 的右下是开区间，负坐标合法。
func fill_rect(rect: Rect2i, material: int) -> void:
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var y1 := rect.position.y + rect.size.y
	var x1 := rect.position.x + rect.size.x
	for y in range(rect.position.y, y1):
		for x in range(rect.position.x, x1):
			if material == 0:
				clear_pixel(x, y)
			else:
				set_pixel(x, y, material)


## 把整个形状的像素**线性平移**（局部空间里的平移，不动刚体）。
## 拖拽编辑、把碎片错位摆放时用得上。
##
## ⚠️ 单位是**像素**，不是 chunk。第一版直接把 dx 加在 chunk 坐标上，
## 结果 translate_pixels(0, -4) 实际位移了 -32（4 x 8）——
## 而且它不会报错，只会让"两个形状该相邻却不相邻"这类判定莫名其妙地失败。
func translate_pixels(dx: int, dy: int) -> void:
	if dx == 0 and dy == 0:
		return
	var out := {}
	for k: int in chunks:
		var c: PixelChunk = chunks[k]
		if c.occ == 0:
			continue
		var bx := key_x(k) << 3
		var by := key_y(k) << 3
		var bits := c.occ
		while bits != 0:
			var i := Bits.first_bit_index(bits)
			bits &= bits - 1
			var px := bx + (i & 7) + dx
			var py := by + (i >> 3) + dy
			var cx := px >> 3
			var cy := py >> 3
			var key := make_key(cx, cy)
			var dst: PixelChunk = out.get(key)
			if dst == null:
				dst = PixelChunk.new()
				out[key] = dst
			dst.set_pixel(px - (cx << 3), py - (cy << 3), c.mat[i])
	chunks = out
	# ⚠️ 墓碑：这里以前**什么都不 bump** —— chunks 整个被换掉，revision 却不动，
	#    于是 local_aabb() 的缓存键没变，返回的是平移**之前**的 AABB。
	#    当前仓库没有调用方（死代码），但雷先拆掉。
	#    平移只改位置不改形状，所以只 bump revision（渲染器必须全量重建），
	#    range_revision 不动 —— 它表示"脏块记录是完整的"，这里显然不是。
	revision += 1
	_bounds_rev += 1


## 材质直方图：material id -> 像素数（不含 0）。
## 质量估算、碎片统计、按材质计分都用它。
func count_by_material() -> Dictionary:
	var out := {}
	for c: PixelChunk in chunks.values():
		var m := c.occ
		while m != 0:
			var i := Bits.first_bit_index(m)
			var id := c.mat[i]
			out[id] = int(out.get(id, 0)) + 1
			m &= m - 1
	return out


## 把一种材质整体换成另一种（"烧焦/结冰/腐蚀"这类整块改色）。返回改动的像素数。
func remap_material(from_id: int, to_id: int) -> int:
	var n := 0
	for c: PixelChunk in chunks.values():
		var m := c.occ
		while m != 0:
			var i := Bits.first_bit_index(m)
			if c.mat[i] == from_id:
				c.mat[i] = to_id
				n += 1
			m &= m - 1
	return n

## 缓存的像素级 AABB + 它对应的 revision。
##
## ⚠️⚠️ **必须缓存。** 本函数要遍历**所有 chunk**（每个 8x8），
##    768x100 的地面是 1248 个 chunk —— 实测 **4.48 ms/次**。
##    而渲染器 sync() 的**脏检查**每次都要调它，于是"什么都没变"
##    也要付这个钱。
##
##    这就是"擦除地面很卡"的真正原因：擦一笔 = 挖像素(~58 ms) +
##    sync(地面)(~51 ms)，而后者几乎全是这个 AABB 重算。
##    Rapier 那边（把 81 个矩形推给物理）只要 0.17 ms，完全不是瓶颈。
##
var _aabb_cache := Rect2i()
var _aabb_rev := -1

## 质量属性的**逐块几何缓存**（键 = 块键，值 = {n, sx, sy, ii, v}）。
##
## ⚠️ 只存**与密度/摩擦无关**的几何量（像素数、一阶矩、绕原点的极惯性矩），
##    材质 v 单独存着以便查密度。所以密度表改了**不需要失效** —— 密度在合并时现查。
##
## ⚠️ 失效策略是"**调用方声明**"：MassProps.compute 传了 changed_keys 才复用，
##    没传就把整个缓存清掉（"我不知道改了哪些块" -> 不能复用）。这样任何
##    没接入的改动路径（set_pixel / 笔刷 / 原生破坏）都只会退回全量，**不会读到脏值**。
var _mp_cache := {}

## AABB 缓存的版本号 —— **只在 AABB 可能改变时才 +1**。
##
## ⚠️⚠️ 为什么不用 revision 当键（这里踩过）：
##    擦除走 mark_dirty_range()，它原本无脑 bump 了 revision，于是**每一笔擦除**
##    都把 AABB 缓存打掉 —— 而 decompose() 第一件事就是调 local_aabb()，
##    等于每笔白扫 1248 个 chunk（768x100 地面实测 3.3 ms）。
##
##    可是擦除**不可能**改变 AABB：AABB 的四个极值像素一定落在改动矩形之外。
##    判据因此是「改动矩形是否严格落在当前 AABB 内部」：
##      严格在内 -> AABB 一定不变   -> 保留缓存
##      碰到边界 -> 可能缩（擦）也可能涨（画）-> 作废重算
##
##    这正是 bench_erase_interior 量到的"内部擦除 AABB 不变、边缘擦除 AABB 变"，
##    只不过以前是**事后**才发现，现在是**事前**就判定。
##
##    touch() / mark_dirty() / mark_dirty_key() 不知道改了哪里，一律 +1（保守）。
var _bounds_rev := 0


func local_aabb() -> Rect2i:
	## 返回像素级 AABB（左上闭、右下开区间），空形状返回 Rect2i()。
	if _aabb_rev == _bounds_rev:
		return _aabb_cache
	var min_x := 1 << 30
	var min_y := 1 << 30
	var max_x := -(1 << 30)
	var max_y := -(1 << 30)
	for k: int in chunks:
		var c: PixelChunk = chunks[k]
		if c.occ == 0:
			continue
		var bx := key_x(k) << 3
		var by := key_y(k) << 3
		for y in 8:
			var row := Bits.row_bits(c.occ, y)
			if row == 0:
				continue
			var lo := Bits.first_bit_index(row)
			var hi := 8
			while hi > lo and ((row >> (hi - 1)) & 1) == 0:
				hi -= 1
			min_x = mini(min_x, bx + lo)
			max_x = maxi(max_x, bx + hi)
			min_y = mini(min_y, by + y)
			max_y = maxi(max_y, by + y + 1)
	_aabb_rev = _bounds_rev
	if max_x <= min_x:
		_aabb_cache = Rect2i()
	else:
		_aabb_cache = Rect2i(min_x, min_y, max_x - min_x, max_y - min_y)
	return _aabb_cache


## 这次改动**是否可能**改变 AABB。只有缓存本身是新鲜的，才敢回答"不会变"。
##
## 严格在内（四条边一条都不碰）才返回 true：AABB 的四个极值像素都落在
## 矩形之外，既删不掉也盖不住，四个边界值必然不变。
func _aabb_survives(rect: Rect2i) -> bool:
	if _aabb_rev != _bounds_rev:
		return false          # 缓存本来就过期了，别装作知道
	var ax := _aabb_cache.position.x
	var ay := _aabb_cache.position.y
	return (rect.position.x > ax
			and rect.position.y > ay
			and rect.position.x + rect.size.x < ax + _aabb_cache.size.x
			and rect.position.y + rect.size.y < ay + _aabb_cache.size.y)


func blit_mask_from(src: PixelChunk, key: int, mask: int) -> void:
	## split 用：把 src 里 mask 内的像素按 key 复制进本 Shape。
	#
	# ⚠️⚠️ 整块拷贝（mask == -1，split 时的绝大多数）走**零拷贝共享**：
	#    PixelChunk.new() 会先分配两张 64 字节的表，而 blit_into 的整块路径又会用
	#    duplicate() 把它们覆盖掉 —— 每块 4 次分配，这是 _assemble 拷贝 8.5 ms 的主因。
	#    PackedByteArray 是**写时复制**：直接赋值只是共享缓冲区，任何一方之后写入
	#    才会真的复制。所以这里跳过分配，直接共享母体的两张表。
	#    ⚠️ 共享是安全的：无论走 mat[i]=v（GDScript 会 copy-modify-assign）
	#    还是取局部再写回，都会触发 COW 复制，母体那边不会被改到。
	#    实测 _assemble 的拷贝 8.5 ms -> ~3 ms。
	if mask == -1 and not chunks.has(key):
		var nc := PixelChunk.new(true)
		nc.occ = src.occ
		nc.mat = src.mat
		nc.aux = src.aux
		chunks[key] = nc
		mark_dirty_key(key)
		return
	var target := chunk_or_create(key_x(key), key_y(key))
	src.blit_into(target, mask)
	mark_dirty_key(key)


## ---- 体素遍历原语 ----
##
## 引擎负责"怎么走"，**规则由游戏层给**（谓词 + 访问者都是 Callable）。
## 这样"蓝线传信号""绿线生长""红色蔓延"能共用同一套遍历，
## 而引擎完全不知道这些概念。

const OFFSETS_4: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const OFFSETS_8: Array = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]


## 邻域像素坐标。⚠️ 每次调用都会新建数组 ——
## 逐像素的热循环里请直接内联 OFFSETS_4/OFFSETS_8，别调这个。
func neighbors(x: int, y: int, diagonal := false) -> Array:
	var out: Array = []
	for off: Vector2i in (OFFSETS_8 if diagonal else OFFSETS_4):
		out.append(Vector2i(x + off.x, y + off.y))
	return out


## 沿连通体素做 BFS。**谓词和访问者都由游戏层提供** —— 引擎只负责"怎么走"。
##
##   matches(x, y, material, dist) -> bool   能不能踏进这个像素
##   visit(x, y, material, dist) -> bool     访问它；**返回 false 就停止整趟遍历**
##
## 返回访问到的像素数。起点为空、或被 matches 拒绝时返回 0。
##
## 典型用法：
##   蓝线传信号 —— visit 里按 dist 衰减，matches 里限材质
##   绿线生长   —— visit 里改 aux/mat（改完记得 mark_dirty）
##   红色蔓延   —— visit 里收集待爆体素，遍历结束后统一处理
##
## ⚠️ **GDScript 的 lambda 按值捕获局部变量** —— visit 里改一个局部标量
##    （比如 `var count := 0` 然后 count += 1）**不会传出去**。
##    要累积结果请用 Array / Dictionary / 对象成员（引用类型）。
##    实测症状：visit 明明被调用了，外面的计数还是 0。
func flood(from: Vector2i, matches: Callable, visit: Callable, diagonal := false) -> int:
	var m0 := get_pixel(from.x, from.y)
	if m0 == 0:
		return 0
	if matches.is_valid() and not matches.call(from.x, from.y, m0, 0):
		return 0
	var seen := {}
	seen[make_key(from.x, from.y)] = true
	var queue: Array = [from]
	var dists: Array = [0]
	var head := 0
	var count := 0
	var offsets: Array = OFFSETS_8 if diagonal else OFFSETS_4
	while head < queue.size():
		var p: Vector2i = queue[head]
		var d: int = dists[head]
		head += 1
		count += 1
		if visit.is_valid() and not visit.call(p.x, p.y, get_pixel(p.x, p.y), d):
			return count
		for off: Vector2i in offsets:
			var nx := p.x + off.x
			var ny := p.y + off.y
			var k := make_key(nx, ny)
			if seen.has(k):
				continue
			var m := get_pixel(nx, ny)
			if m == 0:
				continue
			if matches.is_valid() and not matches.call(nx, ny, m, d + 1):
				continue
			seen[k] = true
			queue.append(Vector2i(nx, ny))
			dists.append(d + 1)
	return count
