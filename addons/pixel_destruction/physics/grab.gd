extends RefCounted
## 抓取 —— **游戏层的策略**：每子步算一个**受限的力**，交给引擎已有的 add_force。
##
## ## 为什么是力控（而不是"关节/运动学跟随"）
##
## 甲方定的语义（原话）：
##
## > "抓取就是向鼠标位置施加力，并补偿重力；而施加力的点就是鼠标一开始抓取的点。"
##
## 拆成三条，就是本文件做的事：
##   1. **向鼠标位置施加力** —— 力上限 = `max_accel * 质量`（重物要滞后，重量感来自这里）；
##   2. **补偿重力** —— 抓取要托住物体（`-m*g`，按刚体逐个补，作用在各自质心）；
##      补偿量**不占**力上限：否则力上限 < 自重的物体一抓就掉，那是"抓不住"不是"抓取"；
##   3. **力的作用点 = 鼠标一开始抓取的那个点**（`local_anchor`，body 局部坐标，永不改变）。
##
## ⚠️ 这条语义顺带解决了"摆动停不下来"：重力被补偿掉之后，物体不再被重力
##    拽着绕抓点摆（泵能量的那台发动机没了），剩下的自转被抓取的阻尼耗散掉。
##    所以**不需要**任何"只许刹车 / 转动时软化"之类的特殊规则 —— 那些规则是全局的，
##    会连普通物体的抓取一起改掉（甲方："怎么把非焊接体的抓取也修坏了"）。
##
## ⚠️ 试过并被否掉的两条路（别再走）：
##   · **鼠标关节**（运动学锚点 + 位置马达）：Rapier 里马达只在"锁住的轴"上生效，
##     而锁住的轴本身就是硬约束 —— 实测跟踪误差恒为 0.0~0.36 px，等于强制位移；
##     放开轴则马达完全不产生力（物体直接自由落体）。
##   · **状态级转动摩擦**（ω *= 1-k*dt）：非物理，手感像惯量被改小
##     （甲方："转动的支点/惯量不太对"）。
##
## ## 力控的两个坑（都踩过）
##
## 1. **限力饱和会泵能量**：力被截断后，方向仍然跟着位置误差走 ——
##    物体转起来时力臂方向周期性变化，等于按摆动相位持续做功（像人荡秋千）。
##    所以增益要**软**：正常拖动时力远低于上限，只有卡住时才饱和。
## 2. **等效质量必须算对**：`K = Σ K_i`（整个焊接组件在抓点处的等效质量），
##    按质量把冲量分给每个刚体。分配后 Σ r_i x imp_i = (抓点 - 组件质心) x imp ——
##    **恰好**等于"在抓点上给组件一个冲量"的力矩，所以重力力矩照样能让它垂下去。
##    （早期版本按质心分配、力矩为 0，表现是"挂起来不会垂下去"。）

const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")

var body: PBody
## 要一起驱动的**焊接组件**（含 body 自己）。由 PWorld 每子步刷新（关节会断会建）。
var bodies: Array = []
var local_anchor := Vector2.ZERO    # Body 局部坐标
var target := Vector2.ZERO          # 世界坐标（鼠标）
## 约束能提供的最大加速度。重力是 900 —— 1.7g 够把东西拎起来，又不会"弹射"。
## ⚠️ 调大 = 更容易饱和 = 更容易泵能量（见文件头的坑 1）。
var max_accel := 1500.0
## 位置修正转成期望速度时的上限（世界单位/秒）。
var max_speed := 600.0
## 响应频率上限（弧度/秒）。误差大时自动变软。
var max_omega := 8.0
## 角速度阻尼力矩系数（1/秒）：τ = -ang_damp * 角动量。
##
## ⚠️ **默认 0**（不额外加力矩）。甲方定的语义里抓取"就是向鼠标施力 + 补偿重力"，
##    没有这一项；而且补偿重力之后，转动的阻尼**已经**由位置伺服那一项提供了 ——
##    伺服阻尼作用在**抓点的速度**上，抓点速度里就含旋转分量（v_anchor = v + ω×r），
##    所以物体转起来时伺服本来就在耗散它。再叠一层角阻尼 = 阻尼过强，
##    手感像"转不动"（甲方："旋转的阻尼太强了"）。
## 需要"更黏"的手感时才调大；硬上限是 1/dt（60Hz 下 < 60），否则显式积分发散。
var ang_damp := 0.0


func anchor_world() -> Vector2:
	return body.to_world(local_anchor) if body != null else target


## 每子步调用一次：算出**受限的力**，写进 grab_force/grab_torque（覆盖写，不累加）。
func apply(dt: float, gravity: Vector2 = Vector2.ZERO) -> void:
	var b := body
	if b == null or b.is_static or dt <= 0.0:
		return
	var group: Array = bodies if not bodies.is_empty() else [b]
	var anchor := anchor_world()
	var err := target - anchor

	# 位置误差 -> 期望速度（临界阻尼：omega <= sqrt(max_accel / err)）
	var omega := max_omega
	var err_len := err.length()
	if err_len > 1e-4:
		omega = minf(max_omega, sqrt(max_accel / err_len))
	var bias := err * omega
	if bias.length() > max_speed:
		bias = bias.normalized() * max_speed
	var rhs := bias - b.velocity_at(anchor)

	# 收集组件：合计质量 + 每个刚体到抓点的 r
	var m_tot := 0.0
	var k11 := 0.0
	var k12 := 0.0
	var k22 := 0.0
	var parts: Array = []
	for p: PBody in group:
		if p == null or p.is_static:
			continue
		var r := anchor - p.com_world()
		var im := p.inv_mass
		var ii := p.inv_inertia
		k11 += im + ii * r.y * r.y
		k12 += -ii * r.x * r.y
		k22 += im + ii * r.x * r.x
		m_tot += p.mass
		parts.append([p, r])
	if m_tot <= 0.0 or parts.is_empty():
		return
	var det := k11 * k22 - k12 * k12
	if det < 1e-12:
		return
	var imp := Vector2((k22 * rhs.x - k12 * rhs.y) / det, (k11 * rhs.y - k12 * rhs.x) / det)
	var max_impulse := max_accel * m_tot * dt
	if max_impulse > 0.0 and imp.length() > max_impulse:
		imp = imp.normalized() * max_impulse

	# 角速度阻尼力矩（只耗散，不锁死旋转；见 ang_damp）
	var w_sum := 0.0
	var i_sum := 0.0
	for p2: Array in parts:
		w_sum += (p2[0] as PBody).angular_velocity * (p2[0] as PBody).inertia
		i_sum += (p2[0] as PBody).inertia
	var tq := 0.0
	if i_sum > 0.0:
		tq = clampf(-ang_damp * w_sum, -max_accel * i_sum, max_accel * i_sum)

	# 冲量按质量分给每个刚体，各自的 r 出各自的力矩（等价于在抓点上给组件一个冲量）
	for part: Array in parts:
		var q: PBody = part[0]
		var r2: Vector2 = part[1]
		var f := (imp * (q.mass / m_tot)) / dt
		# 重力补偿：托住物体。
		#
		# ⚠️⚠️ 补偿力必须作用在**抓取的那个点**上，不是质心（甲方明确过）：
		#    作用在抓点上时，它相对质心有一个力矩 r x (-m*g) —— 于是
		#    **平衡状态下质心会落在鼠标正下方**（像用手拎着东西，东西自己垂下来）。
		#    早期版本作用在质心（力矩 0），物体被"托"得不会转，挂着是歪的。
		#    补偿量单独一项、不参与上面的限力：否则力上限 < 自重的物体一抓就掉，
		#    那是"抓不住"不是"抓取"。
		var comp := -gravity * q.mass
		q.grab_force = f + comp
		q.grab_torque = r2.cross(f) + r2.cross(comp)
		if i_sum > 0.0:
			q.grab_torque += tq * (q.inertia / i_sum)
