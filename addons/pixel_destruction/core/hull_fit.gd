extends RefCounted
## 像素团 -> **凸包**（多边形碰撞箱拟合）。
##
## 与 GreedyRects 是**两个东西**，别混：
##   · GreedyRects.decompose() = 物理真正用的**碰撞形状**（精确覆盖，凹形状不会多出幻影体积）
##   · HullFit.fit()           = **包围体**，和 AABB 并列的另一种外接
##
## ## 为什么要有凸包（AABB 不够用在哪）
##
## AABB 是**轴对齐**的：一个刚体一旦转起来，它的 AABB 会按外接半径膨胀 ——
## 100x8 的木板转 45 度，AABB 变成约 76x76（面积 x7）。于是所有"先用 AABB 粗筛"
## 的地方（射线、最近点、编辑器可视化）都在**筛一个比物体大好几倍的空盒子**。
## 凸包跟着刚体一起转，是**紧的**：同一块木板转 45 度，凸包面积只涨约 1.4 倍。
##
## ## ⚠️ 凸包**不是**碰撞体
##
## 拿它当碰撞形状会把凹角"填平"（L 形墙、楼梯、手绘轮廓都会多出看不见的体积）——
## 这正是 GreedyRects 顶部那段墓碑说的坑。凸包在这里的身份只有一个：
## **保守的外接**（像素集 ⊆ 凸包），所以"凸包筛掉的 = 一定碰不到"永远成立，
## 而反过来不成立。
##
## ## 约定
##
##   · 坐标是**形状局部像素空间**（与 PixelShape.local_aabb() 同一套）；
##   · 像素是**单位方格**（不是格点）：1 个像素的凸包是边长 1 的方形，
##     所以凸包面积 >= 像素数，且一定包得住每个像素的四个角；
##   · 顶点**不重复首点**（不开环）；绕向见 signed_area()；
##   · 共线点会被丢掉（顶点数最小）。

const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")


## 点集 -> 凸包（Andrew 单调链，O(n log n)）。
##
## ⚠️ 判据用 <= 0 而不是 < 0：**共线的中间点必须丢掉**。留着的话
##    "最小包围体"就名不副实（一条直边上会挂一串顶点），
##    而下游（画线、SAT、contains）都要为这些没信息的点多花时间。
static func of_points(points: PackedVector2Array) -> PackedVector2Array:
	var n := points.size()
	if n < 3:
		return points.duplicate()
	var pts := points.duplicate()
	# ⚠️ 用原生 sort()，**不要** sort_custom(lambda)：
	#    · PackedVector2Array 根本没有 sort_custom（写了直接解析失败）；
	#    · 而 Vector2 的 operator< 恰好就是我们要的字典序
	#      （x 不同比 x，相同比 y，见 Godot 的 vector2.h）——
	#      正好是单调链要求的那个严格弱序，还是原生实现（快得多）。
	pts.sort()
	# 去重（排序后相等的点必然相邻）。重复点会让下面的 <= 0 判定退化。
	var uniq := PackedVector2Array()
	for i in n:
		var p := pts[i]
		if uniq.size() > 0 and uniq[uniq.size() - 1] == p:
			continue
		uniq.append(p)
	n = uniq.size()
	if n < 3:
		return uniq
	var lower := PackedVector2Array()
	for i in n:
		while lower.size() >= 2 and _cross(lower[lower.size() - 2], lower[lower.size() - 1], uniq[i]) <= 0.0:
			lower.remove_at(lower.size() - 1)
		lower.append(uniq[i])
	var upper := PackedVector2Array()
	for i in range(n - 1, -1, -1):
		while upper.size() >= 2 and _cross(upper[upper.size() - 2], upper[upper.size() - 1], uniq[i]) <= 0.0:
			upper.remove_at(upper.size() - 1)
		upper.append(uniq[i])
	# 两条链的**末点**与对方的首点重复（最左/最右点各出现两次），各自去掉末点再拼。
	var out := PackedVector2Array()
	for i in range(0, lower.size() - 1):
		out.append(lower[i])
	for i in range(0, upper.size() - 1):
		out.append(upper[i])
	return out


## 一个像素形状的凸包（形状局部像素坐标）。
##
## ⚠️⚠️ **只需要每行的最左/最右像素**，不是所有像素 —— 这不是近似，是**恒等式**：
##    同一行里任何一个像素的四个角，都落在"该行最左像素到最右像素"这个矩形的凸包里
##    （两个同行的单位方格，其凸包恰好是横跨两者的轴对齐矩形），
##    所以中间的像素对凸包**一个顶点都贡献不了**。
##
##    代价因此是 O(块数 x 8) 而不是 O(像素数)：768x100 的地面是 1248 块 / 约 1 万个
##    行扫描，与 local_aabb() 同一量级；真正的逐像素扫描要贵 8 倍以上。
##
##    ⚠️ 代价实测（tests/bench_hull.gd，各 2000 次取平均）：768x100 地面（1248 块）首次
##    **5.05 ms**、64x64 方块 0.440 ms、8x8 碎块 0.046 ms；缓存命中 0.000 ms。
##    想再快只能换掉这一层（GreedyRects 的位网格是现成的：1200 个 word 而不是
##    1 万次行扫描），但那会把两个模块耦上 —— 而**惰性 + 缓存**已经让它在热路径上的
##    代价是 0，真嫌慢的地方该去问 cached_local_hull()（它不触发重算）。
##
## ⚠️ 参数故意**不加 PixelShape 类型标注**：本文件被 pixel_shape.gd preload，
##    反过来 preload 它会成环 —— 而 GDScript 的 preload 环会让**编辑器无声段错误**
##    （见 tools/check_addon.py 的 2c 闸门）。鸭子类型在这里是刻意的。
static func fit(shape) -> PackedVector2Array:
	var rows := {}          # y -> Vector2i(最左 x, 最右 x)，闭区间
	var chunks: Dictionary = shape.chunks
	for k: int in chunks:
		var occ: int = chunks[k].occ
		if occ == 0:
			continue
		# key_x / key_y 的内联（这个循环要跑块数次）：cx << 3 / cy << 3
		var bx := (k >> 32) << 3
		var by := ((k << 32) >> 32) << 3
		for y in 8:
			var row := Bits.row_bits(occ, y)
			if row == 0:
				continue
			var lo := Bits.first_bit_index(row)
			var hi := 7
			while ((row >> hi) & 1) == 0:
				hi -= 1                      # row != 0，不会越界
			var yy := by + y
			var e = rows.get(yy)
			if e == null:
				rows[yy] = Vector2i(bx + lo, bx + hi)
			else:
				rows[yy] = Vector2i(mini(e.x, bx + lo), maxi(e.y, bx + hi))
	if rows.is_empty():
		return PackedVector2Array()
	var pts := PackedVector2Array()
	pts.resize(rows.size() * 4)
	var i := 0
	for yy: int in rows:
		var e2: Vector2i = rows[yy]
		# 像素是**单位方格**：最左像素的左边界 = e2.x，最右像素的右边界 = e2.y + 1
		var x0 := float(e2.x)
		var x1 := float(e2.y + 1)
		var y0 := float(yy)
		var y1 := float(yy + 1)
		pts[i] = Vector2(x0, y0)
		pts[i + 1] = Vector2(x1, y0)
		pts[i + 2] = Vector2(x0, y1)
		pts[i + 3] = Vector2(x1, y1)
		i += 4
	return of_points(pts)


## 矩形集合 -> 凸包。**PBody 用的就是这条**（它的碰撞形状只有 rects）。
##
## ⚠️ 精确覆盖时 hull(矩形角点) == hull(像素角点)：贪心分解是**精确覆盖**
##    （并集逐像素等于像素集，见 GreedyRects 顶部），所以两者的点集完全相同。
##    用 decompose_proxy() 时 rects 是**近似**的，凸包会跟着变大 —— 这是对的，
##    因为凸包描述的是"碰撞体集合"，不是"画面上的像素"。
static func hull_of_rects(rects: Array) -> PackedVector2Array:
	if rects.is_empty():
		return PackedVector2Array()
	var pts := PackedVector2Array()
	pts.resize(rects.size() * 4)
	var i := 0
	for r: Rect2 in rects:
		var p := r.position
		var e := r.end
		pts[i] = p
		pts[i + 1] = Vector2(e.x, p.y)
		pts[i + 2] = e
		pts[i + 3] = Vector2(p.x, e.y)
		i += 4
	return of_points(pts)


## 点在凸包内吗（**闭集**：边上算在内部）。
##
## 判据是"所有边的叉积同号"（不需要预先算外法线，两种绕向都对）。
## ⚠️ eps 是**叉积**的容差，量纲 = 距离 x 边长，不是距离 —— 想要"外扩 n 像素"
##    请用 segment_hits()，那里把法线归一化了。
static func contains(poly: PackedVector2Array, p: Vector2, eps := 0.0) -> bool:
	var n := poly.size()
	if n < 3:
		return false
	var lo := INF
	var hi := -INF
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var c := (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
		if c < lo:
			lo = c
		if c > hi:
			hi = c
	return lo >= -eps or hi <= eps


## 线段 ab 与凸包相交吗（Cyrus-Beck 半平面裁剪，O(顶点数)）。
##
## 这是**射线查询的预剔除**用的：拿它挡掉"射线穿过 AABB、但离物体本体还远"的那些刚体，
## 免得为它们白跑一遍体素 DDA。
##
## ⚠️⚠️ **必须保守**：eps 把每个半平面向外推 eps 像素，也就是把凸包**外扩**。
##    少算了（把该命中的判成不命中）是**静默漏命中**，比慢难查得多；
##    多算了只是白跑一次 DDA，代价可控。所以调用方宁可给大一点的 eps。
static func segment_hits(poly: PackedVector2Array, a: Vector2, b: Vector2, eps := 0.0) -> bool:
	var n := poly.size()
	if n < 3:
		return false
	var orient := 1.0 if signed_area(poly) >= 0.0 else -1.0
	var d := b - a
	var t0 := 0.0
	var t1 := 1.0
	for i in n:
		var v1 := poly[i]
		var v2 := poly[(i + 1) % n]
		var e := v2 - v1
		# 外法线（按绕向定向，并归一化 —— eps 要能以"像素"为单位）
		var nrm := Vector2(e.y, -e.x).normalized() * orient
		# 半平面：nrm.(p - v1) <= eps
		var num := nrm.dot(a - v1) - eps
		var den := nrm.dot(d)
		if absf(den) < 1.0e-12:
			if num > 0.0:
				return false                 # 平行且在外侧
			continue
		var t := -num / den
		if den > 0.0:
			t1 = minf(t1, t)
		else:
			t0 = maxf(t0, t)
		if t0 > t1:
			return false
	return true


## 有向面积（鞋带公式，y 向下的屏幕坐标系）。符号 = 绕向，绝对值 = 面积。
##
## ⚠️ 这里不用 Godot 的 Geometry2D.is_polygon_clockwise()：那个函数的 y 轴假设
##    与"屏幕上看起来顺/逆时针"相反（y 向下），拿它当判据时**读代码的人会理解反**。
##    自持一个符号约定，并在测试里钉住它。
static func signed_area(poly: PackedVector2Array) -> float:
	var n := poly.size()
	if n < 3:
		return 0.0
	var s := 0.0
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		s += a.x * b.y - b.x * a.y
	return s * 0.5


static func area(poly: PackedVector2Array) -> float:
	return absf(signed_area(poly))


## o->a 与 o->b 的叉积（> 0 = 左转）。
static func _cross(o: Vector2, a: Vector2, b: Vector2) -> float:
	return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
