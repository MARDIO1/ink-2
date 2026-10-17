@tool
extends Resource
## 一整套**物理旋钮**（单一真源）：把散在 @PWorld@ / @PixelWorld@ / 门面 opts 里的可调参数
## 收进一个 Resource，上层（游戏）只维护一份 .tres，用 @PhysicsConfig.apply()@ **一处下发**。
##
## ## 为什么要有它
##
## 在这之前同一个旋钮最多有**三个家**：PWorld 的字段、PixelWorld 的 @export、
## 门面的 opts 表 —— 三份默认值各自演化，而"现值是多少"要靠读三个文件才能回答。
## 更糟的是下发方式：每个调用点自己写 `world.set(name, value)`，
## 名字写错时 **Object.set() 是静默失败**（本仓库最怕的失败方式，甲方踩过：
## 改了 @export，world 那边还是 0）。
##
## 现在：
##   · 字段名**就是** PWorld 的字段名（不造第二套命名，也就不需要映射表）；
##   · @apply()@ 逐字段下发，**对不上的字段吵闹地报出来**（返回值 + push_error）；
##   · @capture()@ / @diff()@ 与 apply 对称，探针与闸门用它做"现值快照 / 逐项对照"。
##
## ## 用法
##
## ```gdscript
## # 游戏侧：一份 .tres，一处下发
## world.apply_config(physics)          # 或 physics.apply(world)
## # 节点侧：把 .tres 拖到 PixelWorld.physics 上即可（见 PixelWorld.push_physics_settings）
## ```
##
## ⚠️ 默认值 = **PWorld 现在的默认值**（行为不变）。闸门
##    tests/validation_physics_config.gd 钉这一条：拿一份全新配置下发到全新世界，
##    世界的每一个字段都必须**逐位不变**。
##
## ⚠️ 不收进来的东西（刻意）：`material_density` / `material_friction` /
##    `material_restitution` 三张**材质表**（它们是逐材质的表，不是标量旋钮，
##    由 PixelMaterial 资源负责），以及 `last_*` / `bp_*` / `_rp_*` 这些**运行时状态与镜像**。

#region 世界
## 重力（世界单位/秒²）。像素世界里 +y 朝下。
@export var gravity := Vector2(0.0, 600.0)
## 固定步长（秒）。累加器按它切子步 —— 改它会改变所有手感与数值结果。
@export var fixed_dt := 1.0 / 60.0
## 每帧最多补几步（防"死亡螺旋"）。
@export var max_substeps := 4
## 动态刚体上限（超过就淘汰最远的；0 = 不限）。见 PWorld.max_dynamic_bodies。
@export var max_dynamic_bodies := 400
## 长度单位（推给 Rapier 的 length_unit；像素尺度下通常保持 1.0）。
@export var rp_length_unit := 1.0
@export_group("接触事件")
## 是否收集接触事件（关掉省一笔开销；破坏判据要用它）。
@export var contact_events_enabled := false
## 是否计算接触应力（强度判据用）。
@export var contact_stress_enabled := true
## 每次 step 最多保留多少个接触。
@export var max_contacts := 512
## 接触点是否带上冲量（破坏/反馈要看"打多重"时需要）。
@export var fill_contact_impulses_enabled := true
#endregion

#region 休眠
@export var sleeping_enabled := true
## 线速度低于它才可能睡着。
@export var sleep_linear := 6.0
## 表面速度（线速度 + 角速度 x 半径）低于它才可能睡着。
@export var sleep_surface := 6.0
## 连续安静这么久（秒）才睡着。
@export var sleep_delay := 0.4
#endregion

#region 速度钳制
## 终端速度：**只钳下落方向**（见 PWorld.terminal_speed）。
@export var terminal_speed := 650.0
## 角速度上限（rad/s，0 = 不钳）—— Rapier 只有线速度上限，这条是引擎自己钳的。
@export var max_angular_velocity := 1000.0
## **表面速度**上限（px/s，0 = 关）：角速度上限 = 它 / 包围半径。
## 它比"角速度上限"更接近玩家看到的东西（转得快不快看的是边缘速度）。
@export var max_surface_speed := 0.0
## Rapier 自己的线速度上限（0 = 不钳）。它是数值安全的兜底，不是手感旋钮。
@export var rp_max_linear_velocity := 40000.0
#endregion

#region CCD / 子步
@export var ccd_enabled := true
## Rapier 逐体 CCD 的总闸（0 = 关；>= 1 才开）。
@export var rp_ccd_substeps := 1
## 逐体 CCD 的软预测距离（px，0 = 没有提前量 -> 逐体 CCD 约等于半开）。
@export var rp_soft_ccd_prediction := 0.0
## 每个子步允许的最大位移（世界单位）。
@export var ccd_max_motion := 2.0
## 每个子步允许的最大转角（弧度）。
@export var ccd_max_rotation := 0.25
## 是否把"每子步位移/转角"钳到上面两个值。
@export var ccd_clamp_motion := true
## 子步数上限（0 = 用自适应）。
@export var ccd_max_substeps := 0
## 子步数预算（世界单位）。
@export var ccd_substep_budget := 600
## 子步的**时间预算**（微秒，0 = 不限）。
@export var ccd_substep_cost_budget_us := 0.0
## 抓取时的子步时间预算（微秒）—— 抓着重物时子步会更多。
@export var ccd_grab_substep_cost_budget_us := 6000
## 薄于它的刚体不参与"子步数取全世界最快"的估计（0 = 不豁免）。
@export var ccd_min_driver_thickness := 0.0
## 轻于它的碎片不参与子步估计（0 = 关）—— 一个轻碎片不该拖慢全世界。
@export var ccd_ignore_mass := 0.0
## 关节是否参与 CCD 估计。
@export var ccd_joint_aware := false
## 逐体 CCD（只给快的那几个开）。
@export var ccd_per_body := false
## 逐体 CCD 的"独占"模式：开了就不再叠加全局子步。
@export var ccd_per_body_only := false
## 逐体 CCD 的固定子步数。
@export var ccd_fixed_substeps := 1
## 是否自动决定逐体 CCD 的子步数。
@export var ccd_auto := true
## 推测接触的额外余量（世界单位）。
@export var max_speculative_margin := 1.5
#endregion

#region Rapier 求解 / 接触参数
@export var rp_prediction_distance := 0.02
@export var rp_max_corrective_velocity := 300.0
@export var rp_allowed_linear_error := 0.5
@export var rp_linear_damping := 0.35
@export var rp_angular_damping := 0.6
## 关节/接触求解迭代次数（0 = 不推，保持 Rapier 默认）。**调它是调全局精度**。
@export var rp_joint_solver_iterations := 0
## warmstart 开关（-1 = 不推；0 = 关；1 = 开）。
@export var rp_warmstart_joints := -1
## warmstart 系数（< 0 = 不推）。
@export var rp_warmstart_coefficient := -1.0
#endregion

#region 碎片 / 碰撞体
## 碎片小于这么多**像素**就丢掉（不生成刚体）。
@export var min_fragment_pixels := 4
## 外接盒短边小于它的碎片降级（0 = 关）。
@export var min_fragment_thickness := 0.0
## 像素数低于它的碎片降级为纯视觉灰尘（0 = 关）。
@export var min_fragment_pixels_downgrade := 0
## 质量 <= 它（且运动 >= debris_min_speed）的刚体直接删（0 = 关）。
@export var debris_max_mass := 0.0
## 灰尘清理的速度门槛（0 = 不限速度）。
@export var debris_min_speed := 0.0
## 每个形状的矩形上限（0 = 不限；超了只报 budget_exceeded，不改变几何）。
@export var max_rects_per_shape := 0
## 碰撞体是否走**凸多边形**拟合（Noita 式；关掉就退回逐矩形 cuboid）。
@export var poly_colliders := true
## 走多边形拟合的矩形数上限（超了退回矩形那条路）。
@export var poly_max_rects := 256
## 多边形拟合的偏离容差（像素）。
@export var poly_dev_tol := 1.0
#endregion

#region 材质
## 摩擦系数的**合成规则**（Rapier CoefficientCombineRule 判别值）。
## 见 PWorld.COMBINE_* 与 PixelMaterial.friction。
@export var friction_combine_rule := 5        # COMBINE_GEOMETRIC_MEAN
## 恢复系数的**合成规则**（同上）。
@export var restitution_combine_rule := 3     # COMBINE_MAX
#endregion

#region 诊断
## 收集每步耗时明细（profile）。
@export var profile_enabled := false
## Rapier 侧的调试输出开关。
@export var rp_debug := false
## 宽相/编码走高优先级线程。
@export var parallel_high_priority := false
#endregion


## 本配置的**字段清单**（= PWorld 上同名字段的那批）。
##
## ⚠️ 不手写第二份列表：直接从脚本属性表里取 `@export` 的变量
##    （内置属性如 resource_path / script 没有 SCRIPT_VARIABLE+STORAGE 这两个位）。
## ⚠️ 这份清单是 apply / capture / diff / 闸门的**唯一**依据 ——
##    新增一个旋钮只要在类里加一个 @export 字段，四处同时生效。
func knob_names() -> PackedStringArray:
	var out := PackedStringArray()
	for p in get_property_list():
		var usage: int = p["usage"]
		if (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		if (usage & PROPERTY_USAGE_STORAGE) == 0:
			continue
		out.append(String(p["name"]))
	return out


## 把这份配置**一处下发**到 world（PWorld 或任何有同名字段的对象）。
##
## ⚠️ 名字对不上的字段**吵闹地报**：`Object.set()` 对不存在的属性是**静默失败**，
##    而"旋钮静默失效"正是这个类要消灭的东西（甲方踩过：改了 @export，world 那边还是 0）。
## 返回没找到的字段名（空数组 = 全部下发成功）。
func apply(world: Object) -> PackedStringArray:
	var missing := PackedStringArray()
	if world == null:
		push_error("PhysicsConfig.apply: world 为空 —— 一个旋钮都没下发")
		return knob_names()
	for n in knob_names():
		if not (n in world):
			missing.append(n)
			continue
		world.set(n, get(n))
	if not missing.is_empty():
		push_error("PhysicsConfig.apply: world 上找不到这 %d 个字段（旋钮会静默失效）：%s" % [
			missing.size(), ", ".join(missing)])
	return missing


## 与 @apply()@ 对称：把 world 的**现值**读回这份配置（"现值快照"用）。
## 返回没找到的字段名。
func capture(world: Object) -> PackedStringArray:
	var missing := PackedStringArray()
	if world == null:
		push_error("PhysicsConfig.capture: world 为空")
		return knob_names()
	for n in knob_names():
		if not (n in world):
			missing.append(n)
			continue
		set(n, world.get(n))
	if not missing.is_empty():
		push_error("PhysicsConfig.capture: world 上找不到这 %d 个字段：%s" % [
			missing.size(), ", ".join(missing)])
	return missing


## 逐字段对照 world，返回**不一致**的项（探针/闸门用：`"字段: world=1 配置=2"`）。
## ⚠️ 比较是**逐位**的（浮点不做近似）—— 它要抓的正是"值搬错了"，不是"看起来差不多"。
func diff(world: Object) -> PackedStringArray:
	var out := PackedStringArray()
	if world == null:
		return out
	for n in knob_names():
		if not (n in world):
			out.append("%s: world 上没有这个字段" % n)
			continue
		var a: Variant = world.get(n)
		var b: Variant = get(n)
		if typeof(a) != typeof(b) or a != b:
			out.append("%s: world=%s 配置=%s" % [n, str(a), str(b)])
	return out
