extends RefCounted
## 精确 OBB 扫掠（swept OBB）—— 保守推进（conservative advancement）。
##
## ## 为什么需要它
##
## 旧的 @@_sweep_clamp@@ 是"把移动体的 AABB 收成点、把障碍 AABB 按半尺寸膨胀，
## 然后射线-矩形平板测试"。三个硬伤：
##   1. **旋转完全不参与**：斜 45 度的薄板会被当成它外接的 AABB —— 薄的东西直接漏过去；
##   2. **忽略目标的运动**：只考虑移动体自己的位移，对面迎上来的情况判错；
##   3. 只截断位移，不产生接触点/法向，冲量层拿不到信息。
##
## ## 为什么没有解析解
##
## 两个 OBB 边旋转边平移时，分离轴**自己也在变**（转动会改变各轴的投影半径），
## 于是"最早碰撞时刻"没有闭式解。这不是实现偷懒，是问题本身的性质。
##
## ## 保守推进
##
## 标准替代方案。设在时刻 t 的**有符号分离量**为 sep(t)（>0 = 还有间隙），
## 则 sep 的减小速度有一个可计算的上界：
##
##     bound = |Δv · n| + |ω_A| · r_A + |ω_B| · r_B
##
##   第一项是两体沿分离轴的接近速度，后两项是**转动贡献**：
##   盒子转起来时，最靠近对面的那个点会朝对面扫过去，
##   距离转动中心越远扫得越快，上界就是 |ω| × 该点到质心的最大距离。
##
## 因为 bound 是上界，@@sep / bound@@ 一定**不会越过真正的 TOI**，
## 所以每步都能安全地推进这么多。反复迭代即线性收敛到 TOI。
##
## ⚠️ 少了转动项就会"转进来的薄板漏过去" —— 这正是旧实现的第一条硬伤。
##
## ## 关于精度
##
## 全程用 double（GDScript 的 float）计算标量，Vector2 运算仍是 float32，
## 与引擎其余部分一致（见开发日志坑 27/30/32）。
## 别在这里"顺手优化"成 float32 —— 这个项目的基准是逐位可比的。

const Collide := preload("res://addons/pixel_destruction/physics/collide.gd")
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")

const OBB := Collide.OBB
const Sat := Collide.Sat

## 收敛容差（世界单位）。留一点皮，让随后的推测接触去处理剩下的间隙。
const TOL := 1e-3
## 迭代上限。保守推进线性收敛，实际命中通常 3~8 次就够。
const MAX_ITER := 32


class Hit:
	var hit := false
	var t := 1.0              ## 命中时刻，0~1（乘以 dt 得秒）
	var normal := Vector2.ZERO ## 由 A 指向 B
	var point := Vector2.ZERO  ## 接触点（命中时刻两盒的近似接触位置）
	var sep := 0.0            ## 命中时刻的分离量（<= TOL）

	func reset() -> void:
		hit = false
		t = 1.0
		normal = Vector2.ZERO
		point = Vector2.ZERO
		sep = 0.0


## 由调用方持有、反复复用 —— 每次查询**零分配**。
## 热路径上每个高速体每帧要查几十上百次，逐次 new 两个 OBB 会立刻显形。
class Sweeper:
	var _oa := OBB.new()
	var _ob := OBB.new()
	var _sat := Sat.new()
	var _iterations := 0       ## 诊断：上一次查询用了几轮
	var _tmp := Hit.new()      ## 矩形对内层复用的结果，避免每次分配

	## 单个 OBB 对。
	##
	##   oa/ob     t=0 时刻的两个盒子
	##   com_a/com_b  各自的**转动中心**（质心）—— 盒子是绕质心转的，
	##                质心偏离盒子中心时，中心其实在画圆
	##   va/vb     线速度；wa/wb  角速度
	##   ra/rb     质心到盒子任一顶点的最大距离（转动项的上界）
	func sweep(oa: OBB, com_a: Vector2, va: Vector2, wa: float, ra: float,
			ob: OBB, com_b: Vector2, vb: Vector2, wb: float, rb: float,
			dt: float, out: Hit) -> void:
		out.reset()
		_iterations = 0
		if dt <= 0.0:
			return
		var dv := va - vb
		# 两边都在动，先把两个盒子摆到时刻 0（输入就是时刻 0，这里只准备暂存）
		_place(oa, com_a, va, wa, 0.0, dt, _oa)
		_place(ob, com_b, vb, wb, 0.0, dt, _ob)
		var t := 0.0
		for it in MAX_ITER:
			_iterations = it + 1
			Collide.sat_signed_into(_oa, _ob, _sat)
			if _sat.sep <= TOL:
				out.hit = true
				out.t = t
				out.normal = _sat.normal
				out.sep = _sat.sep
				out.point = _contact_point(_oa, _ob, _sat.normal)
				return
			# 最大接近速度上界（见文件头）。转动项一项都不能少。
			var bound := absf(dv.dot(_sat.normal)) + absf(wa) * ra + absf(wb) * rb
			if bound <= 1e-12:
				return                      # 分离量只会变大，永远碰不上
			t += (_sat.sep - TOL) / (bound * dt)
			if t >= 1.0:
				return
			_place(oa, com_a, va, wa, t, dt, _oa)
			_place(ob, com_b, vb, wb, t, dt, _ob)
		# 迭代用尽仍未收敛：**保守地报命中**。
		# 这里绝不能报"没命中" —— 当前的 t 仍然在真 TOI 之前，
		# 放行全程就等于穿模。宁可早停（可见后果是稍微提前减速）。
		out.hit = true
		out.t = t
		out.normal = _sat.normal
		out.sep = _sat.sep
		out.point = _contact_point(_oa, _ob, _sat.normal)


	## 把盒子摆到 t*dt 时刻。
	## ⚠️ 盒子的中心不是不动点：刚体绕**质心**转，中心在半径 |center-com| 的圆上走。
	## 直接 center += v*t 且只转自身基向量，在质心偏离盒子中心时会算错轨迹。
	static func _place(o: OBB, com: Vector2, v: Vector2, w: float, t: float, dt: float, dst: OBB) -> void:
		var secs := t * dt
		var com_t := com + v * secs
		var ang := w * secs
		var c := cos(ang)
		var s := sin(ang)
		# 与 Collide.obb_from_local_rect 同一套写法：直接用 (cos, sin) 构造基向量，
		# 不走 Vector2.rotated（那条路会把角度先截成 float32，见坑 27）。
		dst.u = Vector2(o.u.x * c - o.u.y * s, o.u.x * s + o.u.y * c)
		dst.v = Vector2(-dst.u.y, dst.u.x)
		var arm := o.center - com
		dst.center = com_t + Vector2(arm.x * c - arm.y * s, arm.x * s + arm.y * c)
		dst.h = o.h


	## 整个 Body 对 Body：逐矩形对扫掠，取最早命中。
	##
	## 一个 Body 的碰撞形状是肉贪心分解出的一组矩形，所以"体对体"
	## 就是这些矩形的笛卡尔积 —— 与窄相的做法一致。
	func sweep_bodies(a: PBody, b: PBody, dt: float, out: Hit) -> void:
		out.reset()
		if dt <= 0.0 or a.rects.is_empty() or b.rects.is_empty():
			return
		var com_a := a.com_world()
		var com_b := b.com_world()
		var ra := sweep_radius(a)
		var rb := sweep_radius(b)
		# ⚠️ 用**真实速度 + 伪速度**：物体实际走过的轨迹是两者之和
		# （伪速度是位置修正通道，同样改变位置）。用真实速度算 TOI 会得到错误的轨迹。
		var va := a.linear_velocity + a.pseudo_linear_velocity
		var vb := b.linear_velocity + b.pseudo_linear_velocity
		var wa := a.angular_velocity + a.pseudo_angular_velocity
		var wb := b.angular_velocity + b.pseudo_angular_velocity
		var best := 1.0
		for rect_a: Rect2 in a.rects:
			var oa := Collide.obb_from_local_rect(a, rect_a)
			for rect_b: Rect2 in b.rects:
				var ob := Collide.obb_from_local_rect(b, rect_b)
				sweep(oa, com_a, va, wa, ra, ob, com_b, vb, wb, rb, dt, _tmp)
				if _tmp.hit and _tmp.t < best:
					best = _tmp.t
					out.hit = true
					out.t = _tmp.t
					out.normal = _tmp.normal
					out.point = _tmp.point
					out.sep = _tmp.sep
		if not out.hit:
			out.t = 1.0


	## 质心到该 Body 任一形状点的**最大距离** —— 转动项 |ω|·r 的上界。
	##
	## ⚠️ 不能用 bounding_radius()：那是相对 AABB **中心**的半对角线，
	## 而转动是绕**质心**的，质心偏离 AABB 中心时它会低估。
	## 好消息是这个量是**常量**（刚体上任意点到质心的距离不随时间变），
	## 所以每次扫掠算一次就够。
	static func sweep_radius(b: PBody) -> float:
		var com := b.com_world()
		var worst := 0.0
		for r: Rect2 in b.rects:
			var c := b.to_world(r.position + r.size * 0.5)
			var h := r.size * 0.5
			worst = maxf(worst, (c - com).length() + sqrt(h.x * h.x + h.y * h.y))
		return worst


	## 命中时刻的近似接触点：取两个盒子在法向方向上的支撑点中点。
	static func _contact_point(a: OBB, b: OBB, n: Vector2) -> Vector2:
		var pa := Collide.support(a, n)
		var pb := Collide.support(b, -n)
		return (pa + pb) * 0.5
