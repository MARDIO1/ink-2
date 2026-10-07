extends RefCounted
## 顺序冲量求解器（2D 版）。
##
## 与 3D 版本的差别：
##   摩擦只需要 1 个切向（3D 需要 2 个）；有效质量里的角向项退化为标量平方。
## 这里补上了参考实现缺失的两件事：warm starting 与休眠。
##
## ⚠️ 求解器占整帧的 62~72%（tests/profile_stages.gd），所以它是唯一值得花力气的地方。
## 内层做过一次专门优化，原则是：**把迭代不变量全部搬到 prepare()**。
## 一次 solve 里，物体的 inv_mass / inv_inertia / 是否可写 / 接触点的 r_a / r_b
## 都不变，有效质量 k11 / k22 / k12 更是不变 —— 而旧写法把它们放在 10 次迭代里
## 各重算一遍。改完的等价性由 tests/dump_state.gd 逐位比对确认（不是"测试都过了"）。

const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")

class Point:
	var feature_id := 0
	var position := Vector2.ZERO
	var depth := 0.0
	var r_a := Vector2.ZERO
	var r_b := Vector2.ZERO
	var normal_mass := 0.0
	var tangent_mass := 0.0
	var velocity_bias := 0.0
	var normal_impulse := 0.0
	var tangent_impulse := 0.0
	## >0 表示还有间隙（推测接触），<=0 表示穿透深度 = -separation
	var separation := 0.0
	## 位置修正走独立的伪速度通道（split impulse）
	var pseudo_velocity_bias := 0.0
	var pseudo_normal_impulse := 0.0
	# --- prepare() 预计算的迭代不变量 ---
	## 法向有效质量的分母（k11 / k22）。块求解器要用它本身，不只是它的倒数，
	## 所以两个都留着（normal_mass = 1/k_n）。
	var k_n := 0.0
	## r_a x normal / r_b x normal：法向相对速度要用
	var rn_a := 0.0
	var rn_b := 0.0
	var rt_a := 0.0
	var rt_b := 0.0

class Manifold:
	var a: PBody
	var b: PBody
	var normal := Vector2.RIGHT     # A -> B
	var points: Array = []
	var key := 0
	var restitution := 0.0
	var friction := 0.5
	# --- prepare() 预计算的迭代不变量 ---
	var tangent := Vector2.RIGHT
	var mu := 0.5
	var ma := 0.0                   # 逆质量（不可写时为 0）
	var mb := 0.0
	var ia := 0.0                   # 逆惯量（不可写时为 0）
	var ib := 0.0
	var wa := false                 # 是否允许写 A 的速度（清醒且非静态）
	var wb := false
	var k12 := 0.0                  # 2 点流形的耦合项
	var two_point := false

var iterations := 10
## 同色组小于这个规模就不开线程（线程开销大于收益）
var parallel_min_per_color := 8
var baumgarte := 0.15
## 允许的穿透深度（像素）。小于它的穿透不做修正 —— 这点"软"是必要的，
## 否则接触面会一直在推挤，堆叠永远无法入睡。
##
## ⚠️ 这个值和推测接触是**耦合**的：推测接触真正生效之后，深穿透（> slop）
##    会触发伪速度挤出，和"允许接近"的推测偏置形成拉锯。
##    实测 20 塔 x 4 层、初始嵌入 7px 的场景在 0.5 时塌陷、1.0 时稳定。
var penetration_slop := 1.0           # 像素
## 穿透修正（伪速度通道）的速度上限，像素/秒。
##
## ⚠️ 这个值在**推测接触真正生效之后**必须调小，否则两者会打架：
##    深穿透时 100 px/s 的暴力挤出会把物体猛地推离接触面，重力再把它拉回来，
##    和推测接触的"允许接近"形成振荡，最终把堆叠结构抖散（实测 20 塔 x 4 层直接塌）。
##    20 px/s ≈ 每步 0.33 像素 —— 缓慢、单调地把穿透磨掉，不再产生回弹。
var max_depenetration_speed := 20.0  # 像素/秒
var restitution_velocity_threshold := 40.0
var global_restitution := 0.0
var global_friction := 0.5

var _warm: Dictionary = {}
var use_block_solver := true
## 见 pworld.parallel_high_priority 的注释：这里同样**默认 false**。
## 着色本来就比岛并行慢（实测 0.90~1.13x 对 1.37~1.64x），再开高优先级只会更糟。
var color_high_priority := false
var color_tasks_needed := -1

func clear_warm() -> void:
	_warm.clear()


func prepare(manifolds: Array, dt: float) -> void:
	for m: Manifold in manifolds:
		var a: PBody = m.a
		var b: PBody = m.b
		var e := maxf(m.restitution, global_restitution)
		var warm: Dictionary = _warm.get(m.key, {})
		var tangent := Vector2(-m.normal.y, m.normal.x)
		# 这些在一次 solve 里都不变，提到点循环外面、并且缓存到流形上
		var wa := a.awake and not a.is_static
		var wb := b.awake and not b.is_static
		var ia := a.inv_inertia if wa else 0.0
		var ib := b.inv_inertia if wb else 0.0
		var ma := a.inv_mass if wa else 0.0
		var mb := b.inv_mass if wb else 0.0
		m.tangent = tangent
		m.mu = maxf(m.friction, global_friction)
		m.wa = wa
		m.wb = wb
		m.ia = ia
		m.ib = ib
		m.ma = ma
		m.mb = mb
		var n := m.normal
		var pa := a.com_world()
		var pb := b.com_world()
		for p: Point in m.points:
			p.r_a = p.position - pa
			p.r_b = p.position - pb

			var rn_a := p.r_a.cross(n)
			var rn_b := p.r_b.cross(n)
			p.rn_a = rn_a
			p.rn_b = rn_b
			var kn := ma + mb + ia * rn_a * rn_a + ib * rn_b * rn_b
			p.k_n = kn
			p.normal_mass = 0.0 if kn <= 0.0 else 1.0 / kn

			var rt_a := p.r_a.cross(tangent)
			var rt_b := p.r_b.cross(tangent)
			p.rt_a = rt_a
			p.rt_b = rt_b
			var kt := ma + mb + ia * rt_a * rt_a + ib * rt_b * rt_b
			p.tangent_mass = 0.0 if kt <= 0.0 else 1.0 / kt

			# 恢复系数：只在足够快的撞击下生效，避免静止抖动
			var vn := (b.velocity_at(p.position) - a.velocity_at(p.position)).dot(n)
			var bias := 0.0
			if vn < -restitution_velocity_threshold:
				bias = -e * vn
			# 推测接触：允许接近，但最多接近到"刚好碰上"为止。
			# separation > 0 是间隙，所以允许的最小法向速度就是 -separation/dt。
			# 这一条就是防隧穿的核心 —— 不需要物体真的重叠才开始拦。
			if p.separation > 0.0:
				bias = maxf(bias, -p.separation / dt)
			p.velocity_bias = bias

			# 穿透修正放进伪速度通道：不改变真实速度，也就不参与摩擦上限。
			# （以前 Baumgarte 直接加在法向偏置里，深穿透时会撑大 normal_impulse，
			#   摩擦上限 = mu * normal_impulse 随之暴涨，两个物体就被"粘"死了。）
			var pen := maxf(0.0, -p.separation - penetration_slop) * baumgarte / dt
			p.pseudo_velocity_bias = minf(pen, max_depenetration_speed)
			p.pseudo_normal_impulse = 0.0

			# warm start：按特征 id 精确匹配，匹配不上就从 0 开始
			p.normal_impulse = 0.0
			p.tangent_impulse = 0.0
			var w: Variant = warm.get(p.feature_id)
			if w != null:
				p.normal_impulse = w.x
				p.tangent_impulse = w.y
			_apply(m, p, n * p.normal_impulse)
			_apply(m, p, tangent * p.tangent_impulse)
		# 2 点流形的耦合项 k12 需要两个接触点都在，所以放在点循环之后
		m.two_point = m.points.size() == 2
		if m.two_point:
			var p1: Point = m.points[0]
			var p2: Point = m.points[1]
			m.k12 = ma + mb + ia * p1.rn_a * p2.rn_a + ib * p1.rn_b * p2.rn_b


## 解一条流形（一个迭代步）。
##
## 与旧写法的差别只有两点，都是"把不变量搬出循环 / 省掉方法调用"，**数学与运算顺序不变**
## （所以结果逐位一致，见 tests/dump_state.gd）：
##   1. 有效质量、逆质量、切向、摩擦系数、r x normal 全部来自 prepare()；
##   2. 速度采样不再调 velocity_at()，因为 r_a / r_b 已经缓存，
##      "lv + w x r" 就地写出来即可（这也顺带省掉了 com_world() 那层调用）。
func solve_manifold(m: Manifold, dt: float) -> void:
	var a: PBody = m.a
	var b: PBody = m.b
	var n := m.normal
	var tangent := m.tangent
	var mu := m.mu
	var wa := m.wa
	var wb := m.wb
	var block := use_block_solver and m.two_point
	# 2 点流形用法向块求解器：把两个接触点当 2x2 LCP 一次解出，
	# 而不是各自独立迭代。堆叠场景下这是收敛快慢的关键。
	if block:
		_solve_block_normal(m)
	for p: Point in m.points:
		# --- 法向（块求解器已处理 2 点流形）---
		if not block:
			var vb := b.linear_velocity + Vector2(-b.angular_velocity * p.r_b.y, b.angular_velocity * p.r_b.x)
			var va := a.linear_velocity + Vector2(-a.angular_velocity * p.r_a.y, a.angular_velocity * p.r_a.x)
			var dl := p.normal_mass * (p.velocity_bias - (vb - va).dot(n))
			var new_n := maxf(p.normal_impulse + dl, 0.0)
			dl = new_n - p.normal_impulse
			p.normal_impulse = new_n
			var imp_n := n * dl
			if imp_n.x != 0.0 or imp_n.y != 0.0:
				if wa:
					a.linear_velocity -= imp_n * m.ma
					a.angular_velocity -= m.ia * p.r_a.cross(imp_n)
				if wb:
					b.linear_velocity += imp_n * m.mb
					b.angular_velocity += m.ib * p.r_b.cross(imp_n)

		# --- 位置修正（伪速度，split impulse）---
		if p.pseudo_velocity_bias > 0.0 and p.normal_mass > 0.0:
			var pvb := b.pseudo_linear_velocity + Vector2(-b.pseudo_angular_velocity * p.r_b.y, b.pseudo_angular_velocity * p.r_b.x)
			var pva := a.pseudo_linear_velocity + Vector2(-a.pseudo_angular_velocity * p.r_a.y, a.pseudo_angular_velocity * p.r_a.x)
			var pdl := p.normal_mass * (p.pseudo_velocity_bias - (pvb - pva).dot(n))
			var pnew := maxf(p.pseudo_normal_impulse + pdl, 0.0)
			pdl = pnew - p.pseudo_normal_impulse
			p.pseudo_normal_impulse = pnew
			var imp_p := n * pdl
			if imp_p.x != 0.0 or imp_p.y != 0.0:
				if wa:
					a.pseudo_linear_velocity -= imp_p * m.ma
					a.pseudo_angular_velocity -= m.ia * p.r_a.cross(imp_p)
				if wb:
					b.pseudo_linear_velocity += imp_p * m.mb
					b.pseudo_angular_velocity += m.ib * p.r_b.cross(imp_p)

		# --- 切向（库仑摩擦，按法向冲量裁剪）---
		var vb2 := b.linear_velocity + Vector2(-b.angular_velocity * p.r_b.y, b.angular_velocity * p.r_b.x)
		var va2 := a.linear_velocity + Vector2(-a.angular_velocity * p.r_a.y, a.angular_velocity * p.r_a.x)
		var dt_imp := -p.tangent_mass * (vb2 - va2).dot(tangent)
		var max_f := mu * p.normal_impulse
		var new_t := clampf(p.tangent_impulse + dt_imp, -max_f, max_f)
		dt_imp = new_t - p.tangent_impulse
		p.tangent_impulse = new_t
		var imp_t := tangent * dt_imp
		if imp_t.x != 0.0 or imp_t.y != 0.0:
			if wa:
				a.linear_velocity -= imp_t * m.ma
				a.angular_velocity -= m.ia * p.r_a.cross(imp_t)
			if wb:
				b.linear_velocity += imp_t * m.mb
				b.angular_velocity += m.ib * p.r_b.cross(imp_t)


## 串行求解。**不再复制 solve_manifold 的函数体** ——
## 旧写法把同一段逻辑抄了两份（一份给串行、一份给并行），
## 那正是"同一份规则写在两个地方"的老毛病（见开发日志坑 18）。
func solve(manifolds: Array, dt: float, grabs: Array = []) -> void:
	for it in iterations:
		for m: Manifold in manifolds:
			solve_manifold(m, dt)
		# 抓取约束和接触约束在同一层迭代，所以拖着物体撞墙时会自然互相制衡
		for g in grabs:
			g.solve(dt)


## 同色组内**互不共享刚体**，所以可以同时求解 ——
## 而且因为不共享状态，并行结果与「组内串行」逐位一致（确定性）。
## 注意：着色会改变**跨色**的求解顺序，所以结果与纯顺序求解略有差异。
func solve_colored(groups: Array, dt: float, grabs: Array = []) -> void:
	for it in iterations:
		for gi in groups.size():
			var grp: Array = groups[gi]
			var cnt := grp.size()
			if cnt == 0:
				continue
			elif cnt < parallel_min_per_color:
				# 太小的组，线程开销大于收益
				for m2: Manifold in grp:
					solve_manifold(m2, dt)
			else:
				var worker := func(t: int) -> void:
					solve_manifold(grp[t], dt)
				# 同 pworld._parallel_solve：高优先级才能拿到全部线程（低优先级只有 ~30%）
				var gid := WorkerThreadPool.add_group_task(worker, cnt, color_tasks_needed,
					color_high_priority, "solve_color")
				WorkerThreadPool.wait_for_group_task_completion(gid)
		for g in grabs:
			g.solve(dt)


## 贪心着色：两条流形只要共享刚体就冲突；同色的可以同时求解。
## 按度数降序分配颜色（Welsh–Powell），色数接近最优。
## 返回值按颜色分组，组内两两不共享刚体。
static func color_manifolds(manifolds: Array) -> Array:
	var by_body := {}
	for i in manifolds.size():
		var m: Manifold = manifolds[i]
		for id in [m.a.id, m.b.id]:
			if not by_body.has(id):
				by_body[id] = []
			(by_body[id] as Array).append(i)
	var order: Array = []
	for i in manifolds.size():
		order.append(i)
	order.sort_custom(func(x: int, y: int) -> bool:
		var mx: Manifold = manifolds[x]
		var my: Manifold = manifolds[y]
		return (by_body[mx.a.id] as Array).size() + (by_body[mx.b.id] as Array).size() \
			> (by_body[my.a.id] as Array).size() + (by_body[my.b.id] as Array).size())
	var color := PackedInt32Array()
	color.resize(manifolds.size())
	color.fill(-1)
	var ncolors := 0
	for i: int in order:
		var mi: Manifold = manifolds[i]
		var used := {}
		for id in [mi.a.id, mi.b.id]:
			for j: int in by_body[id]:
				if j != i and color[j] >= 0:
					used[color[j]] = true
		var c := 0
		while used.has(c):
			c += 1
		color[i] = c
		if c + 1 > ncolors:
			ncolors = c + 1
	var groups: Array = []
	for c2 in ncolors:
		groups.append([])
	for i in manifolds.size():
		(groups[color[i]] as Array).append(manifolds[i])
	return groups


## 2 点法向块求解器：求解 K * dx = (bias - vn)，要求 x_new = x_old + dx >= 0。
## 依次尝试四种活跃集：双活跃、仅点1、仅点2、双零。
## 全部 k11 / k22 / k12 都来自 prepare() 的预计算。
func _solve_block_normal(m: Manifold) -> void:
	var p1: Point = m.points[0]
	var p2: Point = m.points[1]
	var a: PBody = m.a
	var b: PBody = m.b
	var n := m.normal
	var k11 := p1.k_n
	var k22 := p2.k_n
	var k12 := m.k12

	var vb1 := b.linear_velocity + Vector2(-b.angular_velocity * p1.r_b.y, b.angular_velocity * p1.r_b.x)
	var va1 := a.linear_velocity + Vector2(-a.angular_velocity * p1.r_a.y, a.angular_velocity * p1.r_a.x)
	var vb2 := b.linear_velocity + Vector2(-b.angular_velocity * p2.r_b.y, b.angular_velocity * p2.r_b.x)
	var va2 := a.linear_velocity + Vector2(-a.angular_velocity * p2.r_a.y, a.angular_velocity * p2.r_a.x)
	var vn1 := (vb1 - va1).dot(n)
	var vn2 := (vb2 - va2).dot(n)
	var rhs1 := p1.velocity_bias - vn1
	var rhs2 := p2.velocity_bias - vn2
	var x1 := p1.normal_impulse
	var x2 := p2.normal_impulse
	var dx1 := 0.0
	var dx2 := 0.0
	var solved := false

	var det := k11 * k22 - k12 * k12
	if absf(det) > 1e-12:
		dx1 = (k22 * rhs1 - k12 * rhs2) / det
		dx2 = (k11 * rhs2 - k12 * rhs1) / det
		if x1 + dx1 >= 0.0 and x2 + dx2 >= 0.0:
			solved = true

	if not solved and k22 > 1e-12:
		# 仅点 2 活跃
		var d2 := rhs2 / k22
		if x2 + d2 >= 0.0 and k12 * (x2 + d2) - rhs1 >= -1e-9:
			dx1 = -x1
			dx2 = d2
			solved = true

	if not solved and k11 > 1e-12:
		var d1 := rhs1 / k11
		if x1 + d1 >= 0.0 and k12 * (x1 + d1) - rhs2 >= -1e-9:
			dx1 = d1
			dx2 = -x2
			solved = true

	if not solved:
		if rhs1 <= 0.0 and rhs2 <= 0.0:
			dx1 = -x1
			dx2 = -x2
		else:
			return

	p1.normal_impulse = x1 + dx1
	p2.normal_impulse = x2 + dx2
	var wa := m.wa
	var wb := m.wb
	var imp1 := n * dx1
	if imp1.x != 0.0 or imp1.y != 0.0:
		if wa:
			a.linear_velocity -= imp1 * m.ma
			a.angular_velocity -= m.ia * p1.r_a.cross(imp1)
		if wb:
			b.linear_velocity += imp1 * m.mb
			b.angular_velocity += m.ib * p1.r_b.cross(imp1)
	var imp2 := n * dx2
	if imp2.x != 0.0 or imp2.y != 0.0:
		if wa:
			a.linear_velocity -= imp2 * m.ma
			a.angular_velocity -= m.ia * p2.r_a.cross(imp2)
		if wb:
			b.linear_velocity += imp2 * m.mb
			b.angular_velocity += m.ib * p2.r_b.cross(imp2)


func store_warm(manifolds: Array) -> void:
	for m: Manifold in manifolds:
		var d := {}
		for p: Point in m.points:
			d[p.feature_id] = Vector2(p.normal_impulse, p.tangent_impulse)
		if d.is_empty():
			_warm.erase(m.key)
		else:
			_warm[m.key] = d


## 慢速参考实现。热路径已经内联（见 solve_manifold），这里保留一份可读版本，
## 同时 prepare() 的 warm start 仍然用它。
static func _apply(m: Manifold, p: Point, impulse: Vector2) -> void:
	if impulse == Vector2.ZERO:
		return
	var a: PBody = m.a
	var b: PBody = m.b
	if a.awake and not a.is_static:
		a.linear_velocity -= impulse * a.inv_mass
		a.angular_velocity -= a.inv_inertia * p.r_a.cross(impulse)
	if b.awake and not b.is_static:
		b.linear_velocity += impulse * b.inv_mass
		b.angular_velocity += b.inv_inertia * p.r_b.cross(impulse)


## 与 _apply 同构，但只作用于伪速度（热路径同样已内联）
static func _apply_pseudo(m: Manifold, p: Point, impulse: Vector2) -> void:
	if impulse == Vector2.ZERO:
		return
	var a: PBody = m.a
	var b: PBody = m.b
	if a.awake and not a.is_static:
		a.pseudo_linear_velocity -= impulse * a.inv_mass
		a.pseudo_angular_velocity -= a.inv_inertia * p.r_a.cross(impulse)
	if b.awake and not b.is_static:
		b.pseudo_linear_velocity += impulse * b.inv_mass
		b.pseudo_angular_velocity += b.inv_inertia * p.r_b.cross(impulse)


static func make_key(ia: int, ra: int, ib: int, rb: int) -> int:
	# ⚠️⚠️ id 必须留够位宽：原来是 16 位（0xFFFF），id 一超过 65535 就会和旧 id 撞键，
	#    于是一对**无关**的刚体共享同一份 warm-start 冲量 —— 表现为落地时莫名弹一下
	#    或下陷。而每次 fracture 都给碎片发新 id，长时间破坏很容易越过 65535。
	#    实测 make_key(1,0,70000,0) == make_key(1,0,4464,0) 为 true。
	#
	#    现在用 24 位 id（上限 1600 万）+ 8 位矩形下标，正好 64 位：
	#        24 + 8 + 24 + 8 = 64
	#    矩形下标本来就只有 0..63，8 位绰绰有余。
	#
	#    注意：这改变了键的**取值**，但因为旧写法在 id < 65536 时是单射的，
	#    当前所有测试的行为逐位不变（基准未动）。
	return ((ia & 0xFFFFFF) << 40) | ((ra & 0xFF) << 32) | ((ib & 0xFFFFFF) << 8) | (rb & 0xFF)
