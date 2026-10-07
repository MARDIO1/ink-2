extends RefCounted
## 关节（约束）—— Rapier 的冲量关节在 GDScript 侧的把手。
##
## 五种类型：
##   HINGE   铰链：只剩一个转动自由度（门、轮子、摆）
##   SLIDER  滑轨：只剩沿轴平移（活塞、抽屉）
##   WELD    焊接：完全锁死（把两块拼成一块）
##   ROPE    绳：只限制**最大**距离（吊桥、缆绳）—— 不可伸长
##   SPRING  弹簧：拉向静止长度（悬挂、缓冲）
##
## ## 这个对象存什么、不存什么
##
## 求解全在 Rapier 里，这里只存**参数**（与 PBody 的 _rp_* 镜像同构）：
## PWorld 每子步把变了的参数翻译成命令流推过去。
##
## 运动量（movement / speed）**不占命令流** —— 它由刚体位姿直接算出来：
##   · 铰链 = 相对转角相对**创建时刻**的变化量；
##   · 滑轨 = 两个锚点连线在轴上的投影；
##   · 绳 / 弹簧 = 两个锚点的距离。
## 这与 Rapier 侧关节帧的设零方式一致（见 rapier_bridge/src/lib.rs 的 rb_joint_new）。
##
## ⚠️ 两个锚点是**各自刚体的局部坐标**（不是世界坐标）：世界坐标在刚体一动就过期了。
##    创建时由 PWorld 用 to_local 换算好。

const HINGE := 0
const SLIDER := 1
const WELD := 2
const ROPE := 3
const SPRING := 4

## 马达模式
const MOTOR_OFF := 0
const MOTOR_VELOCITY := 1
const MOTOR_POSITION := 2

var world = null          ## PWorld（弱引用；世界活着关节才活着）
var kind := HINGE
var body_a = null         ## PBody；**null = 静态世界**
var body_b = null         ## PBody；**null = 静态世界**
var rapier_id := 0        ## Rapier 侧的关节 id（0 = 还没建出来）

var local_anchor_a := Vector2.ZERO
var local_anchor_b := Vector2.ZERO
## 滑轨的轴（**世界系**，创建时定下；Rapier 侧两端各自转到自己的局部系）
var axis := Vector2.RIGHT
## 绳 = 最大长度；弹簧 = 静止长度
var rest_length := 0.0
## 弹簧刚度 / 阻尼（Rapier 的 ForceBased 模型：力 = 刚度 × 误差 + 阻尼 × 速度误差）
var stiffness := 0.0
var damping := 0.0

## 限位（铰链是角度，滑轨是距离）。只有 HINGE / SLIDER 支持。
var limits_enabled := false
var min_limit := 0.0
var max_limit := 0.0

## 马达
var motor_mode := MOTOR_OFF
var motor_target := 0.0        ## 速度模式 = 目标速度；位置模式 = 目标位置/角度
var motor_max_force := 0.0     ## 0 = 禁用（参考 API 里 "strength 0 = 关闭" 的语义）
var motor_stiffness := 0.0
var motor_damping := 10.0

## 两个被这个关节连着的刚体之间**要不要生成接触**。默认 **false（不碰）**。
##
## 为什么默认关：关节和接触是**两个求解器**，目标相反 ——
##   · 关节按创建时的相对位姿把两端按住；
##   · 接触要把重叠的体素推开。
## 于是"焊在一起但体素重合"的两个刚体会**一直抽搐**（实测：速度在 0~40 之间来回抖，
## 关节承受的冲量是静止载荷的几十倍）。关掉接触，关节才是唯一权威。
##
## 这与 Box2D 的 `collideConnected = false` 是同一个默认值。
## 确实需要"连在一起还互相碰"（比如带限位的门要挡住身体）时再打开它。
var contacts_enabled := false
## 推给 Rapier 的镜像（Rapier 的默认是 **true** —— 生成接触）
var _rp_contacts := true

## 关节求解**软度**：自然频率（Hz）。**0 = 用 Rapier 默认**（joint_defaults）。
##
## 频率越高越硬（约束误差越小、越少迭代就收敛），越低越"软"（允许漂移，看起来像
## 带弹性的连接）。**焊接仍然是焊接**（自由度照样全锁）—— 软度只决定"违约被拉回的速度"。
##
## ⚠️ 这是**求解器参数**，不是关节类型。想诊断它调得对不对用 anchor_error() /
## angle_error()（见 R3 的诊断接口）。
var solver_frequency := 0.0
## 阻尼比（只有 solver_frequency > 0 时才用得上；默认 1.0 = 临界阻尼）。
var solver_damping := 1.0
## 推给 Rapier 的镜像（-1 = 从没推过；0 = 已推"回默认"）
var _rp_soft_freq := -1.0

## 断裂阈值：约束冲量（**力 × 时间步**）超过它就断。INF = 不断。
##
## 比的是**线性冲量**（锚点处的约束反力）—— 铰链也一样：挂着东西的铰链，
## 载荷几乎全在"锁住锚点"的线性自由度上，而自由转动那一行是 0。
## 角冲量（马达/限位顶住时才非零）存在 last_angular_impulse 里，只作诊断。
##
## ⚠️ 冲量随 dt 变（子步越小冲量越小），要跨帧率稳定就用 break_impulse ≈ 目标力 × 固定 dt。
var break_impulse := INF
## 是否已经断掉（只有"冲量超阈值"才置位 —— 主动移除走 active）
var broken := false
## 是否还活着（主动移除 / 刚体被删 / 断裂都会置 false）
var active := true

## 上一步读回的约束冲量（只有设了 break_impulse 的关节才读）
var last_linear_impulse := 0.0
var last_angular_impulse := 0.0
var last_impulse := 0.0        ## 用于断裂判定的那一个（铰链 = 角，其余 = 线）

## 创建时刻两个刚体的朝向 —— movement() 的零点
var _rot_a0 := 0.0
var _rot_b0 := 0.0

## 推给 Rapier 的镜像（"变了才推"用）
var _rp_limits_on := false
var _rp_min := 0.0
var _rp_max := 0.0
var _rp_motor_mode := MOTOR_OFF
var _rp_motor_target := 0.0
var _rp_motor_force := 0.0
var _rp_motor_stiffness := 0.0
var _rp_motor_damping := 10.0


# ============================================================ 运动量

func _rot_a() -> float:
	return 0.0 if body_a == null else body_a.rotation


func _rot_b() -> float:
	return 0.0 if body_b == null else body_b.rotation


func anchor_a_world() -> Vector2:
	return local_anchor_a if body_a == null else body_a.to_world(local_anchor_a)


func anchor_b_world() -> Vector2:
	return local_anchor_b if body_b == null else body_b.to_world(local_anchor_b)


## 滑轨的轴在当前时刻的世界方向（轴跟着刚体 A 转）。
func world_axis() -> Vector2:
	return axis.rotated(_rot_a() - _rot_a0)


func _vel_at_a() -> Vector2:
	if body_a == null:
		return Vector2.ZERO
	return body_a.velocity_at(anchor_a_world())


func _vel_at_b() -> Vector2:
	if body_b == null:
		return Vector2.ZERO
	return body_b.velocity_at(anchor_b_world())


## 关节当前的"位置"：铰链是角度（弧度），滑轨是距离，绳/弹簧是两点距离，焊接恒为 0。
##
## **符号约定**：一端是静态世界（body 传 null）时，读数是"刚体相对世界"（往正方向动 = 正数）；
## 两个真刚体之间是 **B 相对 A**（谁当参考系由参数顺序决定）。
func movement() -> float:
	match kind:
		HINGE:
			return wrapf((_rot_b() - _rot_b0) - (_rot_a() - _rot_a0), -PI, PI)
		SLIDER:
			return (anchor_b_world() - anchor_a_world()).dot(world_axis())
		ROPE, SPRING:
			return anchor_a_world().distance_to(anchor_b_world())
		_:
			return 0.0


## 关节当前的运动速率：铰链是相对角速度，滑轨是沿轴的相对速度，绳/弹簧是距离变化率。
func speed() -> float:
	match kind:
		HINGE:
			var wa: float = 0.0 if body_a == null else body_a.angular_velocity
			var wb: float = 0.0 if body_b == null else body_b.angular_velocity
			return wb - wa
		SLIDER:
			return (_vel_at_b() - _vel_at_a()).dot(world_axis())
		ROPE, SPRING:
			var d: Vector2 = anchor_b_world() - anchor_a_world()
			var len := d.length()
			if len < 1e-6:
				return 0.0
			return d.dot(_vel_at_b() - _vel_at_a()) / len
		_:
			return 0.0


# ============================================================ 约束误差（诊断）

## ⚠️ 这些量**不是** Rapier 内部那个速度级约束误差 —— 那个不对外暴露（只作为 rhs 活在求解器里，
##    每步重建，见 rapier_bridge/src/lib.rs 的 op 30 说明）。它们回答的是**位姿级**的问题：
##    "约束到底把两个锚点 / 两个朝向按住了吗"。也就是 R3 里那个"锚点误差 / 角差"，与求解器同源
##    （位姿就是约束的积分结果），只是**不是**同一个数学对象 —— 别拿它当求解器的内部残差用。
##
## ⚠️ 采样时机决定你看到什么：子步末读一次只看到"步末"值；要刻画**振动**请按**步**采样
##    （PWorld.step() 之后，或节点层的 PixelWorld.physics_step_finished 信号里）。
##
## ⚠️ 代价：每关节每次约 10 次 GDScript 操作（项目经验值 ~5~10 us），**零原生调用**。
##    所以别把它塞进每子步的热循环 —— 需要时再读。
##
## ⚠️ 为什么不做成原生 op：Rapier 每关节每子步一次往返实测 ~2.8 us（见 dd8682d），
##    10 个关节 x 29 子步 = 0.8 ms/步，而这里 0 次调用就拿到了同一个量。

## 锚点误差（世界向量，px）：约束有没有把两个锚点按在一起。
## 静态端（body == null）用的是世界坐标锚点，公式照样成立。
func anchor_error() -> Vector2:
	return anchor_b_world() - anchor_a_world()


func anchor_error_len() -> float:
	return anchor_b_world().distance_to(anchor_a_world())


## 角度误差（弧度）：WELD / HINGE 锁住的那一行。
##
## ⚠️ **不能复用 movement()**：WELD 的 movement() 恒为 0（它没有自由度），
##    而那恰恰是"焊接被拉开多少角度"最需要看的地方。
func angle_error() -> float:
	return wrapf((_rot_b() - _rot_b0) - (_rot_a() - _rot_a0), -PI, PI)


## 滑轨专用：**垂直于轴**的漂移（被锁住的 LinY 那一行）。
## 沿轴的分量是 movement()（那是它的自由自由度），这里只给被锁住的那部分。
func lateral_error() -> Vector2:
	var d := anchor_b_world() - anchor_a_world()
	var ax := world_axis()
	return d - ax * d.dot(ax)


# ============================================================ 参数

## 限位。铰链是角度（弧度），滑轨是距离（沿轴，创建时为 0）。
## ⚠️ 只有 HINGE / SLIDER 支持：绳的最大长度、弹簧的静止长度是**构造参数**
##    （rest_length），焊接没有自由度 —— 对它们设限位会覆盖掉这些语义。
func set_limits(min_v: float, max_v: float) -> void:
	if kind != HINGE and kind != SLIDER:
		push_error("PJoint.set_limits：只有铰链/滑轨有限位（绳/弹簧用 rest_length）")
		return
	if min_v > max_v:
		push_error("PJoint.set_limits：min 必须 <= max（要取消限位请用 clear_limits()）")
		return
	limits_enabled = true
	min_limit = min_v
	max_limit = max_v


func clear_limits() -> void:
	limits_enabled = false


## 速度马达：让关节以 target_vel 运动（铰链 rad/s，滑轨 px/s），最多出 max_force 的力/力矩。
## max_force = 0 = 禁用（参考 API 里 "strength 0 = 关闭" 的语义）。
##
## damp 是速度误差的修正速率（越大越硬），必须 > 0 —— 0 会让 Rapier 的马达约束算出 NaN。
## ⚠️ Rapier 的马达是**软约束**：稳态速度会差一点点（实测目标 3.0 时，
##    damp=10 -> 2.71、100 -> 2.97、1000 -> 2.996）。默认取 100（误差 ~1%）；
##    要"绝对准"就往上加，代价是数值上更硬、更容易抖。
func set_motor_velocity(target_vel: float, max_force: float, damp := 100.0) -> void:
	if damp <= 0.0:
		push_error("PJoint.set_motor_velocity：damping 必须 > 0")
		return
	motor_mode = MOTOR_VELOCITY
	motor_target = target_vel
	motor_max_force = max_force
	motor_damping = damp


## 位置/角度伺服：走到 target（铰链是角度，滑轨是距离）。
## stiff > 0 才有意义（Rapier 的 AccelerationBased 模型：a = 刚度 × 误差 + 阻尼 × 速度误差）。
func set_motor_target(target: float, max_force: float, stiff := 100.0, damp := 10.0) -> void:
	if stiff <= 0.0:
		push_error("PJoint.set_motor_target：stiffness 必须 > 0")
		return
	motor_mode = MOTOR_POSITION
	motor_target = target
	motor_max_force = max_force
	motor_stiffness = stiff
	motor_damping = damp


func motor_off() -> void:
	motor_mode = MOTOR_OFF


## 设置关节求解**软度**：自然频率（Hz）+ 阻尼比。**frequency <= 0 = 调回 Rapier 默认**。
##
## 用途：默认的关节很硬（约束误差极小），但在"长链 / 大质量比 / 迭代次数被压"的场景里
## 会表现为抖动或过冲；调低频率可以让它变成"带弹性的连接"（代价是锚点会漂）。
## 反过来，想让锚点更死就调高（但迭代次数不够时调高也没用 —— 见
## PWorld.rp_joint_solver_iterations）。
##
## 实测判据：tests/validation_joint_solver.gd 用 anchor_error() 量"漂多少"。
func set_solver_softness(frequency: float, damping := 1.0) -> void:
	solver_frequency = frequency
	solver_damping = damping


## 断开这个关节（刚体照旧，只是不再连在一起）。
func remove() -> void:
	if world != null:
		world.remove_joint(self)


func is_broken() -> bool:
	return broken


func is_active() -> bool:
	return active


## 上一步的约束冲量（用于断裂判定的那一个：铰链 = 角冲量，其余 = 线性冲量模长）。
func impulse() -> float:
	return last_impulse
