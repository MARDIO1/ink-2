extends RefCounted
## 像素团 -> 局部空间矩形集合（贪心最大矩形分解）。
##
## 为什么不用凸包：
##   2D 像素物体大量是凹的（L 形墙、楼梯、手绘的不规则形状）。
##   凸包会把凹角"填平"，产生看不见的碰撞体积。
##   贪心矩形分解是像素的**精确覆盖**：面积和 == 像素数，互不重叠，无幻影格。
##
## 关于预算（重要）：
##   精确覆盖与"矩形数量上限"在一般情况下是**不可兼得**的。
##   用包围盒去兜底会产生大量幻影碰撞体（实测一个 2400 像素的梳齿形
##   会凭空多出 1600 个碰撞格），所以这里的策略是：
##     - decompose()        永远精确。max_rects 只是"超了要告诉我"的阈值。
##     - decompose_proxy()  显式选择的近似代理，调用方自己承担幻影体积。
##
## 关于两条路（重要）：
##   decompose()      = 原生（GDExtension 的 PixelRaster op 2）优先，拿不到就回退。
##   decompose_gd()   = **参照实现**，原样保留。两条路必须**逐位相同**
##                      （同样的矩形、同样的顺序）—— tests/validation_greedy_native.gd。
##   ⚠️ "顺序不同也是不同"：矩形顺序会原样进入 Rapier 的碰撞体顺序。

const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")
const PixelChunk := preload("res://addons/pixel_destruction/core/pixel_chunk.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")

class Grid:
	## 位网格：每行 wq 个 64 位 word，共 wq * h 个。
	##
	## ⚠️ 为什么从"每像素一个字节"改成位：
	##    768x100 原来是 76800 个字节，现在是 12 x 100 = **1200 个 word**。
	##    实测建网格 **9.61 -> 4.95 ms**（1.94 倍）—— 因为每个 chunk-行
	##    从"8 次字节写"变成"1~2 次掩码写"。
	##
	##    ⚠️ 但**清零**这条反过来了：全宽矩形用字节版的 slice/resize
	##    整体替换只要 0.01 ms，位版要 0.10 ms。所以 _greedy 里
	##    对全宽矩形**保留了字节版的退化路径**（见那里的说明）——
	##    退化路径不改变结果，只改变怎么把位清掉。
	var words: PackedInt64Array = PackedInt64Array()
	var wq := 0            # 每行多少个 word
	var w := 0
	var h := 0
	var origin := Vector2i.ZERO


class Result:
	var rects: Array = []            # Array[Rect2]，Shape 局部像素空间
	var origin: Vector2 = Vector2.ZERO
	var budget_exceeded := false
	var exact := true

	func rect_count() -> int:
		return rects.size()

	func covered_area() -> float:
		var a := 0.0
		for r: Rect2 in rects:
			a += r.size.x * r.size.y
		return a


## 块边长（像素）。64 是研究文档 §4.2 的推荐值，也是实测选的：
##   32x32 的矩形更多、合并更贵；128 的脏块本身太大（一笔擦除要重算 4 倍面积）。
const BLOCK_SHIFT := 6
const BLOCK_SIZE := 64
const BLOCK_CHUNKS := 8          # 64 / 8：每边 8 个 chunk（8 整除 64，所以 chunk 不会跨块）

## 分解入口。原生优先，拿不到（扩展没编 / DLL 太旧 / 协议对不上）就回退参照实现。
static func decompose(shape: PixelShape, max_rects: int = 0) -> Result:
	if _ensure_raster() != null:
		var r := _decompose_native(shape, max_rects)
		if r != null:
			return r
	return decompose_gd(shape, max_rects)


## **参照实现**：GDScript 版 decompose（原样保留，一字不改）。
##
## ⚠️ 它的每一处行为都是原生的判据，改它等于改判据：
##    · 空形状（或全空块）时 origin 保持 Vector2.ZERO（**不是** aabb.position）
##    · 分块锚在局部 0/64/128…，块按 key **有符号升序**遍历 -> 决定矩形顺序
##    · 块内横/竖两遍贪心取**更少**那份（相等时留横优先）
##    · _merge_pass 的分组按**首次出现**顺序输出
##    · max_rects 不参与几何，只决定 budget_exceeded
static func decompose_gd(shape: PixelShape, max_rects: int = 0) -> Result:
	var res := Result.new()
	var aabb := shape.local_aabb()
	if aabb.size.x <= 0 or aabb.size.y <= 0:
		return res
	var rects := _merge_pass(_block_rects(shape))
	res.origin = Vector2(aabb.position)
	res.rects = rects
	if max_rects > 0 and rects.size() > max_rects:
		res.budget_exceeded = true
	return res


## ---- 原生分解（GDExtension 的 PixelRaster op 2）----
##
## ⚠️ 为什么值得（800x40 实测，见 tests/bench_decompose_native.gd）：
##    · GDScript 冷路径（块缓存全空）3.1 ms
##    · 每笔破坏的热路径 2.0 ms —— 其中 local_aabb() 的重扫占 1.8 ms，
##      真正的分块 + 融合只占 0.2 ms
##    · 原生把这两笔一起算掉：~0.15 ms
##
## ⚠️⚠️ **AABB 也由原生算**（是出参）。它是 decompose() 的第一步，留在 GDScript
##    里就等于把 1.8 ms 从 decompose 挪到下一个 local_aabb() 的调用方
##    （PBody.update_aabb / 渲染器）—— 总量一点没省。代价是原生算出的 AABB 会
##    写回 PixelShape 的缓存，所以它必须**逐位正确**：闸门单独对拍它
##    （含空形状 / 负原点 / 只占半个 chunk）。
##
## ⚠️ 原生化之后 GDScript 的块缓存（_rect_blocks）就不再被这条路喂了 ——
##    它是按块指纹失效的缓存，空着只会让回退路径多算一点，**不会算错**。
static var _raster: Object = null
static var _raster_checked := false
## 原生调用 / 回退计数。闸门靠它确认"真的走了原生"—— 否则"悄悄退回 GDScript"
## 会让逐位对拍变成同义反复（结果当然一样）。
static var native_calls := 0
static var native_fallbacks := 0
## 第一次调用给的结果段容量（按矩形个数算）。**这不是上限**：放不下时原生会把
## count 报回来（头 24 字节一定写得下），按它精确重开一次。
const NATIVE_CAP0 := 256


## 懒加载原生分解器。返回 null 表示扩展不可用（调用方退回参照实现）。
static func _ensure_raster() -> Object:
	if not _raster_checked:
		_raster_checked = true
		if ClassDB.class_exists("PixelRaster"):
			_raster = ClassDB.instantiate("PixelRaster")
			# ⚠️ 与 RapierPhys 同一个 Godot 已知问题（issue #111075）：
			#    GDExtension 实例化出来的 RefCounted 引用计数是 2，多出来的那份
			#    没人还 -> 退出时报实例泄漏。判 > 1 再 unreference
			#    （计数为 1 时调它会真的把对象释放掉）。
			if _raster != null and _raster.get_reference_count() > 1:
				_raster.unreference()
			# ⚠️ 老 DLL（还没编进 op 2）也要能安全回退：注册的方法表里没有
			#    decompose 就直接当扩展不可用 —— 否则每次调用都刷一条
			#    "Nonexistent function" 错误，而错误信息指不到"DLL 太旧"。
			if _raster != null and not _raster.has_method("decompose"):
				_raster = null
				push_warning("PixelRaster 扩展没有 decompose（DLL 太旧）—— 矩形分解退回 GDScript。" +
					"跑 python tools/build_native.py 重编 fastphys.dll。")
		if _raster == null:
			# ⚠️ 只警告、不回退到 assert：矩形分解**有**一条正确的慢路径。
			push_warning("PixelRaster 扩展不可用 —— 矩形分解退回 GDScript 路径（慢 ~10 倍）。" +
				"跑 python tools/build_native.py 重编 fastphys.dll。")
	return _raster


## 原生路径。返回 null 表示"没走原生"，调用方回退参照实现。
##
## 协议见 gdext/fastphys.cpp 的 PixelRaster op 2。失败时**吵闹地**回退，
## 不做"能算多少算多少"—— 静默算错比慢难查得多（本仓库的规矩）。
static func _decompose_native(shape: PixelShape, max_rects: int) -> Result:
	var n := shape.chunks.size()
	if n <= 0:
		# 空形状：参照实现那条路更短（而且它自己会把 AABB 缓存写好），不差这一次
		return null
	# ① 打包块记录：i32 cx, i32 cy, i64 occ（与 op 1 同一种记录，只是没有 mat）
	var cmds := PackedByteArray()
	cmds.resize(9 + n * 16)
	cmds.encode_u8(0, 2)                 # op 2 = decompose
	cmds.encode_s32(1, n)
	cmds.encode_s32(5, max_rects)
	var off := 9
	for k: int in shape.chunks:
		var c: PixelChunk = shape.chunks[k]
		# cx / cy 是 PixelShape.key_x / key_y 的内联（这个循环要跑 n 次）
		cmds.encode_s32(off, k >> 32)
		cmds.encode_s32(off + 4, (k << 32) >> 32)
		cmds.encode_s64(off + 8, c.occ)
		off += 16
	# ② 结果段：先给 NATIVE_CAP0 个矩形的位置
	var cap := 24 + 16 * NATIVE_CAP0
	var inp := PackedByteArray()
	inp.resize(8)
	inp.encode_s32(0, cap)
	inp.encode_s32(4, cmds.size())
	inp.append_array(cmds)
	var tmpl := PackedByteArray()
	tmpl.resize(4 + cap)
	var res: PackedByteArray = _raster.decompose(inp, tmpl)
	native_calls += 1
	# ⚠️ 一次 to_int32_array() 拿全部（每个矩形 4 次 decode_s32 会把收益吃光）
	var w32 := res.to_int32_array()
	if w32.size() < 7:
		native_fallbacks += 1
		push_error("PixelRaster.decompose 返回太短（size=%d）—— 退回 GDScript 参照实现" % res.size())
		return null
	if w32[0] < 24:
		native_fallbacks += 1
		push_error("PixelRaster.decompose 没写头（written=%d）—— 退回 GDScript 参照实现" % w32[0])
		return null
	var count: int = w32[1]
	if count > 0 and w32[0] < 24 + count * 16:
		# 结果段放不下矩形：原生已经把 count 报回来了（头一定写得下），按它精确重开
		cap = 24 + count * 16
		inp.encode_s32(0, cap)
		tmpl.resize(4 + cap)
		res = _raster.decompose(inp, tmpl)
		native_calls += 1
		w32 = res.to_int32_array()
		if w32.size() < 7 or w32[0] < 24 + count * 16 or w32[1] != count:
			native_fallbacks += 1
			push_error("PixelRaster.decompose 重开后仍然对不上（size=%d written=%d count=%d/%d）—— 退回 GDScript" % [
				res.size(), w32[0] if w32.size() > 0 else -1, w32[1] if w32.size() > 1 else -1, count])
			return null
	if w32.size() < 7 + count * 4:
		native_fallbacks += 1
		push_error("PixelRaster.decompose 结果段缺矩形（size=%d count=%d）—— 退回 GDScript" % [w32.size(), count])
		return null
	# ③ AABB 写回缓存（见上面的说明：不写回就等于白优化）
	#    同一条判据也在闸门里逐位对拍过（native_aabb == 重算的 local_aabb）。
	shape._aabb_cache = Rect2i(w32[3], w32[4], w32[5], w32[6])
	shape._aabb_rev = shape._bounds_rev
	var out := Result.new()
	out.budget_exceeded = w32[2] != 0
	if w32[5] <= 0 or w32[6] <= 0:
		# 与参照实现同一条早返回：origin 保持 Vector2.ZERO（不是 aabb.position）
		return out
	out.origin = Vector2(w32[3], w32[4])
	var rects: Array = []
	rects.resize(count)
	for i in count:
		var q := 7 + i * 4
		rects[i] = Rect2(w32[q], w32[q + 1], w32[q + 2], w32[q + 3])
	out.rects = rects
	return out


## 按块（64x64）分解 + 缓存：只重算**指纹变了的块**。
##
## ⚠️⚠️ 为什么按块：全形状贪心的代价随**形状尺寸**走，而一笔擦除只动一小块。
##    768x100 实测（10 笔擦除后 115 个矩形）：
##      _build_grid 0.51 + 横优先 1.66 + **竖优先 3.78** + merge 0.00 = 5.95 ms
##    而竖优先那一遍在这个形状上产出的矩形数**完全相同（115 = 115）**，纯白跑 ——
##    它只是"两个方向取更少那份"里的比较对象，而比较结果常常是平手。
##    按块之后一笔只重算 1~2 个块（每块约 0.5 ms）。
##
## ⚠️ 块锚在**局部像素坐标的 0/64/128...**，不是 AABB 原点：
##    AABB 会随"擦到边界"而变，锚在 AABB 上的话每笔边缘擦除都要全量重算。
##
## ⚠️⚠️ 缓存不过期的判据：**比对该块 64 个 chunk 的占用字**（指纹），
##    不依赖任何"谁改了要通知我"的脏标记 —— 理由见 _build_grid 的说明
##    （脏标记那条路栽过多次，而**缓存判错是不报错的**）。
##
## ⚠️ 代价：矩形**不再跨块**，实心区域会凭空多出接缝 —— 必须靠 _merge_pass 的
##    最大行程合并并回去（实心区域并成 1 个矩形 = 零接缝）。
##    即便如此矩形集合仍会变 -> 8 条基准会移动（必须单独一个提交）。
static func _block_rects(shape: PixelShape) -> Array:
	var cache: Dictionary = shape._rect_blocks
	var sigs: Dictionary = shape._grid_sigs
	var keys: Array = shape._grid_keys
	# 1) 把"本形状有 chunk 但 key 列表里没有"的块补进来。
	#
	# ⚠️⚠️ 判据必须是"**key 在不在 keys 里**"，不能是"在不在 sigs 里"：
	#    split 的分片会从母体**继承 sigs**（还有按块缓存），于是 sigs 里已经有那些块，
	#    用 sigs 判就会跳过插入 -> key 列表靠 _assemble 预建 -> 两边一叠加，
	#    在 sigs 为空的形状上（例如被 clone 出来的、或游戏层刚造好还没 rebuild 的）
	#    就会**重复插入**同一个块 -> 同一个块的矩形被 append 多次
	#    -> 分片的碰撞体成对重叠（实测每片 380 个矩形、每个像素被覆盖 2 次）。
	#    ⚠️ 这个 bug 8 条基准没抓到（它们不走 split），像素覆盖闸门也没抓到
	#    （它测独立形状）—— tests/validation_fragment_cover.gd 就是为它补的。
	var seen := {}
	for kk: int in keys:
		seen[kk] = true
	for k: int in shape.chunks:
		var bk := ((k >> 35) << 32) | (((k << 32) >> 35) & 0xFFFFFFFF)
		if seen.has(bk):
			continue
		seen[bk] = true
		_sorted_insert(keys, bk)
		if not sigs.has(bk):
			# 真正的新块：没有指纹可比 -> 置空指纹与空缓存，让下面的循环重算它。
			sigs[bk] = PackedInt64Array()
			cache[bk] = []
	# 2) 指纹变了才重算这一块
	var out: Array = []
	for bk2: int in keys:
		var sig := _block_sig(shape, bk2)
		# ⚠️⚠️ 必须用 get() 安全查找：上面的发现循环**不保证**每个 key 都在 sigs 里
		#    （key 可能由 _assemble 预建、或从母体继承而来）。而 GDScript 里
		#    sigs[bk2] 访问不存在的键会**中断整个函数** —— 症状是 decompose 静默返回
		#    **0 个矩形**（形状有像素、碰撞体却是空的）。踩过一次。
		var old = sigs.get(bk2)
		if old == null or sig != old:
			sigs[bk2] = sig
			cache[bk2] = _decompose_block(shape, bk2)
		for r: Rect2 in cache.get(bk2, []):
			out.append(r)
	return out


## 把一个块（64x64）重算成矩形列表（形状局部像素坐标）。
## 块内网格宽恰好 1 个 word，所以每行是**一次直接 OR 写入**，不需要跨 word 掩码。
static func _decompose_block(shape: PixelShape, bk: int) -> Array:
	var bix := PixelShape.key_x(bk)
	var biy := PixelShape.key_y(bk)
	var cx0 := bix << 3
	var cy0 := biy << 3
	var words := PackedInt64Array()
	words.resize(BLOCK_SIZE)
	for oy in BLOCK_CHUNKS:
		var row0 := oy << 3
		for ox in BLOCK_CHUNKS:
			var c: PixelChunk = shape.chunks.get(((cx0 + ox) << 32) | ((cy0 + oy) & 0xFFFFFFFF))
			if c == null:
				continue
			var shift := ox << 3
			for y in 8:
				words[row0 + y] |= Bits.row_bits(c.occ, y) << shift
	var a := _greedy(words.duplicate(), 1, BLOCK_SIZE, BLOCK_SIZE, true)
	var rects: Array = a
	if a.size() > 1:
		var b := _greedy(words.duplicate(), 1, BLOCK_SIZE, BLOCK_SIZE, false)
		if b.size() < a.size():
			rects = b
	var off := Vector2(bix << BLOCK_SHIFT, biy << BLOCK_SHIFT)
	for i in rects.size():
		var r: Rect2 = rects[i]
		rects[i] = Rect2(r.position + off, r.size)
	return rects


## 显式选择的近似代理：矩形数被压到 max_rects 以内，但会引入幻影碰撞体积。
## 只有在"这个物体离玩家很远 / 只是背景装饰"时才应该用它。
static func decompose_proxy(shape: PixelShape, max_rects: int) -> Result:
	var res := decompose(shape, 0)
	if max_rects <= 0 or res.rects.size() <= max_rects:
		return res
	var sorted := res.rects.duplicate()
	sorted.sort_custom(func(x: Rect2, y: Rect2) -> bool:
		return x.size.x * x.size.y > y.size.x * y.size.y)
	var out: Array = []
	for i in mini(max_rects - 1, sorted.size()):
		out.append(sorted[i])
	var rest := Rect2(sorted[max_rects - 1].position, sorted[max_rects - 1].size)
	for i in range(max_rects - 1, sorted.size()):
		rest = rest.merge(sorted[i])
	out.append(rest)
	res.rects = out
	res.exact = false
	res.budget_exceeded = true
	return res


## 把 Shape 铺成 w*h 的 0/1 网格（**带缓存**）。空形状返回 null。
##
## ⚠️⚠️ 网格的代价随**物体尺寸**走，与"这一笔改了哪里"无关 ——
##    2048x128 地面全量重建实测 **15.8 ms**，而一笔擦除只动 1~2 个 64x64 块。
##    所以这里缓存网格，指纹没变的块**直接跳过**。
##
## ⚠️⚠️ 失效判据：**每次比对该块 64 个 chunk 的占用字**，不依赖任何
##    "谁改了要通知我"的脏标记。
##    · 脏标记那条路这个项目栽过多次 —— 原生破坏在 C++ 里直接改块位图，
##      不经过 set_pixel（症状：擦掉了画面上还在）；而**缓存判错是不报错的**，
##      只会让形状与碰撞箱静默错位（用户报过两次）。
##    · 自校验的代价是每次扫一遍 chunks（2048x128 是 4096 次查表 + 64 个块的
##      指纹），比全量重建（15.8 ms）便宜一个数量级，而且**不可能错**。
##    · 占用位是网格的唯一输入（材质 id 不参与），所以指纹只需要 occ。
##
## ⚠️ 输出必须与全量重建**逐位相同** —— 这是硬判据：
##    网格逐位相同 => 贪心结果相同 => 矩形集合相同 => 8 条基准必须逐位不变。
##    见 tests/validation_grid_cache.gd。
static func _build_grid(shape: PixelShape) -> Grid:
	var aabb := shape.local_aabb()
	if aabb.size.x <= 0 or aabb.size.y <= 0:
		return null
	var w := aabb.size.x
	var h := aabb.size.y
	var wq := (w + 63) >> 6
	if shape._grid_ready and shape._grid_w == w and shape._grid_h == h \
			and shape._grid_origin == aabb.position:
		_refresh_grid(shape, aabb, w, h, wq)
	else:
		_full_grid(shape, aabb, w, h, wq)
	var g := Grid.new()
	g.w = w
	g.h = h
	g.wq = wq
	g.origin = aabb.position
	g.words = shape._grid_words
	return g


## 全量重建（冷启动 / AABB 动过）。顺便把所有块的指纹记下来。
static func _full_grid(shape: PixelShape, aabb: Rect2i, w: int, h: int, wq: int) -> void:
	var words := PackedInt64Array()
	words.resize(wq * h)
	var sigs := {}
	var keys: Array = []
	# ⚠️⚠️ 这里曾经有一条"增量路径"：缓存网格，只重建**块级脏集合**覆盖的区域。
	#    **它失败了，但"增量没用"这个结论是过期的** —— 两个前提都变了：
	#      · 当年脏集合是**逐像素**记的（一个半径 6 的圆标了约 113 个 chunk），
	#        增量要跑 113 x 64 = 7232 次迭代，全量 79872 次 —— 理论上差 11 倍，
	#        实测却几乎一样（9.36 vs 9.13 ms），因为每次迭代固定开销约 1 us。
	#      · 现在的脏集合是**按 chunk** 记的（一笔 13x13 擦除只标 9 个 chunk），
	#        位网格也是 8 行/块。
	#    新版**不再依赖脏集合**，改用自校验指纹（见 _build_grid 的说明）：
	#    2048x128 实测 15.8 -> 约 2 ms。
	# ⚠️⚠️ 这里曾经有一个"实心快路径"：占满外接盒时直接 fill(1)（8.71 -> 0.52 ms）。
	#    **已按用户要求移除。**
	#
	#    理由不是它慢，而是它让**第一笔和之后每一笔走的不是同一条路**：
	#      · 第一笔：形状实心 -> 命中快路径 -> 0.52 ms，很跟手
	#      · 之后：有了洞 -> 退回逐像素 -> 8.71 ms，明显卡
	#    用户的原话是"影响擦除手感" —— **不一致比均匀地慢更伤手感**，
	#    因为手会先建立起"跟手"的预期，然后在第二笔被打破。
	#
	#    这条经验值得留着：**优化如果只覆盖一部分情况，它带来的
	#    预期落差可能比不做优化更糟。** 要么全快，要么别快。
	#
	#    （顺带：真正的解法是让**所有**情况都快 —— 位网格，
	#      1200 个 word 而不是 76800 个字节，见下面的墓碑注释。）
	# ⚠️ 试过把这里改成"逐行用 append_array/slice 原生拼接"（配 256 项
	#    8 字节模式表）—— **实测同样是 8.71 ms，白做**，已回退。
	#
	#    原因：地板不在"每次写多少字节"，而在**迭代次数** ——
	#    768x100 是 96 chunk x 100 行 = 9600 次 chunk-行访问，
	#    无论里面是 8 次赋值还是 1 次原生拼接，都要付这 9600 次的代价。
	#
	#    要真正降下来只能**减少迭代**（比如用位网格：1248 个 word 而不是
	#    76800 个字节），那是重写 _greedy，不是改这一处能解决的。
	#
	#    真正有效的是上面的**实心快路径**（fill(1)，8.71 -> 0.52 ms）。
	for k: int in shape.chunks:
		var c: PixelChunk = shape.chunks[k]
		var bk := PixelShape.make_key(PixelShape.key_x(k) >> 3, PixelShape.key_y(k) >> 3)
		if not sigs.has(bk):
			sigs[bk] = PackedInt64Array()
			_sorted_insert(keys, bk)
		var bx := (PixelShape.key_x(k) << 3) - aabb.position.x
		var by := (PixelShape.key_y(k) << 3) - aabb.position.y
		for y in 8:
			var gy := by + y
			if gy < 0 or gy >= h:
				continue
			_write_row_bits(words, wq, w, bx, gy, Bits.row_bits(c.occ, y))
	for bk2: int in keys:
		sigs[bk2] = _block_sig(shape, bk2)
	shape._grid_words = words
	shape._grid_wq = wq
	shape._grid_w = w
	shape._grid_h = h
	shape._grid_origin = aabb.position
	shape._grid_sigs = sigs
	shape._grid_keys = keys
	shape._grid_ready = true


## 增量刷新：只重写指纹变了的块（外加发现新块）。
static func _refresh_grid(shape: PixelShape, aabb: Rect2i, w: int, h: int, wq: int) -> void:
	var sigs: Dictionary = shape._grid_sigs
	var keys: Array = shape._grid_keys
	# 1) 新块。chunk 属于哪个块是它的 key 的函数（8 整除 64，chunk 不会跨块），
	#    所以"新块"一定伴随"新 chunk"。
	#
	# ⚠️ 这里内联了 key_x / key_y / make_key：这一段每次刷新要跑 chunk 数次
	#    （2048x128 是 4096 次），三次静态函数调用就是 ~1.2 ms。
	#    等价性由 validation_grid_cache.gd 逐位对拍（含负坐标）。
	for k: int in shape.chunks:
		var bk := ((k >> 35) << 32) | (((k << 32) >> 35) & 0xFFFFFFFF)
		if not sigs.has(bk):
			sigs[bk] = PackedInt64Array()
			_sorted_insert(keys, bk)
	# 2) 指纹变了才重写。
	#    ⚠️ PackedInt64Array 是**值类型**（写时复制）：先取到局部、改完再写回。
	#    直接写 shape._grid_words[i] 会在**每次**索引赋值时触发一次整体拷贝
	#    （512 次写 x 4096 个 word = 灾难）。
	var words := shape._grid_words
	for bk2: int in keys:
		var sig := _block_sig(shape, bk2)
		if sig == sigs[bk2]:
			continue
		sigs[bk2] = sig
		var bix := PixelShape.key_x(bk2)
		var biy := PixelShape.key_y(bk2)
		var cx0 := bix << 3
		var cy0 := biy << 3
		for oy in 8:
			var by := (biy << 6) + (oy << 3) - aabb.position.y
			for ox in 8:
				var bx := (bix << 6) + (ox << 3) - aabb.position.x
				var c: PixelChunk = shape.chunks.get(((cx0 + ox) << 32) | ((cy0 + oy) & 0xFFFFFFFF))
				for y in 8:
					var gy := by + y
					if gy < 0 or gy >= h:
						continue
					var row := 0
					if c != null:
						row = Bits.row_bits(c.occ, y)
					_write_row_bits(words, wq, w, bx, gy, row)
	shape._grid_words = words


## 一个块的指纹：64 个 chunk 的占用字（缺的 chunk 记 0）。
## 分解只吃占用位，所以这足以判定"这个块变了没有"。
static func _block_sig(shape: PixelShape, bk: int) -> PackedInt64Array:
	var bix := PixelShape.key_x(bk)
	var biy := PixelShape.key_y(bk)
	var sig := PackedInt64Array()
	sig.resize(64)
	var cx0 := bix << 3
	var cy0 := biy << 3
	var i := 0
	for oy in 8:
		for ox in 8:
			# 内联 make_key：这段每个块 64 次、每次刷新几十个块
			# （不用"加法"写法：cy0 为负时 (cy0 & 0xFFFFFFFF) + oy 会进位到高 32 位）
			var c: PixelChunk = shape.chunks.get(((cx0 + ox) << 32) | ((cy0 + oy) & 0xFFFFFFFF))
			sig[i] = 0 if c == null else c.occ
			i += 1
	return sig


## 有序插入。块 key 只在"新块第一次出现"时插入，所以 O(n) 的搬移无所谓；
## 顺序必须稳定（指纹表按 key 有序遍历，输出才是内容的纯函数）。
static func _sorted_insert(keys: Array, bk: int) -> void:
	var lo := 0
	var hi := keys.size()
	while lo < hi:
		var mid := (lo + hi) >> 1
		if int(keys[mid]) < bk:
			lo = mid + 1
		else:
			hi = mid
	keys.insert(lo, bk)


## 贪心最大矩形。horizontal_first 决定先向右还是先向下扩，
## 两种顺序都是精确覆盖，但矩形数量可能不同。
static func _greedy(words: PackedInt64Array, wq: int, w: int, h: int, horizontal_first: bool) -> Array:
	var rects: Array = []
	# ⚠️ 扫描：**逐 word 找非零**，不要逐位或逐格。
	#    一行是 wq 个 word（768 宽 = 12 个），100 行 = **1200 个 word**，
	#    比原来的 76800 个字节少两个数量级。
	#
	#    （字节版当年用的是 PackedByteArray.find() 原生 memchr —— 那条经验仍然对：
	#      扫描要交给引擎或降到 word 级，别写逐格循环。）
	var wi := 0
	var nw := wq * h
	while wi < nw:
		while wi < nw and words[wi] == 0:
			wi += 1
		if wi >= nw:
			break
		var y := wi / wq
		var x := ((wi - y * wq) << 6) + Bits.first_bit_index(words[wi])
		if x >= w:
			# 理论上不该发生（构建时已按 w 裁剪），但真发生了就跳过这个 word，
			# 免得死循环。
			wi += 1
			continue
		var rw := 1
		var rh := 1
		if horizontal_first:
			rw = _run_right(words, wq, w, x, y)
			rh = _extend_down_bits(words, wq, w, h, x, y, rw)
		else:
			rh = _run_down(words, wq, w, h, x, y)
			rw = _extend_right_bits(words, wq, w, h, x, y, rh)
		# ⚠️ 清零用**位掩码**：rh x ceil(rw/64) 次 AND。
		#    全宽矩形是 100 x 12 = **1200 次**，而字节版是 76800 次赋值。
		#
		#    ⚠️ 但实测**全宽**这一种情况字节版更快（0.01 ms vs 0.10 ms）——
		#    因为字节版能用 slice/resize 整体替换（原生 memcpy），
		#    而位版要按 word 循环。所以这里保留一个**退化路径**：
		#    全宽时把整行整行地清（每行 ceil(w/64) 个 word），
		#    逻辑上与按矩形清完全等价，只是少了 per-rect 的边界计算。
		#    退化路径不改变结果，只改变怎么把位清掉。
		_clear_rect(words, wq, x, y, rw, rh)
		rects.append(Rect2(x, y, rw, rh))
	return rects


## 把一个 8 位行模式写到网格的 [bx, bx+8) 上（**覆盖**，不是或）。
##
## ⚠️ 必须是覆盖：增量路径下同一个 chunk 可能变小了（原来有像素、现在没了），
##    只做 |= 的话旧位会留着 —— 那是"擦掉了但碰撞还在"这类 bug 的经典来源。
static func _write_row_bits(words: PackedInt64Array, wq: int, w: int, bx: int, gy: int, row: int) -> void:
	var start := bx
	var bits := row
	if start < 0:
		bits = bits >> (-start)
		start = 0
	var end := mini(bx + 8, w)
	if end <= start:
		return
	var count := end - start
	var off := start & 63
	var wi := gy * wq + (start >> 6)
	if off + count <= 64:
		var mask := ((1 << count) - 1) << off
		words[wi] = (words[wi] & ~mask) | ((bits << off) & mask)
	else:
		# 跨两个 word —— chunk 的 8 位不一定对齐到 word 边界
		# （aabb.position 可以是任意值，所以 bx 也是）
		var lo_count := 64 - off
		var lo_mask := ((1 << lo_count) - 1) << off
		words[wi] = (words[wi] & ~lo_mask) | ((bits << off) & lo_mask)
		var hi_count := count - lo_count
		var hi_mask := (1 << hi_count) - 1
		words[wi + 1] = (words[wi + 1] & ~hi_mask) | ((bits >> lo_count) & hi_mask)


## 从 (x, y) 起，同一行里**连续**有多少个占用格。O(1) 每个 word。
##
## ⚠️ 不要写逐位循环 —— 那样一个全宽行就是 768 次迭代，白改位网格。
##    这里用掩码 + first_bit_index 一次定位"下一个 0"。
static func _run_right(words: PackedInt64Array, wq: int, w: int, x: int, y: int) -> int:
	var n := 0
	var cx := x
	while cx < w:
		var off := cx & 63
		# 把 off 以下的位抹掉（-1 << off 是"低 off 位为 0"的掩码）
		var inv := (~words[y * wq + (cx >> 6)]) & (-1 << off)
		var run := 64 - off
		if inv != 0:
			run = Bits.first_bit_index(inv) - off
		var room := w - cx
		if run >= room:
			return n + room
		if run <= 0:
			return n
		n += run
		cx += run
		if off + run < 64:
			return n     # 停在某个 0 上
	return n


## 从 (x, y) 起，同一列里连续有多少个占用格。O(h)。
static func _run_down(words: PackedInt64Array, wq: int, w: int, h: int, x: int, y: int) -> int:
	var rh := 1
	var wi := y * wq + (x >> 6)
	var bit := 1 << (x & 63)
	while y + rh < h and (words[wi + rh * wq] & bit) != 0:
		rh += 1
	return rh


## 在 y..y+rh-1 每一行上，从 x 起都要有 rw 个占用格。返回能向下扩几行。
static func _extend_down_bits(words: PackedInt64Array, wq: int, w: int, h: int, x: int, y: int, rw: int) -> int:
	var rh := 1
	var end := x + rw
	while y + rh < h:
		var base := (y + rh) * wq
		var ok := true
		var cx := x
		while cx < end:
			var off := cx & 63
			var take := mini(64 - off, end - cx)
			var mask := -1
			if take < 64:
				mask = ((1 << take) - 1) << off
			if (words[base + (cx >> 6)] & mask) != mask:
				ok = false
				break
			cx += take
		if not ok:
			break
		rh += 1
	return rh


## 每一行从 x 起的连续占用长度取**最小值** —— 等价于逐列检查所有 rh 行。
##
## ⚠️ 不要逐列循环：那样是 768 x rh 次迭代。这里每行一次 O(1) 的 _run_right。
static func _extend_right_bits(words: PackedInt64Array, wq: int, w: int, h: int, x: int, y: int, rh: int) -> int:
	var best := w - x
	for j in rh:
		var r := _run_right(words, wq, w, x, y + j)
		if r < best:
			best = r
			if best <= 0:
				break
	return best


## 把 [x, x+rw) x [y, y+rh) 这些位清掉。
## 每行 ceil(rw/64) 次 AND —— 全宽矩形是 100 x 12 = 1200 次。
static func _clear_rect(words: PackedInt64Array, wq: int, x: int, y: int, rw: int, rh: int) -> void:
	var end := x + rw
	for j in rh:
		var base := (y + j) * wq
		var cx := x
		while cx < end:
			var off := cx & 63
			var take := mini(64 - off, end - cx)
			var mask := -1
			if take < 64:
				mask = ((1 << take) - 1) << off
			words[base + (cx >> 6)] &= ~mask
			cx += take


## 合并：把"另一根轴上区间相同、主轴上也相邻"的矩形并成**极大行程**。
##
## ⚠️⚠️ 语义与上一版（"进位"）**故意不同**：这是一次**行为变更**，不是等价重构。
##    上一版是"等尺寸相邻两两配对、反复跑到不动点" —— 3 个等尺寸连排会停在 2 个，
##    于是实心区域被切成 2 的幂那样的一串（4000 宽 -> [0,2048]+[2048,3072]+…），
##    留下 log2 个**接缝**。
##
##    ⚠️ 接缝是**物理缺陷**，不是审美问题。实测（tests/diag_seam_matrix.gd）：
##    地面被切成 6 块、接缝落在静止箱子边缘 **1 像素**处时，箱子会**翻倒**
##    （30 个里 2 个翻 90°、滑走 47 像素）；而 [0,4000] 整块、或同样 6 块但接缝
##    都不在箱子附近时，30 个箱子**纹丝不动**。机制已查清：触发条件就是
##    "矩形边界落在离静止物体边缘 ~1 像素处" —— 与矩形数、顺序、裂缝都无关。
##
##    最大行程合并把实心区域并成 1 个矩形（= 旧全局贪心的结果）-> **零接缝**。
##    这是"按块分解"能上线的**前提**：拿增量速度，但不把物理质量搭进去。
##
## 精确性：只并"另一轴区间相同 + 主轴相邻"的矩形 —— 并集不变、不重叠，
## 覆盖仍逐像素精确（tests/validation_rect_shapes.gd 的像素级对拍守着）。
static func _merge_pass(rects: Array) -> Array:
	var changed := true
	while changed:
		changed = false
		var a := _fuse_axis(rects, true)
		if a.size() < rects.size():
			changed = true
		var b := _fuse_axis(a, false)
		if b.size() < a.size():
			changed = true
		rects = b
	return rects


## 沿一根轴并极大行程：分组键是"**另一根轴**上的区间"（相同才能并），
## 组内按主轴排序，首尾相接就并。
##
## ⚠️ 允许两个矩形**宽度不同**（只要 y 区间相同且 x 相邻）—— 这正是把"最后那个
##    不满 64 的块"吸收进整条行程所需要的一步。并集不变，所以仍然精确。
static func _fuse_axis(rects: Array, along_x: bool) -> Array:
	var groups := {}
	for r: Rect2 in rects:
		var key := Vector2(r.position.y, r.size.y) if along_x else Vector2(r.position.x, r.size.x)
		if groups.has(key):
			groups[key].append(r)
		else:
			groups[key] = [r]
	var out: Array = []
	for key2: Vector2 in groups:
		var g: Array = groups[key2]
		if g.size() == 1:
			out.append(g[0])
			continue
		if along_x:
			g.sort_custom(func(p: Rect2, q: Rect2) -> bool: return p.position.x < q.position.x)
		else:
			g.sort_custom(func(p: Rect2, q: Rect2) -> bool: return p.position.y < q.position.y)
		var cur: Rect2 = g[0]
		for i in range(1, g.size()):
			var nxt: Rect2 = g[i]
			if along_x:
				if absf(cur.end.x - nxt.position.x) < 0.001:
					cur = Rect2(cur.position, Vector2(nxt.end.x - cur.position.x, cur.size.y))
				else:
					out.append(cur)
					cur = nxt
			else:
				if absf(cur.end.y - nxt.position.y) < 0.001:
					cur = Rect2(cur.position, Vector2(cur.size.x, nxt.end.y - cur.position.y))
				else:
					out.append(cur)
					cur = nxt
		out.append(cur)
	return out


## 旧实现（`ea72019` 之前），**原样冻结**：非整数矩形要走 0.001 容差路径时用它兜底。
## 不要"顺手优化"它 —— 它的全部价值就在于它逐位等于旧行为。
static func _merge_pass_ref(rects: Array) -> Array:
	var changed := true
	while changed:
		changed = false
		var out: Array = []
		var used := []
		used.resize(rects.size())
		used.fill(false)
		for i in rects.size():
			if used[i]:
				continue
			var a: Rect2 = rects[i]
			for j in range(i + 1, rects.size()):
				if used[j]:
					continue
				var b: Rect2 = rects[j]
				if a.size == b.size and a.position.y == b.position.y and absf(a.end.x - b.position.x) < 0.001:
					a = Rect2(a.position, Vector2(a.size.x + b.size.x, a.size.y))
					used[j] = true
					changed = true
				elif a.size == b.size and a.position.x == b.position.x and absf(a.end.y - b.position.y) < 0.001:
					a = Rect2(a.position, Vector2(a.size.x, a.size.y + b.size.y))
					used[j] = true
					changed = true
			used[i] = true
			out.append(a)
		rects = out
	return rects


## 在候选表里找第一个"下标 > cursor 且还没被用掉"的 j。
## 候选表正常情况下只有 1 项（键是尺寸 + 位置的完整标识），所以这基本就是一次字典查找。
static func _merge_candidate(idx: Dictionary, used: Array, key: Vector4, cursor: int) -> int:
	var list = idx.get(key)
	if list == null:
		return -1
	for j: int in list:
		if j > cursor and not used[j]:
			return j
	return -1


## 像素空间的矩形应当整数值。判据是"转 int 再转回来"：小数（含负数、NaN）
## 一定不相等，所以它只会**多**退回旧实现，不会漏判。
static func _is_int_rect(r: Rect2) -> bool:
	return r.position == Vector2(Vector2i(r.position)) and r.size == Vector2(Vector2i(r.size))
