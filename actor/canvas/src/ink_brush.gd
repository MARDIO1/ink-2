extends RefCounted
## 笔刷与形状的像素几何：笔刷圆盘、矩形边框、线段、圆环。
##
## 纯函数——只读 `brush_size` 与 `canvas_size` 两个参数，不碰画布状态，
## 所以同一套几何可以脱离场景单独验证（见 `test_ink_brush.gd`）。
##
## 返回的 `Dictionary` 以 `Vector2i` 为键；调用方负责落笔。

## 笔刷沿路径撒点的步长：≤ 半径，保证相邻脚印重叠、不留缝。
static func step(brush_size: int) -> float:
	return maxf(1.0, brush_size * 0.5)


## 把笔刷圆盘覆盖到的像素收进 out（只收，不写）。
static func collect_stamp(out: Dictionary, center: Vector2, brush_size: int,
		canvas_size: Vector2i) -> void:
	# 直径 1 直接取"点所在的那一格"。
	# ⚠️ 不能走下面的距离判定：采样点正好落在格角上时（x、y 都是整数），
	#    半径 0.5 够不到任何格心 —— 1px 的线会随机缺格、1px 的圆环会开口，
	#    而开了口的封闭区域会被墨水桶灌满整张画布。
	if brush_size <= 1:
		out[Vector2i(center.floor())] = true
		return
	# ⚠️ 半径下限 0.5：直径 1 的笔刷若用半径 0，只有圆心正好压在格心上才落笔，
	#    而鼠标坐标是小数 —— 实测 1px 笔触会"什么都画不出来"。
	var radius := maxf(0.5, (brush_size - 1) * 0.5)
	var r2 := radius * radius
	# ⚠️ 边界必须按真实圆心推，不能按 roundi(center)：半径是半整数（偶数直径）时
	#    roundi 会把整圈偏一格，实测 3px 笔触只铺出 2x2。
	var x0 := floori(center.x - radius)
	var x1 := ceili(center.x + radius)
	var y0 := floori(center.y - radius)
	var y1 := ceili(center.y + radius)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if x < 0 or y < 0 or x >= canvas_size.x or y >= canvas_size.y:
				continue
			var dx := float(x) + 0.5 - center.x
			var dy := float(y) + 0.5 - center.y
			if dx * dx + dy * dy <= r2:
				out[Vector2i(x, y)] = true


## 生成轴对齐、方角、外沿完全平整的矩形边框。
## 拖拽的两个点定义外包围盒；最大边按半开坐标换算，确保鼠标落在画布最右/下边时不越界。
static func rect(out: Dictionary, from: Vector2, to: Vector2, brush_size: int,
		canvas_size: Vector2i) -> void:
	var left := clampi(floori(minf(from.x, to.x)), 0, canvas_size.x - 1)
	var top := clampi(floori(minf(from.y, to.y)), 0, canvas_size.y - 1)
	var right := clampi(ceili(maxf(from.x, to.x)) - 1, 0, canvas_size.x - 1)
	var bottom := clampi(ceili(maxf(from.y, to.y)) - 1, 0, canvas_size.y - 1)
	# 单击或零宽/零高拖拽仍至少落一个像素。
	right = maxi(right, left)
	bottom = maxi(bottom, top)
	var thickness := maxi(1, brush_size)
	# 上下两条横边与中间两条竖边分别生成，避免扫描空心矩形的内部面积。
	var top_end := mini(top + thickness, bottom + 1)
	var bottom_start := maxi(top_end, bottom - thickness + 1)
	for y in range(top, top_end):
		for x in range(left, right + 1):
			out[Vector2i(x, y)] = true
	for y in range(bottom_start, bottom + 1):
		for x in range(left, right + 1):
			out[Vector2i(x, y)] = true
	var left_end := mini(left + thickness, right + 1)
	var right_start := maxi(left_end, right - thickness + 1)
	for y in range(top_end, bottom_start):
		for x in range(left, left_end):
			out[Vector2i(x, y)] = true
		for x in range(right_start, right + 1):
			out[Vector2i(x, y)] = true


## 沿线段撒笔刷脚印。
static func line(out: Dictionary, from: Vector2, to: Vector2, brush_size: int,
		canvas_size: Vector2i) -> void:
	var steps := maxi(1, int(ceil(from.distance_to(to) / step(brush_size))))
	for i in range(steps + 1):
		collect_stamp(out, from.lerp(to, float(i) / float(steps)), brush_size, canvas_size)


## 沿圆周撒笔刷脚印（圆心为中点，半径由拖拽距离决定）。
static func circle(out: Dictionary, center: Vector2, radius: float, brush_size: int,
		canvas_size: Vector2i) -> void:
	if radius < 0.5:
		collect_stamp(out, center, brush_size, canvas_size)
		return
	var steps := maxi(8, int(ceil(TAU * radius / step(brush_size))))
	for i in steps:
		collect_stamp(out, center + Vector2.from_angle(TAU * float(i) / float(steps)) * radius,
			brush_size, canvas_size)
