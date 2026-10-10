extends RefCounted
## 2D 刚体（3 自由度：x, y, theta）。
##
## 与 3D 的差别是本项目的最大红利：
##   3D 需要 3x3 惯性张量 + 主轴旋转，2D 只需要一个标量 inv_inertia。
##   角度积分退化为 theta += w * dt。

const MassProps := preload("res://addons/pixel_destruction/core/mass_props.gd")
const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")
const GreedyRects := preload("res://addons/pixel_destruction/core/greedy_rects.gd")
const HullFit := preload("res://addons/pixel_destruction/core/hull_fit.gd")

var id := -1
var position := Vector2.ZERO      # Body 原点（世界坐标）
var rotation := 0.0               # 弧度
var linear_velocity := Vector2.ZERO
var angular_velocity := 0.0

var mass := 0.0
## 材质的**平均密度**（= mass / 像素数）。
##
## ⚠️ 为什么要存它：Rapier 侧碰撞体默认密度是 1.0，而 GDScript 侧 mass 是按材质
##    密度算的 —— 不把这个值推过去，两边质量就差一个密度倍率（金属 7.8 倍），
##    所有按 mass 算的力（抓取限力等）全错。见 PWorld 里推 op 34 的那段。
var density := 1.0
## 推给 Rapier 的镜像（-1 = 未推送）
var _rp_density := -1.0
## 摩擦系数 / 碰撞恢复系数（由材质逐像素平均而来，见 rebuild()）。
## ⚠️ Rapier 的接触系数是**两个碰撞体合成**的（默认 Average），所以这是"这个刚体
##    对外表现出的系数"，不是"两个材质碰在一起会怎样"。
var friction := 0.5
var restitution := 0.0
var _rp_friction := -1.0
var _rp_restitution := -1.0
var inertia := 0.0
var inv_mass := 0.0
var inv_inertia := 0.0
var local_com := Vector2.ZERO     # 质心（Body 局部坐标，像素单位）

var rects: Array = []             # Array[Rect2]，局部空间碰撞矩形（贪心分解结果，**精确覆盖**）
## 碰撞体**真的在用**的凸多边形（局部空间，Array[PackedVector2Array]）—— **惰性**读回。
##
## ⚠️ 它不是"另算一份"：由 PWorld.fetch_polys() 走 op 44 从 Rapier 读回来，
##    所以走矩形那条路时这里就是矩形（4 个角）。可视化必须用这个，
##    否则叠加层画的形状和碰撞体不是一回事。
## 形状一变（rects_rev）就作废；polys_rev == -1 表示"还没读过"。
var polys: Array = []
var polys_rev := -1
var shapes: Array = []            # Array[PixelShape]，局部空间像素数据
var is_static := false
## **冻结**（可逆）—— 与 is_static 的区别：静态是"天生不动"，冻结是"暂时不动，状态留着"。
##
## ⚠️ 冻结**不清速度**（linear/angular_velocity 原样留着），解冻后接着跑 ——
##    这就是"相机外走出范围就冻、回来就恢复"的全部含义。见 PWorld.freeze() / cull_freeze()。
## ⚠️ 冻结期间刚体按**静态**推给 Rapier：不积分、不参与静态-静态对（整片冻住几乎零成本），
##    但碰撞体还在 —— 醒着的东西照样被它挡住。
var frozen := false

## 要不要进**内部渲染器**（引擎给刚体画的那张贴图）。false = 只物理不渲染。
##
## ⚠️⚠️ 为什么这个标志在 PBody 上、而不是只在节点上：**门面（PixelPhysics）那条路没有节点**
##    （代码驱动的项目都走它，比如 ink-2）。策略只接在节点层的话，"配了不渲染"在门面路径上
##    会**静默失效** —— 症状是"明明配了，破坏之后还是冒出一张停在旧位置的矩形贴图"，
##    而且不报任何错。节点层（PixelBody2D.internal_render）烘焙时会把它同步过来。
##
## ⚠️ 关掉只影响**画**：像素照样参与物理、破坏、质量、连通性，刚体也不会被摘出世界。
## ⚠️ 自带视觉（子节点 PixelSprite2D）也走同一条判据（见 PixelWorld.uses_internal_render）。
var internal_render := true
var awake := true
var sleep_timer := 0.0
var aabb := Rect2()
## 覆盖"这一步会扫过的范围"的 AABB。
## 宽相必须用它，否则高速物体在**移动前**根本不会被配对，
## 推测接触就没有机会生成（这是隧穿没被修掉的原因）。
var swept_aabb := Rect2()
## 开启后走**扫掠 CCD**（Teardown 的 QueryShot 模型）：本步位移会做一次
## 射线-AABB 扫掠，撞到东西就停在表面上，速度不受子步上限限制。
## 子弹、投掷物这类"必须打到"的东西打开它；普通刚体不需要。
var ccd := false
var tint := Color(1, 1, 1)

## ---- 碰撞层与掩码（位掩码，bit0 = 第 1 层）----
##
## 语义与 Godot 的 collision_layer / collision_mask、Box2D 的 category/maskBits 一致：
## 两个刚体要碰，必须**双方都同意** ——
##     (A.layer & B.mask) != 0  且  (B.layer & A.mask) != 0
## 推给 Rapier 的是 InteractionGroups，它判的就是这两条。
##
## ⚠️ layer = 0 表示"不在任何层"：碰不到任何东西，任何东西也碰不到它。
##    这是"临时关掉一个刚体"的正当做法 —— 比把它移出世界便宜得多
##    （不重建碰撞体、不丢状态）。
var collision_layer := 1
## 默认全 1：谁都碰。层只有在显式设置后才有意义。
var collision_mask := 0xFFFFFFFF


var _com_cache := Vector2.ZERO

## ---- Rapier 后端的状态镜像 ----
##
## Rapier 是**权威状态源**：每个子步结束后 position / rotation / 速度都从它读回来。
## 这些镜像只有一个用途 —— 判断"引擎侧是否改过"，改过才推给 Rapier。
## 少了这道判断，每子步把几百个刚体全推一遍纯属白烧。
var rapier_id := 0
var _rp_x := 0.0
var _rp_y := 0.0
var _rp_rot := 0.0
var _rp_vx := 0.0
var _rp_vy := 0.0
var _rp_w := 0.0
var _rp_static := false
## 上次推给 Rapier 的**逐体** CCD 开关（-1 = 未推送）。
## ⚠️ 原来是**世界级**镜像（PWorld._rp_ccd_pushed）：改一个刚体的 ccd 要先把全世界重推一遍。
var _rp_ccd := -1
## 解冻后要不要显式叫醒 Rapier 那边（见 PWorld.unfreeze 的说明）。
var _rp_need_wake := false
## 上次推给 Rapier 的矩形版本号（-1 = 还没推过）
var _rp_rects_rev := -1
## 上次推给 Rapier 的碰撞层/掩码（-1 = 还没推过）。
## ⚠️ 重建碰撞体（rects_rev 变化）会让 Rapier 侧的分组回到默认全 1 ——
##    PWorld 在那处会把这两个镜像打回 -1，逼着重新推一次。
var _rp_layer := -1
var _rp_mask := -1
## 上次推给 Rapier 的重力缩放（运行时可以改，所以要镜像）
var _rp_gravity_scale := 1.0
## 上次推给 Rapier 的外力/力矩。
## ⚠️ Rapier 的 add_force 是**跨步累积**的，引擎的 accum_force 是"当前总力"语义 ——
##    所以推的时候必须"先 reset 再 add"（等价于 set），并且变了才推。
var _rp_fx := 0.0
var _rp_fy := 0.0
var _rp_tq := 0.0
## 矩形分解的版本号：rebuild() 每次 +1。用来判断"要不要把矩形推给 Rapier"。
var rects_rev := 0

## 抓取约束这一子步施加的力与力矩。
##
## ⚠️ 为什么**不**复用 accum_force：那个是**持久累加器**（Box2D 那种，
##    要调用方 clear_forces() 才清）。抓取力如果走它，而调用方直接调
##    PWorld.step() / advance()（demo 就是这么干的），就没人清 ——
##    实测力一帧涨 max_accel*mass = 640000，物体冲过目标后疯狂震荡
##    （终态 x=185.7 而目标是 158，速度 ±397 来回翻）。
##    所以抓取力是"这一子步的约束力"：Grab.apply 覆盖写，PWorld 用完清零。
var grab_force := Vector2.ZERO
var grab_torque := 0.0

## 上一子步**求解之前**的速度。
##
## 接触事件的 approach（"撞得多猛"）必须用它：求解之后接触点的相对法向速度
## 已经被吃掉了（那正是求解器干的事），拿求解后的速度算出来恒等于 0。
var pre_vx := 0.0
var pre_vy := 0.0
var pre_w := 0.0

## 位置修正专用的"伪速度"（split impulse）。
## 它只参与下一次位置积分，不进入真实速度 —— 所以
##   1. 深穿透被推开时不会凭空获得动能；
##   2. 摩擦的上限用的是**真实**法向冲量，不会因为穿透深就把物体粘死。
var pseudo_linear_velocity := Vector2.ZERO
var pseudo_angular_velocity := 0.0

## ---- 外力累加器 ----
##
## ⚠️ 这是**持久**累加器（Box2D 的 ClearForces 模型）：add_force 会一直累积，
## 直到显式 clear_forces()。为什么不自动清空 —— 因为一步里可能切出多个子步，
## "每帧加一次力"若每子步消费一次，力会被放大 N 倍（N 还在变，抖得很明显）。
##
## 约定用法（每帧）：
##     body.clear_forces()
##     body.add_force(Vector2(100, 0))            # 过质心，不产生力矩
##     body.add_force_at(Vector2(0, -50), p)      # 在 p 点推，产生力矩
##     world.step(dt)
var accum_force := Vector2.ZERO
var accum_torque := 0.0

## 执行器每帧覆盖输出，按子步积分；停用时归零，避免累加旧输出或覆盖外力。
var control_force := Vector2.ZERO
var control_torque := 0.0
## 只增加当前约束岛的求解精度，不增加全世界碰撞检测次数。
var additional_solver_iterations := 0
var _rp_solver_iterations := -1

## ---- Teardown 对齐用的字段 ----
##
## 重力缩放（Teardown 的 SetBodyGravityScale）。0 = 不受重力，负数 = 反重力。
var gravity_scale := 1.0
## Teardown 风格的标签：tag -> value（value 可以任意，含 null）。
## 用来让游戏逻辑"按标签找物体"，而不是自己维护一张 id 表。
var tags := {}
## 人类可读的说明（Teardown 的 GetDescription/SetDescription），纯给逻辑用。
var description := ""


func pseudo_velocity_at(world_point: Vector2) -> Vector2:
	var r := world_point - com_world()
	return pseudo_linear_velocity + Vector2(-pseudo_angular_velocity * r.y, pseudo_angular_velocity * r.x)


func clear_pseudo() -> void:
	pseudo_linear_velocity = Vector2.ZERO
	pseudo_angular_velocity = 0.0


func bounding_radius() -> float:
	## AABB 半对角线，用来估算旋转带来的表面线速度（推测接触的边际要用）
	var e := aabb.size
	return 0.5 * sqrt(e.x * e.x + e.y * e.y)


## 最薄尺寸（局部空间，世界单位）—— **CCD 判据的分母**。
##
## ⚠️ 为什么判据要**逐体按尺寸**，而不是一个全局常数（ccd_max_motion = 2.0）：
##    穿模的条件是「每步位移 > 厚度」，而**厚度是每个刚体自己的属性**。
##    业界五个引擎用的是同一个形状的判据 ——
##      · Rapier  `is_moving_fast`: max_point_velocity * dt > 0.5 * ccd_thickness
##      · Box2D v3 `b2_isFast`:      maxMotion > safetyFactor(0.5) * sim->minExtent
##    拿一个全局常数代替，等于假设世界里所有东西都一样厚。
##
## ⚠️ 判据只对 **rects** 取 min：rects 是贪心分解的产物，一条 1 像素宽的矩形
##    就是一条真实的薄壁 —— 那正是能穿过去的那条缝。
##    用 bounding_radius 是**错的**：一根 1x100 的细条外接半径约 50，但它只有 1 像素厚。
## ⚠️ 按 rects_rev 缓存：rebuild() 是 rects 的唯一改动点（pbody.gd 里 rects.clear/append
##    全在它内部），所以版本号一变就重算。没有缓存的话每步对每个刚体都是 O(矩形数)。
var _thin_cache := 1.0
var _thin_rev := -1

func thinnest_extent() -> float:
	if _thin_rev == rects_rev:
		return _thin_cache
	var t := INF
	for r: Rect2 in rects:
		t = minf(t, minf(r.size.x, r.size.y))
	if not is_finite(t) or t <= 0.0:
		# 没有矩形（空刚体 / 还没 rebuild）：退回外接盒。别返回 0 —— 那会让 needs_ccd 恒真。
		t = minf(aabb.size.x, aabb.size.y)
	_thin_cache = maxf(t, 1e-3)
	_thin_rev = rects_rev
	return _thin_cache


## **看得见的尺寸**：所有 shape 局部外接盒并集的**短边**（世界单位）。
##
## ⚠️⚠️ 与 thinnest_extent() 是**两个完全不同的量**，别混：
##   · thinnest_extent() = 贪心分解出的**矩形**里最薄的那条 -> 「能不能穿过去」（CCD 判据）
##   · visible_short_side() = 整个形状的**外接盒**短边        -> 「看不看得见」（灰尘判据）
##
## ⚠️⚠️ 拿 thinnest_extent 去判「这算不算灰尘」会**大面积误伤**，而且症状很刺眼：
##    一个斜切的方块，贪心分解沿**斜边**必然会切出 1 像素宽的矩形 -> thinnest = 1
##    -> 一块几百像素、外接盒 29x29 的**大块**被判成灰尘，玩家看到的是
##    「碎片直接消失」。实测（斜切角用例）：435 像素 / 外接盒 29x29 / 短边 29。
##    根因是两个量的语义不同：厚度决定**能不能钻过去**，外接盒决定**看不看得见**。
func visible_short_side() -> float:
	var r := Rect2i()
	var first := true
	for s in shapes:
		if s == null or s.is_empty():
			continue
		var b: Rect2i = s.local_aabb()
		r = b if first else r.merge(b)
		first = false
	if first:
		# 没有 shape（空刚体）：退回世界 AABB。别返回 0 —— 那会让判据恒真。
		return minf(aabb.size.x, aabb.size.y)
	return float(mini(r.size.x, r.size.y))


## 本步的**表面运动**（世界单位/步）：线速度 + |w| x 外接半径。
## 与 PWorld._motion_of 同一个度量（子步估计用的就是它），只是乘上了 dt。
func motion_per_step(dt: float) -> float:
	return (linear_velocity.length() + absf(angular_velocity) * bounding_radius()) * dt


## 这个刚体这一步**需不需要连续检测**（Rapier / Box2D v3 的判据）。
##
## ⚠️ 这个判据对**小碎片是反向的**：物体越小，变成「快体」所需的速度越低 ——
##    60 Hz 下阈值是 v > 30 x 最薄尺寸，1 像素的碎片只要 30 px/s 就永久满足。
##    PhysX 把这写成了一条明确的失败模式警告（Advanced Collision Detection -> Limitations）：
##    「paper-thin rigid body ... Such an object would always be moving at above its CCD
##      velocity threshold ... It is therefore recommended that paper-thin/tiny objects
##      should be avoided if possible.」
##    所以调用方**不要**拿它去给每个碎片开 CCD —— 它的用途恰恰相反：
##    用来**认出**哪些是「永远满足判据」的灰尘，然后别让它们拖累全世界
##    （见 PWorld.ccd_min_driver_thickness）。
func needs_ccd(dt: float, safety_factor: float = 0.5) -> bool:
	return motion_per_step(dt) > safety_factor * thinnest_extent()

func refresh_com() -> void:
	## 缓存世界质心。求解器里每次算相对速度都会用到它，
	## 每帧重算 3000+ 次 Vector2 旋转在 GDScript 里是实打实的开销。
	_com_cache = position + local_com.rotated(rotation)

func com_world() -> Vector2:
	return _com_cache


func to_world(p: Vector2) -> Vector2:
	return position + p.rotated(rotation)


func to_local(p: Vector2) -> Vector2:
	return (p - position).rotated(-rotation)


func velocity_at(world_point: Vector2) -> Vector2:
	## v + w x r，2D 里叉乘退化为 (-w*r.y, w*r.x)
	var r := world_point - com_world()
	return linear_velocity + Vector2(-angular_velocity * r.y, angular_velocity * r.x)


func apply_impulse(impulse: Vector2, world_point: Vector2) -> void:
	if is_static or inv_mass <= 0.0:
		return
	linear_velocity += impulse * inv_mass
	angular_velocity += inv_inertia * (world_point - com_world()).cross(impulse)


## 冲量：**立即**改速度，不乘 dt。过质心，不产生力矩。
func apply_central_impulse(impulse: Vector2) -> void:
	if is_static or inv_mass <= 0.0:
		return
	linear_velocity += impulse * inv_mass


## 纯力矩冲量（角冲量）。
func apply_torque_impulse(t: float) -> void:
	if is_static or inv_inertia <= 0.0:
		return
	angular_velocity += inv_inertia * t


## ---- 动力学量 ----
##
## ⚠️ 符号约定（2D，Godot 的 y 轴向下）：
##   · 角速度 ω 为正 = 屏幕上**顺时针**转；
##   · 二维叉积 a.cross(b) = a.x*b.y - a.y*b.x 在这个坐标系下同样顺时针为正；
##   · 所以下面所有角动量的符号与 ω 一致，不需要额外取负。
##
## ⚠️ 静态体的 mass / inertia 是 0，动量和动能都返回 0 —— 这是对的：
##   静态体吸收冲量但不运动，不参与动量交换。


## 线动量 p = m·v。
##
## 二维里刚体的总线动量恒为 m·v_com，与参考点无关（转动不贡献线动量）。
func linear_momentum() -> Vector2:
	return linear_velocity * mass


## 角动量 L = I·ω，关于**质心**。
##
## 关于其它点要用 angular_momentum_about() —— 那不是加个常数，而是多一项 r × p。
func angular_momentum() -> float:
	return inertia * angular_velocity


## 关于世界坐标中某点的角动量：L = I_com·ω + r × (m·v_com)，r 从该点指向质心。
##
## 用途：判断物体"绕某个轴转不转"。一块木板绕钉住的端点摆动时，
## 关于**钉子**的角动量才有意义，关于质心算出来的不是同一回事。
func angular_momentum_about(world_point: Vector2) -> float:
	var r := com_world() - world_point
	return inertia * angular_velocity + r.cross(linear_velocity * mass)


## 动能 E = ½m|v|² + ½Iω²（平动 + 转动）。
func kinetic_energy() -> float:
	return 0.5 * mass * linear_velocity.length_squared() 		+ 0.5 * inertia * angular_velocity * angular_velocity


## 一次性"推一下"：等价于让力 force 作用 dt 秒。
## 只在确实想要瞬时推力时用它；**持续力请用 add_force**（见 accum_force 的说明）。
func apply_force_once(force: Vector2, world_point: Vector2, dt: float) -> void:
	apply_impulse(force * dt, world_point)


## 施加**过质心**的持久力（不产生力矩）。
##
## ⚠️ 施力会**唤醒**刚体（与 Box2D 一致）。少了这一步会出很隐蔽的 bug：
## 一个刚被加进来的物体速度还很小时就会被判为"慢"而睡着，
## 于是外力**再也施加不上**（实测 vx 恒为 0）。反过来，一直加力就等于不睡，
## 这是调用方的责任。
func add_force(force: Vector2) -> void:
	if force == Vector2.ZERO:
		return
	accum_force += force
	_wake_force()


## 在世界坐标点 world_point 处施加持久力 —— 该点不在质心时会同时产生力矩。
func add_force_at(force: Vector2, world_point: Vector2) -> void:
	if force == Vector2.ZERO:
		return
	accum_force += force
	accum_torque += (world_point - com_world()).cross(force)
	_wake_force()


## 施加持久力矩（纯转动）。
func add_torque(t: float) -> void:
	if t == 0.0:
		return
	accum_torque += t
	_wake_force()


func _wake_force() -> void:
	if not is_static:
		awake = true
		sleep_timer = 0.0


## 清空外力累加器。**每帧开头调一次**（见 accum_force 的说明）。
func clear_forces() -> void:
	accum_force = Vector2.ZERO
	accum_torque = 0.0
	control_force = Vector2.ZERO
	control_torque = 0.0


## 从静态转回动态（Shift 绘制是"先摆好、松手才变成刚体"）。
## 静态期间跳过了质量属性计算，所以这里必须做一次完整 rebuild。
func make_dynamic() -> void:
	is_static = false
	awake = true
	sleep_timer = 0.0
	rebuild(shapes)


func make_static() -> void:
	is_static = true
	awake = true
	mass = 0.0
	inertia = 0.0
	inv_mass = 0.0
	inv_inertia = 0.0
	local_com = Vector2.ZERO


## 用像素 Shape 重建质量属性与碰撞矩形。
## 组合律：并行的组合形状用平行轴定理逐块累加。
## dirty_rect：本次改动**已知的**局部像素范围（可空）。
##
## ⚠️⚠️ 它决定渲染器能不能走"只重建脏块"的快路径：
##    给了 -> 用 mark_dirty_range（**记录了改了哪块**，渲染器只重建那几块）
##    没给 -> 用 touch()（"内容变了但不知道哪里"，渲染器只能全量重建）
##
##    默认没给是**有意的保守**：绝大多数调用方确实不知道范围，
##    全量重建虽然慢但一定对。知道范围的（fracture）必须显式传进来，
##    否则 768x100 的地面每笔都要重建 24 块（~54 ms）而不是 1 块（~7 ms）。
## 第一个非空像素的材质 id（没有像素返回 -1）。静态体取材质属性用它。
static func _first_material(shape_list: Array) -> int:
	for s in shape_list:
		if s == null:
			continue
		for k: int in s.chunks:
			var c = s.chunks[k]
			if c.occ == 0:
				continue
			var i := Bits.first_bit_index(c.occ)
			return c.mat[i]
	return -1


## dirty_rects：**按 shape** 的脏范围（shape -> Rect2i）。给了它就用它，没给的 shape
## 回落 `dirty_rect`（再没有就 touch() = 全量）。
##
## ⚠️ 为什么需要"按 shape"：`dirty_rect` 是**一个**矩形，而它会套给 shape_list 里**所有**
##    shape —— 不同 shape 的局部坐标系不同，一个矩形不可能同时是它们各自的正确范围。
##    单 shape 的刚体（绝大多数）用 dirty_rect 就够了；多 shape 只能给脏矩形，或者保守退回
##    touch()。契约不变：**矩形必须覆盖该 shape 本次改动的全部像素**（可以更大，不能更小）。
func rebuild(shape_list: Array, density_of: Callable = Callable(),
		max_rects: int = 64, dirty_rect: Rect2i = Rect2i(),
		friction_of: Callable = Callable(), restitution_of: Callable = Callable(),
		dirty_rects: Dictionary = {}, changed_chunks: Variant = null) -> void:
	# 几何变了 —— Rapier 后端据此决定要不要重建碰撞体（见 _rp_rects_rev）。
	# 放在 rebuild() 里是**源头修**：破坏 / 擦除 / 绘制 / 分裂全都走这里。
	rects_rev += 1
	shapes = shape_list
	for s0 in shape_list:
		if s0 != null:
			s0.owner_body = self     # Teardown 的 GetShapeBody 靠它
	# ⚠️⚠️ **内容变了，必须让渲染器知道** —— 这里是最可靠的 choke point：
	#     破坏 / 擦除 / 绘制 / 将来任何新路径，改完内容都会调 rebuild()。
	#
	#     为什么不能只靠 PixelShape.set_pixel 里那句 mark_dirty()：
	#     原生破坏（C++ 直接改块位图）和 Brush 的批量写入都**不经过 set_pixel** ——
	#     revision 不变，渲染器 sync() 看到 _rev 没变就跳过贴图重建。
	#     表现是「右键擦掉了，画面上却还在，直到生成新碎片才刷新」
	#     （新碎片是新 body id，_rev 里查不到，必然重建 —— 所以只有它们正常显示）。
	#
	#     我第一版是在调用方补（_damage_world），那是**在症状处打补丁**：
	#     当场就漏掉了 PixelEditor 那条路，用户第二次报同一个 bug 才找到。
	#     放在 rebuild() 里才是源头修 —— 调用方不可能再漏。
	#
	#     代价：擦地形时每帧都会 rebuild，于是每帧 touch 一次 —— 这是对的，
	#     内容确实每帧都在变。不擦的时候不会调到这里。
	for s1 in shape_list:
		if s1 == null:
			continue
		var dr: Rect2i = dirty_rects.get(s1, dirty_rect)
		if dr.size.x > 0 and dr.size.y > 0:
			s1.mark_dirty_range(dr)           # 已知范围 -> 渲染器可只重建脏块
		else:
			s1.touch()                        # 不知道范围 -> 渲染器只能全量
	rects.clear()
	# 静态体不需要质量属性（逆质量恒为 0，质心也不参与求解）。
	# 擦地形时每帧都会 rebuild，跳过逐像素扫描是实打实的收益。
	if is_static:
		for s0 in shape_list:
			var r0: GreedyRects.Result = GreedyRects.decompose(s0, max_rects)
			for rect0: Rect2 in r0.rects:
				rects.append(rect0)
		mass = 0.0
		inertia = 0.0
		inv_mass = 0.0
		inv_inertia = 0.0
		local_com = Vector2.ZERO
		# 静态体不算质量（跳过逐像素扫描是实打实的收益），密度给默认值：
		# 万一之后被 rb_body_set_type 变成动态体，Rapier 会按 1.0 算质量，而不是 0。
		density = 1.0
		# ⚠️ 静态体跳过逐像素扫描（性能），但**材质属性仍然要有**：
		#    否则地面永远用默认摩擦/恢复系数，材质里配的值完全不生效 ——
		#    实测症状是"球 0.9 + 地面 0.0 取平均 = 0.45"，看起来像恢复系数没接上。
		#    这里只取**第一个非空像素**的材质（静态地形通常整块同材质），代价 O(块数)。
		var mat := _first_material(shape_list)
		if mat >= 0:
			if friction_of.is_valid():
				friction = friction_of.call(mat)
			if restitution_of.is_valid():
				restitution = restitution_of.call(mat)
		refresh_com()
		update_aabb()
		return
	# ⚠️⚠️ **质量属性只算一遍**。这里原来对同一个 shape 调了两次 MassProps.compute
	#    （第一遍求总质量/总质心，第二遍求绕总质心的惯性）—— 而它是**逐像素**扫的。
	#    静态体走上面的早返回，所以这个坑只在**动态体**上发作，而动态体恰恰是
	#    fracture 生成的碎片：768x100 地面被一刀切开，碎片 ~3 万像素，
	#    两遍就是 30~40 ms —— 用户报的"生成新实体那一下明显卡顿"就是这个。
	#    两遍的输入完全相同，所以合并成一遍是**等价**的（不是近似）。
	var m_total := 0.0
	var com := Vector2.ZERO
	var inertia_c := 0.0
	var n_px := 0
	var f_sum := 0.0
	var r_sum := 0.0
	var props: Array = []
	for s in shape_list:
		# changed_chunks：调用方声明"只改了这些块"-> 质量属性只重算它们（见 MassProps.compute）
		var p: MassProps.Props = MassProps.compute(s, density_of, friction_of, restitution_of, changed_chunks)
		props.append(p)
		m_total += p.mass
		com += p.com * p.mass
		n_px += p.pixel_count
		f_sum += p.fric_sum
		r_sum += p.rest_sum
	var had_mass := m_total > 0.0
	if had_mass:
		com /= m_total
	for i in shape_list.size():
		var p2: MassProps.Props = props[i]
		# 平行轴定理：把每块的惯性搬到自己质心之外
		inertia_c += p2.inertia + p2.mass * p2.com.distance_squared_to(com)
		var r: GreedyRects.Result = GreedyRects.decompose(shape_list[i], max_rects)
		for rect: Rect2 in r.rects:
			rects.append(rect)
	mass = m_total
	inertia = inertia_c
	# 平均密度 = 质量 / 像素数（材质逐像素不同时取平均值：Rapier 的碰撞体密度是
	# 均匀的，用平均值能让**总质量**精确对上，惯量分布的差异可以忽略）。
	density = m_total / float(n_px) if n_px > 0 else 1.0
	# 摩擦/恢复系数：同样是**逐像素加权平均**（与密度一个口径）。
	#
	# ⚠️⚠️ **没给 Callable 时不能写 0** —— 这条是踩过的坑：
	#    MassProps 在没给摩擦/恢复 Callable 时 f_sum/r_sum 恒为 0，而这里以前**无条件**
	#    写 `friction = f_sum / n_px` -> 摩擦与恢复系数被**静默清成 0**。
	#    破坏路径里 detach / fracture_pixels / ensure_connected 都没传这两个 Callable，
	#    于是"打一次洞，那块石头就变滑"（demo 材质表的石头 friction 0.5 -> 0）。
	#    现在：没给 = **保持原值**（"我不知道"≠"它是 0"）。
	#    ⚠️ 密度那一半不是同一个问题：`density_of` 无效时的语义是"全部按 1.0 算"
	#    （文档写明了"质量 == 像素数"），所以那里照旧。
	var has_fric := friction_of.is_valid()
	var has_rest := restitution_of.is_valid()
	if n_px > 0:
		if has_fric:
			friction = f_sum / float(n_px)
		if has_rest:
			restitution = r_sum / float(n_px)
	local_com = com if had_mass else Vector2.ZERO
	if is_static:
		inv_mass = 0.0
		inv_inertia = 0.0
	else:
		inv_mass = 0.0 if mass <= 0.0 else 1.0 / mass
		inv_inertia = 0.0 if inertia <= 0.0 else 1.0 / inertia
	refresh_com()
	update_aabb()


func update_aabb() -> void:
	if rects.is_empty():
		aabb = Rect2(com_world(), Vector2.ZERO)
		swept_aabb = aabb
		return
	var r0: Rect2 = rects[0]
	var box := _rect_world_aabb(r0)
	for i in range(1, rects.size()):
		box = box.merge(_rect_world_aabb(rects[i]))
	aabb = box
	swept_aabb = box


## 本步内可能扫过的范围（线性位移 + 旋转扫过的半径）
func compute_swept_aabb(dt: float) -> void:
	var motion := linear_velocity.length() * dt + absf(angular_velocity) * bounding_radius() * dt
	swept_aabb = aabb.grow(motion)


func _rect_world_aabb(local_rect: Rect2) -> Rect2:
	var h := local_rect.size * 0.5
	var c := to_world(local_rect.position + h)
	# 旋转后的 AABB 半径
	var ex := absf(h.x * cos(rotation)) + absf(h.y * sin(rotation))
	var ey := absf(h.x * sin(rotation)) + absf(h.y * cos(rotation))
	return Rect2(c - Vector2(ex, ey), Vector2(ex, ey) * 2.0)


## ---------- 凸包（多边形碰撞箱拟合）—— **与 aabb 并列**的另一种包围体 ----------
##
## AABB 是轴对齐的，刚体一转它就按外接半径膨胀（100x8 的板转 45 度 -> 76x76 的空盒子）。
## 凸包跟着刚体一起转，筛起来是紧的 —— 代价是判定 O(顶点数)，比"两个区间相交"贵。
##
## ⚠️⚠️ 为什么**惰性**，而不是像 aabb 那样在 update_aabb() 里一起算：
##    update_aabb() 是**每子步对每个动态刚体**都跑的（PWorld 里那一圈），
##    而凸包要逐顶点做旋转。3000 个碎片的压力场景下，那是一条纯粹白烧的开销 ——
##    而绝大多数项目根本不问凸包。所以这里"谁问谁付"：
##    读的时候按 (位置, 旋转, rects_rev) 判一次新鲜度，三者都没变就直接返回缓存。
##    ⚠️ 三个判据缺一不可：凸包同时依赖**形状**（rects）和**位姿**。
##    （只查 rects_rev 会在刚体移动后返回旧凸包；只查位姿会在破坏后返回旧凸包 ——
##      两种都是静默错，而且错的方向是"包围体不对"，很难往缓存上想。）
var _hull_local := PackedVector2Array()
var _hull_local_rev := -1
var _hull_world := PackedVector2Array()
var _hull_world_rev := -1
var _hull_world_pos := Vector2(INF, INF)
var _hull_world_rot := INF


## 局部空间的凸包。
## ⚠️ 来源是 **rects**（与 aabb 同一个来源）：贪心分解是**精确覆盖**，
##    所以它逐点等于像素集的凸包；用了 decompose_proxy() 的刚体会跟着变大（那是代理的体积）。
func local_hull() -> PackedVector2Array:
	if _hull_local_rev == rects_rev:
		return _hull_local
	_hull_local = HullFit.hull_of_rects(rects)
	_hull_local_rev = rects_rev
	return _hull_local


## **已经算好的**局部凸包；没算过（或形状改过）时返回空数组 —— **绝不触发重算**。
##
## 给"剔除"这类**不值得为它付冷启动代价**的地方用（Query.raycast 就是）：
## 算过就用，没算过就退化成 AABB。语义是"缓存探针"，不是"取凸包"。
##
## ⚠️⚠️ 为什么查询不能直接调 local_hull()：算一次的代价随**形状尺寸**走
##    （768x100 的地面实测 5.05 ms，见 tests/bench_hull.gd），而它一次只省下
##    "这条射线少走几十格 DDA"（约 0.2 ms）。地形每被擦一笔就作废一次 ——
##    于是"为了剔除而现算"在破坏类玩法里是**净亏**，而且亏在射线那一帧（掉帧）。
##    契约：剔除**只影响快慢**，不影响结果（凸包是保守外接）。
func cached_local_hull() -> PackedVector2Array:
	return _hull_local if _hull_local_rev == rects_rev else PackedVector2Array()


## 世界空间的凸包。**包围体，不是碰撞形状** —— 凹形状的凹角会被填平，别拿它去碰撞。
## 用途：查询粗筛（Query.raycast）、调试可视化、游戏层要"比 AABB 紧的轮廓"。
func world_hull() -> PackedVector2Array:
	if _hull_world_rev == rects_rev and _hull_world_pos == position \
			and _hull_world_rot == rotation:
		return _hull_world
	var lh := local_hull()
	var c := cos(rotation)
	var s := sin(rotation)
	var out := PackedVector2Array()
	out.resize(lh.size())
	for i in lh.size():
		var p := lh[i]
		out[i] = Vector2(position.x + p.x * c - p.y * s, position.y + p.x * s + p.y * c)
	_hull_world = out
	_hull_world_rev = rects_rev
	_hull_world_pos = position
	_hull_world_rot = rotation
	return _hull_world


## 世界坐标点在凸包内吗（**保守**：凸包比像素集大，返回 true 不代表那里真有像素）。
func hull_contains(world_point: Vector2) -> bool:
	return HullFit.contains(world_hull(), world_point)


## 休眠判据：质心线速度 + **最快点**的表面速度（|ω| * 包围半径）。
##
## ⚠️ 这里曾经是"|v| <= 阈值 且 |ω| <= 另一个**绝对**角速度阈值(0.15 rad/s)"。
## 那个绝对阈值对**小碎块**过于苛刻：6x6 的碎块 ω=0.2 rad/s 时边缘线速度只有
## 0.6 px/s（肉眼完全静止），却超过 0.15 —— 它的 sleep_timer 于是每帧被清零，
## 而岛的休眠取**岛内最小值**，结果一整个大岛永远睡不着。
##
## 实测（tests/diag_sleep.gd）：300 碎块落定 16.7 秒后，335 个里 **322 个**
## 线速度已经在 0~2 px/s，却因为少数几个 ω=0.16~2.26 而全岛失眠；
## 稳定期帧时间 92.8 ms（本该是个位数）。
##
## 换成表面速度之后判据与尺寸无关，而且与 _compute_substeps 用的是**同一个量**。
func is_slow(lin_thresh: float, ang_thresh: float) -> bool:
	if linear_velocity.length_squared() > lin_thresh * lin_thresh:
		return false
	return absf(angular_velocity) * bounding_radius() <= ang_thresh
