extends RefCounted
## 像素团 -> **碰撞体多边形**（凸多边形集合，Noita 式拟合）。
##
## ## 它和另外几个是什么关系
##   · GreedyRects.decompose() = **精确覆盖**（每个像素恰好被一个矩形盖住）——
##     AABB / 厚度判据 / 覆盖闸门靠它，保留；
##   · HullFit.fit()           = 整个形状的**一个**凸包（凹角被填平）—— 粗包围体；
##   · PolyFit.decompose()     = **碰撞体**：把形状切成若干**凸多边形**，斜边是**直的**
##     （锯齿被拉平），块数远少于矩形。
##
## ## 判据是"偏离多少像素"，不是"幻影多少面积"
##
## 每一块都是它那部分像素的**凸包**，凹处会被填平 —— 填掉的那块叫幻影面积。
## 用**幻影面积**当预算是错的，两个反例都在 tests/validation_poly.gd 里：
##   · 楼梯（40 级台阶）：幻影只有 2.4%，但它**正是我们要的**（斜边拉直，偏离 0.5 像素）；
##   · 1 像素宽的斜线：幻影 96%，偏离其实只有 0.5 像素 —— 面积比判据会把它切碎。
## 真正的量是**偏离**：幻影面积 / 这一块的尺寸 ≈ 碰撞体比像素表面"厚"了多少像素。
## 判据 `phantom / max(宽, 高) <= dev_tol`（默认 1 像素）对两种形状给出的答案正好相反：
##   · 楼梯 / 斜坡 / 圆盘 / 斜线：台阶贴着对角线 -> 偏离 < 1px -> **并成一块**（斜边是直线）；
##   · 锯齿地形（齿深 12px）/ 带洞的墙：偏离 6~12px -> **不并**，于是洞不会被封死。
##
## ## 为什么是"区域生长"而不是单趟扫描
##
## 贪心分解出来的矩形，**长边方向不固定**：圆盘是一行一个横条（该竖着并），
## 锯齿地形是一列一个竖条（该横着并）。任何单一扫描顺序都会把另一种切碎
## （实测：按 x 扫圆盘 -> 26 块；按 y 扫锯齿 -> 769 块）。所以这里做真正的区域生长：
## 从第一个未分配的矩形起，反复在**邻接**的未分配矩形里挑第一个"并进来不超标"的，
## 直到没有能并的为止 —— 两个方向都能长。
##
## ⚠️ 幻影是**真实的物理差异**：碰撞体比像素大一圈（最多 dev_tol 像素）。
##    Result 里给出 phantom / max_deviation，调用方自己决定能不能接受。

const HullFit := preload("res://addons/pixel_destruction/core/hull_fit.gd")
# ⚠️ 必须是**模块级 const**：写成函数里的局部 var 再拿它当类型标注（GreedyRects.Result）
#    会直接解析失败（"Local variable cannot be used as a type"）。
const GreedyRects := preload("res://addons/pixel_destruction/core/greedy_rects.gd")

## 默认偏离容差（像素）。1 像素的台阶/锯齿会被拉直；12 像素的锯齿不会被填平。
##
## ⚠️⚠️ 判据是**平均**厚度（幻影面积 / 长边），不是**最坏深度** —— 这一点必须知道：
##    深而窄的凹口会被低估。实测反例（tests/validation_poly.gd 的"墙+洞"）：
##    把"左立柱 + 洞下方的脚"并起来，幻影 = 洞角上的三角形（72），长边 36
##    -> 平均厚度 2.0，看着"刚好在预算内"，而洞角那里实际深 12 像素 ——
##    于是洞被**封了一半**（子弹打不穿）。容差 2.0 时它正好蒙混过关，
##    1.0 时被拒、洞完整保住。所以默认取 **1.0**（保守），而不是 2.0。
##    要更准就得换成"最坏深度"（要按像素网格量距离），那是另一个量级的代价。
const DEFAULT_DEV_TOL := 1.0
## 空间哈希的格子边长（像素）。只影响邻接查询的常数，不影响结果。
const CELL := 32


class Result:
	var polys: Array = []              ## Array[PackedVector2Array]，形状局部像素坐标
	var pixel_area := 0.0              ## 被覆盖的像素面积（精确值）
	var poly_area := 0.0               ## 凸多边形面积和（>= pixel_area）
	var max_deviation := 0.0           ## 逐块的最大偏离（像素）—— 最坏情况下碰撞体比像素厚多少
	var dev_tol := 0.0

	func parts() -> int:
		return polys.size()

	## 幻影面积：碰撞体比像素多出来的那部分（>= 0）。
	func phantom() -> float:
		return maxf(0.0, poly_area - pixel_area)

	func phantom_ratio() -> float:
		return 0.0 if pixel_area <= 0.0 else phantom() / pixel_area

	## 逐块都没有幻影（每块恰好是它那部分像素的凸包）。
	func is_exact() -> bool:
		return phantom() <= 1.0e-6


## 形状 -> 碰撞体多边形。
static func decompose(shape, dev_tol := DEFAULT_DEV_TOL) -> Result:
	var r: GreedyRects.Result = GreedyRects.decompose(shape, 0)
	return decompose_rects(r.rects, dev_tol)


## 精确覆盖的矩形集合 -> 凸多边形集合（区域生长，O(矩形数 x 邻居数)）。
##
## ⚠️ 输入必须是**互不重叠**的矩形（GreedyRects 的输出满足）。重叠的输入会让
##    "面积和"偏大，偏离判据跟着失真。
static func decompose_rects(rects: Array, dev_tol := DEFAULT_DEV_TOL) -> Result:
	var res := Result.new()
	res.dev_tol = dev_tol
	res.pixel_area = rect_area(rects)
	var n := rects.size()
	if n == 0:
		return res
	# ① 规范顺序：按 (y, x) 排。结果必须是**矩形集合的纯函数**（与输入顺序无关），
	#    所以后面每一步都从这个顺序出发（邻接桶、frontier 的插入顺序也跟着确定）。
	var order: Array = []
	order.resize(n)
	for i in n:
		order[i] = i
	order.sort_custom(func(a: int, b: int) -> bool:
		var ra: Rect2 = rects[a]
		var rb: Rect2 = rects[b]
		if ra.position.y != rb.position.y:
			return ra.position.y < rb.position.y
		return ra.position.x < rb.position.x)
	# ② 空间哈希：格子 -> 矩形下标（用于 O(1) 找邻居）
	var buckets := {}
	for i in n:
		var r: Rect2 = rects[i]
		var c0 := Vector2i(floori(r.position.x / CELL), floori(r.position.y / CELL))
		var c1 := Vector2i(floori((r.position.x + r.size.x) / CELL), floori((r.position.y + r.size.y) / CELL))
		for cy in range(c0.y, c1.y + 1):
			for cx in range(c0.x, c1.x + 1):
				var k := Vector2i(cx, cy)
				if buckets.has(k):
					buckets[k].append(i)
				else:
					buckets[k] = [i]
	var used := {}
	for idx: int in order:
		if used.has(idx):
			continue
		var part_pts := _corners(rects[idx])
		var part_area: float = rects[idx].size.x * rects[idx].size.y
		var part_box: Rect2 = rects[idx]
		var poly := PackedVector2Array()
		used[idx] = true
		# ③ 区域生长：frontier = 与当前块相接的未分配矩形（Dictionary 保插入序 -> 确定性）
		var frontier := _neighbors(rects, buckets, used, part_box)
		while not frontier.is_empty():
			var grew := false
			for j: int in frontier.keys():
				if used.has(j):
					continue
				var r2: Rect2 = rects[j]
				if not _touches(part_box, r2):
					continue
				var mpts := part_pts.duplicate()
				_append_rect(mpts, r2)
				var cand := HullFit.of_points(mpts)
				if cand.size() < 3:
					continue
				var merged_area := part_area + r2.size.x * r2.size.y
				var dev := (HullFit.area(cand) - merged_area) / maxf(1.0, _long_side(cand))
				if dev > dev_tol:
					continue
				# ⚠️ 只留**凸包的顶点**：凸包的凸包还是它自己，点集可以一直缩到 O(顶点数)，
				#    否则每一轮都要对几千个点重排一次（实测锯齿地形 16.45 -> 6.44 ms）。
				part_pts = cand
				part_area = merged_area
				part_box = part_box.merge(r2)
				poly = cand
				used[j] = true
				frontier.erase(j)
				for k2: int in _neighbors(rects, buckets, used, r2).keys():
					if not used.has(k2):
						frontier[k2] = true
				grew = true
				break
			if not grew:
				break
		if poly.size() < 3:
			poly = HullFit.of_points(part_pts)
		_emit(res, poly, part_area)
	for p: PackedVector2Array in res.polys:
		res.poly_area += HullFit.area(p)
	return res


static func _emit(res: Result, poly: PackedVector2Array, area: float) -> void:
	if poly.size() < 3:
		return
	res.polys.append(poly)
	var dev := (HullFit.area(poly) - area) / maxf(1.0, _long_side(poly))
	if dev > res.max_deviation:
		res.max_deviation = dev


## 与 box 相接（相交或相切）的**未分配**矩形下标集合。
static func _neighbors(rects: Array, buckets: Dictionary, used: Dictionary, box: Rect2) -> Dictionary:
	var out := {}
	var c0 := Vector2i(floori((box.position.x - 1.0) / CELL), floori((box.position.y - 1.0) / CELL))
	var c1 := Vector2i(floori((box.position.x + box.size.x + 1.0) / CELL),
			floori((box.position.y + box.size.y + 1.0) / CELL))
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var arr = buckets.get(Vector2i(cx, cy))
			if arr == null:
				continue
			for i: int in arr:
				if used.has(i):
					continue
				if _touches(box, rects[i]):
					out[i] = true
	return out


## 两个包围盒相接（相交或相切）。
## ⚠️ 不要求严格共边：隔着一两个像素的缝并进来也是对的（凸包会盖住缝，
##    那点幻影本来就计入偏离预算）。但**跨过洞**会立刻让偏离超标 -> 被拒。
static func _touches(a: Rect2, b: Rect2) -> bool:
	return a.position.x <= b.position.x + b.size.x 			and b.position.x <= a.position.x + a.size.x 			and a.position.y <= b.position.y + b.size.y 			and b.position.y <= a.position.y + a.size.y


static func _corners(r: Rect2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	_append_rect(pts, r)
	return pts


static func _append_rect(pts: PackedVector2Array, r: Rect2) -> void:
	var p := r.position
	var e := r.end
	pts.append(p)
	pts.append(Vector2(e.x, p.y))
	pts.append(e)
	pts.append(Vector2(p.x, e.y))


## 凸包的"尺寸"：包围盒的长边。偏离 = 幻影面积 / 长边 ≈ 平均厚度（像素）。
static func _long_side(poly: PackedVector2Array) -> float:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p: Vector2 in poly:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	return maxf(hi.x - lo.x, hi.y - lo.y)


static func rect_area(rects: Array) -> float:
	var a := 0.0
	for r: Rect2 in rects:
		a += r.size.x * r.size.y
	return a


static func bounds_of(rects: Array) -> Rect2:
	if rects.is_empty():
		return Rect2()
	var b: Rect2 = rects[0]
	for i in range(1, rects.size()):
		b = b.merge(rects[i])
	return b
