#region 依赖与规则
extends Node
## 世界级碰撞结算。每个固定步先算双方，再统一删像素、分片和重建。
## 不保存像素余量；碎片只需 PBody，不需要额外挂载脚本。

const PBody = preload("res://addons/pixel_destruction/physics/pbody.gd")
const DebrisDust = preload("res://map/src/debris_dust.gd")
## ⚠️ 钉子的材质 id 上游已改成走 InkPalette（单一真源），本地那份
##    NAIL_MATERIAL_ID := 4 已随之删除 —— 合并时不要把它带回来。
const InkPalette := preload("res://Ink/src/ink_palette.gd")
const ANCHOR_TAG := "static_anchor_points"

## 以抓住 32×32 物块抬起再下砸校准：普通落下不删像素，完整下砸约一层。
## 碰撞冲量转为破坏预算的倍率；越大越容易删像素。
@export var damage_scale: float = 0.012
## 触发损坏的最小接近速度，单位 px/s；低于该值不结算，避免静态压力损坏。
@export var min_approach: float = 300.0
## 厚度支撑累加上限，以表面材料强度归一化；超过后不再增加减伤。
@export var support_max: float = 64.0
## 厚度对数减伤系数；越大，同样厚度下的损坏越小。
@export var thickness_scale: float = 0.5
## 厚度修正的最低倍率；即使支撑很厚也保留该比例的破坏预算。
@export_range(0.0, 1.0, 0.01) var min_thickness_factor: float = 0.2
## 强度 0 表示不删像素；作为攻击方及玩家伤害的参考抗性仍需有限值。
@export var reference_strength: float = 100.0
## 单次撞击最多生成的主裂纹数；实际数量仍由可破坏像素预算决定。
@export_range(1, 4, 1) var crack_max_count: int = 4
## 每增加一条主裂纹需要的等效可破坏像素数；越大越难出现多条裂纹。
@export_range(1.0, 32.0, 0.5) var crack_pixels_per_branch: float = 6.0
## 主裂纹围绕受力进入方向的最大展开角；实际角度带确定性扰动，不形成整齐扇形。
@export_range(0.0, 80.0, 1.0) var crack_spread_degrees: float = 35.0
## 每段裂纹的最大随机转角；越大越接近闪电或树根，越小越接近玻璃直裂纹。
@export_range(0.0, 30.0, 1.0) var crack_turn_degrees: float = 10.0
## 裂纹前进多少像素后重新取一次转角；越小折线越密。
@export_range(1, 16, 1) var crack_turn_pixels: int = 4
var _elapsed: float = 0.0
var _main = null
var _player = null
var _protected: Array = []
@onready var _feet = $"../Player/PlayerInput"
@onready var _forces = get_node_or_null("../debugHUD/ForceDebug")
@onready var _camera: Camera2D = $"../Camera2D"
## 活动范围相对当前可见画面的宽高倍率；4 表示宽高各四倍，完全在外的刚体冻结。
@export_range(1.0, 32.0, 0.5) var freeze_view_scale: float = 4.0

## ---- CCD 代价闸门（游戏侧）----
## 每个固定步允许花在**子步循环**上的时间预算（微秒）。0 = 关（引擎原行为）。
##
## ⚠️⚠️ 为什么需要：子步是**全局**的 —— 每个子步都要把整个世界步进一遍，所以
##    帧时间 = 子步数 x 全世界矩形数。而**子步数只由全世界最快的那个刚体决定**
##    （pworld.gd:_fastest_motion_plain 取的是 max，不是各自算各自的）。
##    实测（test/tools/bench_small_fragment_ccd.gd，876 矩形 = 真实地图规模）：
##      一个 2x2 的碎片以 20000 px/s 飞过 -> 167 子步 -> **307 ms/固定步**
##      以 40000 px/s                    -> 334 子步 -> **593 ms/固定步**
##    配合 max_substeps = 4 的追帧，一帧能叠到几秒 —— 这就是「卡死」。
##
## ⚠️ 引擎自带的 grab_substep_cap 是同一个公式，但**只在抓取时**生效
##    （pworld.gd:_compute_substeps 里那个 `if not grabs.is_empty()`）。
##    这里是「任何时候都生效」的那一道。公式与标定同源，见 pworld.gd:CCD_RECT_COST_US。
## ⚠️ 代价：重场景里子步变少 -> 每子步位移变大 -> 超高速物体**穿模**。
##    而「穿模」正是 CCD 现在被关掉时的口径（见 _start() 里那 3 行），所以不新增损失。
@export var ccd_substep_budget_us: float = 6000.0

## 刚体的**表面速度**上限（px/s）：线速度与 |w| x 外接半径 都按它收口。0 = 关。
##
## ⚠️⚠️ 为什么角速度要按**表面速度**收：引擎的 max_angular_velocity 是**绝对 rad/s**
##    （pworld.gd:52），而子步估的是 |w| x 外接半径（表面速度，pworld.gd:_motion_of）。
##    同一个物理量，两把尺子：
##      · 线速度上限 1000 px/s 只值 ceil(1000/120) = **9 子步**；
##      · 60 rad/s x 300 px 外接半径 = 17860 px/s -> **151 子步**（实测 876 矩形下 230 ms）。
##    引擎对**睡眠**用的就是表面速度（pworld.gd:sleep_surface，「绝对角速度阈值会把小碎块
##    永久钉在醒着」），对 CCD 却用了裸 rad/s。这里只是把 CCD 这一侧对齐。
##
## ⚠️ 它在 _compute_substeps **之前**跑：引擎的钳制发生在 Rapier 步进**之中**
##    （rp_max_linear_velocity 在 Rapier 内部）与**读回之后**（max_angular_velocity，
##    pworld.gd:1200），而子步估计读的是 GDScript 侧镜像 —— 读在钳制之前。
##    于是「这一帧」用的是未钳制的值。实测：一根 300x40 的板以 w=60 自转被切开，
##    碎片继承 9168 px/s -> 77 子步，而母体已经不存在了（pworld.gd:3192 的速度场继承）。
## ⚠️ 代价：大刚体转不快了（r=300 时上限 3.3 rad/s）。觉得手感被削就调大本值 ——
##    那是「用穿模风险换转速」的旋钮。
@export var max_surface_speed: float = 1000.0

## 逐体 CCD 的**软预测距离**（px，0 = 关）。它就是让 Rapier 的逐体 CCD 真正生效的那个旋钮。
##
## ⚠️⚠️ Rapier 的默认值是 **0.0 —— 等于半关**：快物体没有任何提前量，逐体扫掠只能
##    「正好撞上」才发现。实测 20000 px/s 撞 4 像素薄墙：软预测 0.0 时要靠 167 个
##    全局子步才挡住（停在 x=188.1），1.5 时逐体 CCD 用 **1** 个子步就挡住（x=188.0）。
## ⚠️ 引擎里 `max_speculative_margin = 1.5` 是同一个概念的 GDScript 侧版本，
##    两者都吃这个提前量；这里取同一个数量级。
@export var ccd_soft_prediction: float = 0.5

## ---- 灰尘策略（档 C）----
## 碎片的**外接盒短边**低于它就算**灰尘**：不进物理，降级成短命灰尘（0 = 关）。
##
## ⚠️ 与场景已有的 min_fragment_pixels 是**两个轴**：那个数**像素个数**
##    （1x20 的细条有 20 像素，照样过），这个数**看得见的尺寸**（同一条细条是 1，被挡住）。
## ⚠️⚠️ 用的是**外接盒短边**，不是 thinnest_extent()（最薄矩形）。
##    后者会被斜边切出的 1 像素矩形骗到：一块 29x29、435 像素的**斜切大块**
##    thinnest=1 -> 整块被当成灰尘 -> 玩家看到「碎片直接消失」。
##    而斜切恰恰是真实破坏里最常见的形状（爆炸 / 擦除 / 裂纹都出斜边）。
## ⚠️ 为什么值得做：PBody.needs_ccd 的判据对小碎片是**反向**的（越小越容易满足），
##    所以「每个碎片都值得 CCD」是陷阱 —— PhysX 官方把它写成失败模式警告
##    （paper-thin rigid body -> always above its CCD velocity threshold）。
##    业界做法是**根本不给它们刚体**：Teardown 有最小碎片尺寸、Noita 从不把散像素
##    升格成刚体、roxlap 让碎片落地即碎成纯表现粒子。
## ⚠️ 命中的碎片**不会消失**：它们进 debris_dust.gd，还看得见，只是不再参与物理。
@export var debris_max_thickness: float = 4.0
## 外接盒短边比它还小的碎片**只跟静态世界碰**（碎片之间不碰；0 = 关）。
##
## ⚠️ 为什么：碎片-碎片对是**配对爆炸**的主要来源（Rapier 自己的 CCD 文档点名
##    high-speed objects in close proximity），而两粒灰互不互撞没人看得出来。
## ⚠️ 阈值必须**明显大于** debris_max_thickness，否则它几乎是空操作 ——
##    能活过判废的碎片本来就已经比 debris_max_thickness 厚了。
## ⚠️ 只对**够薄的**碎片生效：大块照旧互相碰。否则「大块落在碎块堆上」会直接穿过去，
##    那是看得见的。
@export var debris_isolate_thickness: float = 10.0
## 碎片**像素数**低于它也算灰尘（0 = 关）。
##
## ⚠️⚠️ 与 debris_max_thickness 是**两个触发器、取并集**，缺一个就会反直觉：
##   · 只按厚薄：3x200 的细长条（600 像素，看着不小）会成灰尘，
##     而 5x5 的方块（25 像素，看着很小）会留下来 —— 正是「大的成灰尘、小的没成」。
##   · 只按像素数：1x20 和 4x5 都是 20 像素，但前者会穿墙。
##   **厚薄决定能不能钻过去，大小决定值不值得存在。**
## ⚠️ 它和场景的 min_fragment_pixels(5) 不是一回事：那个是**直接删掉**（更小的一撮，
##    连画都不画），这个是**降级**（还看得见，只是不进物理）。
@export var debris_max_pixels: int = 40

## 灰尘层用的碰撞层位。语义（引擎 collision_layer/mask）：两个刚体要碰必须**双方都同意** ——
##   (A.layer & B.mask) != 0  且  (B.layer & A.mask) != 0
##
## ⚠️⚠️ **引擎的节点默认是 layer=1 / mask=全开**（pixel_body_2d.gd:332）——
##    也就是说**地形、道具、玩家全都在第 1 层**。所以「只跟第 1 层碰」不等于
##    「只跟静态世界碰」：玩家也在第 1 层，灰尘照样撞他。
##    我第一版就是栽在这里，而且注释里写着「世界与玩家都在 WORLD_LAYER」——
##    和上面那句「只跟静态世界碰」**自相矛盾**，等于把这个事实写在脸上却当没看见。
##    修法：把**玩家**挪到 PLAYER_LAYER（见 _start 里那两行），
##    于是 (玩家.layer & 灰尘.mask) == 0 -> 灰尘穿过玩家。
##
## 三层的分工：
##   DEFAULT_LAYER(1)：地形、道具、所有没显式设过的刚体 —— 灰尘跟**这些**碰
##   DEBRIS_LAYER(2) ：灰尘自己 —— 灰尘 vs 灰尘 (2 & 1) == 0 -> 不碰
##   PLAYER_LAYER(4) ：玩家（+ 手臂/手）—— 灰尘的 mask 里没有它 -> 不碰
const DEBRIS_LAYER := 2
const WORLD_LAYER := 1
const PLAYER_LAYER := 4
## 引擎给的**默认**过滤器（pixel_body_2d.gd:332 / pbody.gd）。
## ⚠️ 隔离策略**只动还留在默认值上的碎片** —— 调用方显式设过的过滤器是它的配置，
##    不是我们能替他决定的。见 _isolate_debris 里的守卫。
const DEFAULT_LAYER := 1
const DEFAULT_MASK := 0xFFFFFFFF

var _dust = null
## 上一次固定步被 _clamp_speeds 收口的次数（诊断用）。
var last_speed_clamped: int = 0
## 上一次固定步被 _apply_substep_budget 压掉的子步数（诊断用，0 = 没压）。
var last_substeps_capped: int = 0
var profile_enabled: bool = false
var _profile: Dictionary = {}
#endregion


#region 世界步进
func _ready() -> void:
	# 等父世界及 Player 完成初始化，再接管步进，避免同一帧推进两次。
	call_deferred("_start")


## 停止场景时解除形状与刚体的引用环，避免每次编辑器运行都残留物理资源。
func _exit_tree() -> void:
	if _main == null or _main.world == null:
		return
	for body in _main.world.bodies.duplicate():
		for shape in body.shapes:
			shape.owner_body = null
		_main.world.remove_body(body)
		body.shapes.clear()
	_main.world._rp = null


func _start() -> void:
	_main = get_parent()
	_player = _main.get_node("Player")
	_protected = [_player.get_node("Arm").body, _player.get_node("Arm/Hand").body]
	_main.set_physics_process(false)
	_main.world.contact_events_enabled = false
	# ---- CCD：**恢复开着**，但把「代价的闸门」全部装上 ----
	#
	# ⚠️⚠️ 这里曾经有 3 行「临时关闭 CCD」（ccd_enabled = false + rp_ccd_substeps = 0），
	#    拿穿模换帧时间。现在恢复，因为根因被掐掉了：子步数只由**一个**最快的刚体决定，
	#    而子步是**全局**的（每个子步都要把整个世界重跑一遍），所以实测（876 矩形）
	#    一个 2x2 的碎片以 40000 px/s 飞过 = 334 子步 = **593 ms/固定步**。
	#    四道闸门各管一段，谁都不是「再关一次 CCD」：
	#      · 游戏侧 _clamp_speeds + 引擎 max_surface_speed：把**输入**收口 —— 角速度按
	#        表面速度，不是裸 rad/s（引擎的 max_angular_velocity 是绝对 rad/s，两把尺子）；
	#      · 游戏侧 _apply_substep_budget + 引擎 ccd_substep_cost_budget_us：按**世界大小**
	#        给子步循环一个时间预算；
	#      · 引擎 ccd_max_substeps：硬上限；
	#      · 引擎 ccd_min_driver_thickness：**尺寸**豁免（薄灰尘不驱动子步）。
	#
	# ⚠️ 要再关必须**两层一起关**（ccd_enabled + rp_ccd_substeps）才有穿模效果：
	#    只关一层时另一层还挡着（pworld.gd 里 ccd_ignore_mass 的墓碑记过 ——
	#    薄墙 + 子步 1 仍然挡住，只有把 rp_ccd_substeps 也设成 0 才真的穿过去）。
	var world = _main.world
	# ① 逐体 CCD 的**总闸**。这两行 + 下面那行软预测，才是「CCD 真的在工作」。
	world.ccd_enabled = true
	world.rp_ccd_substeps = 1
	# ⚠️⚠️ **这一行是关键，而且以前从来没设过。**
	#    Rapier 的软 CCD 预测距离默认 **0.0 —— 等于逐体 CCD 半关**：快物体没有任何
	#    提前量，只能「正好撞上」才发现，对一步跨几百像素的物体等于不起作用。
	#    引擎里有一个同义的旋钮 max_speculative_margin = 1.5（推测接触边际），
	#    这里是它在 Rapier 那一侧的对应物。
	#    实测（4 像素薄墙 + 12x12 块，20000 px/s）：
	#      软预测 0.0 -> 只能靠全局子步：峰值 167 子步，停在 x=188.1
	#      软预测 1.5 -> **逐体 CCD 单独搞定**：峰值 1 子步，停在 x=188.0
	world.rp_soft_ccd_prediction = ccd_soft_prediction
	# ② **不做全局子步**：防穿是**逐体**的事，而子步是**全局**的
	#    （每个子步都要把整个世界重跑一遍）。拿全局子步防穿 = 让一个最快的小碎片
	#    决定全世界的帧时间。上面那两行实测就是这条的注脚：167 子步 vs 1 子步，
	#    而且 1 子步的结果**更好**。
	_push_knob(world, "ccd_per_body_only", true)
	# ⚠️ 逐体模式**不等于**子步=1：子步同时是求解器的收敛手段（TGS「Soft Step」）。
	#    实测把它塌到 1，test_hand_physics 的「grounded/held object lifted」当场变红
	#    （抬升 46.25 -> 39.88）—— 抓取变软。3 是量出来的：它既拿掉了「按最快刚体
	#    自适应」，又保住了手感和求解精度。
	_push_knob(world, "ccd_fixed_substeps", 3)
	# ③ 逐体 bullet 旗：只有「按自身尺寸真的需要」的刚体才被推成 Rapier 的 bullet。
	# ⚠️ 老行为是**全世界每个刚体**都推成 bullet，而 bullet 会连动态/运动学目标一起扫
	#    （Rapier 文档：more expensive, disabled by default）—— 碎片堆里动态体最多。
	# ⚠️ 注意它**不是**防穿主力：对静态世界的那一层（自动扫掠）不看这个旗子，
	#    只要 rp_ccd_substeps >= 1 就在跑。旗子只管「动态-动态」。
	_push_knob(world, "ccd_per_body", true)
	_push_knob(world, "ccd_auto", true)
	# ④ 下面三行在逐体模式下**不参与**（子步恒为 1），但照样设上 ——
	#    它们是**回退路径**：把 ccd_per_body_only 关掉就立刻回到「全局子步 + 四道闸门」。
	#    留着是因为逐体 CCD 对「动态-动态高速相撞」无解（Rapier 官方承认），
	#    哪天要为那种场景兜底，把开关一关就能回到老机制。
	_push_knob(world, "ccd_max_substeps", 4)
	_push_knob(world, "ccd_min_driver_thickness", 3.0)
	_push_knob(world, "max_surface_speed", max_surface_speed)
	# ⑤ 玩家挪到**独立碰撞层** —— 否则「灰尘只跟静态世界碰」是假的：
	#    (玩家.layer=1 & 灰尘.mask=1) != 0 -> 两边都同意 -> 灰尘照样撞玩家。
	#    ⚠️ 注意 mask **不能**留空：玩家仍然要跟地形（layer 1）和道具碰，
	#    所以只改 layer、mask 保持全开 —— 这样「玩家 vs 世界」两边都同意，
	#    而「灰尘 vs 玩家」只有一边同意（灰尘的 mask 里没有 PLAYER_LAYER）。
	if _player != null and _player.body != null:
		_player.body.collision_layer = PLAYER_LAYER
	for pb in _protected:
		# 手臂/手（如果它们本来就是 layer 0 = 谁也不碰，就别动它）
		if pb != null and pb.collision_layer != 0:
			pb.collision_layer = PLAYER_LAYER
	# 档 C：太薄的碎片**不进物理**（引擎在 fracture_pixels 里就把它们挑出来，
	# 随 result.downgraded 交回来，见下面 commit()）。
	_push_knob(world, "min_fragment_thickness", debris_max_thickness)
	_push_knob(world, "min_fragment_pixels_downgrade", debris_max_pixels)
	# 灰尘层：renderer 是**延迟**加进树的，所以这里只是先把节点挂上，
	# 拿不到渲染器时 debris_dust 会每帧重试（不能静默什么都不画）。
	_dust = DebrisDust.new()
	_dust.name = "DebrisDust"
	add_child(_dust)
	# ⚠️ 传的是**世界节点**而不是 renderer：renderer 是 add_child.call_deferred 加进树的，
	#    这里很可能还是 null。灰尘层自己按帧去解析（见 debris_dust.gd 的墓碑）。
	_dust.setup(_main)
	process_physics_priority = _main.process_physics_priority + 1


## 把旋钮推给世界；引擎版本里没有这个旋钮就**吵一声**（静默失效是最坏的失败方式）。
## 这几个旋钮是本仓库引擎快照新增的 —— 用 `in` 探测存在性，缺了也不崩，但一定留痕。
func _push_knob(world, name: String, value) -> bool:
	if not (name in world):
		push_warning("[CCD] 引擎没有 %s —— 这一道闸门失效（需要本仓库的引擎快照）" % name)
		return false
	world.set(name, value)
	return true


func _physics_process(delta: float) -> void:
	if _main == null or not _main.auto_step:
		return
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	_elapsed += delta
	var steps: int = 0
	while _elapsed >= _main.fixed_dt and steps < _main.max_substeps:
		var result: Dictionary = _step(_main.fixed_dt)
		_player.apply_collision_damage(result.player_damage)
		if not result.removals.is_empty():
			var nodes: Array = _main._body_nodes.duplicate()
			commit(_main.world, result.removals)
			var sync_start: int = Time.get_ticks_usec() if profile_enabled else 0
			_main.sync_world_bodies()
			if profile_enabled:
				_profile.sync_us = _profile.get("sync_us", 0) + Time.get_ticks_usec() - sync_start
			var live: Dictionary = {}
			for body in _main.world.bodies:
				live[body] = true
			for node in nodes:
				if is_instance_valid(node) and not live.has(node.body):
					node.queue_free()
		_elapsed -= _main.fixed_dt
		steps += 1
	if _elapsed > _main.fixed_dt * _main.max_substeps:
		_elapsed = 0.0
	if is_instance_valid(_forces):
		_forces.finish(delta)
	if _main.auto_render and _main.renderer != null:
		var render_start: int = Time.get_ticks_usec() if profile_enabled else 0
		# 归属判据只有引擎那一个 uses_internal_render（rebuild/bake_node/sync_world_bodies 同源）；
		# 不归内部渲染器画的刚体必须 forget 掉旧贴图，否则它会停在旧位置变成鬼影。
		_main.renderer.prune(_main._live_ids())
		# ⚠️ 按下标取节点前先保证 _body_nodes 与 world.bodies 一一对应：绕过节点层的增删
		#    （直接调 fracture_pixels、门面 spawn_*、调试脚本 add_body；灰尘剔除那条已由
		#    _drop_culled_nodes() 覆盖）会让数组变短 -> 越界 -> 整个同步循环中断 ->
		#    之后的碎片贴图停在旧位姿。按版本号对齐：平时一次整数比较。
		# ⚠️ 每次同步前对齐一次：只补位/对齐、不删项，O(n) 很小（引擎 realign_body_nodes 的注释
		#    写明这条不变量与静默错配的后果）。写成无条件是为了**不依赖引擎版本** ——
		#    仓库里内置的 addon 快照还没有 world.bodies_rev（v0.3.11 才有），无条件对齐对两版都成立。
		_main.realign_body_nodes()
		for i in _main.world.bodies.size():
			var body = _main.world.bodies[i]
			var node = _main._body_nodes[i] if i < _main._body_nodes.size() else null
			if not _main.uses_internal_render(node):
				_main.renderer.forget(body.id)
				continue
			if body.is_static or body.frozen:
				continue
			_main.renderer.sync(body)
		if profile_enabled:
			_profile.render_sync_us = _profile.get("render_sync_us", 0) + Time.get_ticks_usec() - render_start
	if profile_enabled:
		_profile.physics_us = _profile.get("physics_us", 0) + Time.get_ticks_usec() - profile_start
		_profile.physics_calls = _profile.get("physics_calls", 0) + 1


func set_profile_enabled(enabled: bool) -> void:
	profile_enabled = enabled
	_profile.clear()


func take_profile() -> Dictionary:
	var result: Dictionary = _profile.duplicate()
	_profile.clear()
	return result


## 接触点必须匹配该子步的位姿；删除并集留到固定步末，避免重复重建。
func _step(delta: float) -> Dictionary:
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var physics = _main.world
	# 用当前可见画面扩大范围，整组关节冻结；玩家连接的物体持续受力。
	var size: Vector2 = _camera.get_viewport_rect().size / _camera.zoom * freeze_view_scale
	physics.cull_freeze(Rect2(_camera.get_screen_center_position() - size * 0.5, size), [_player.body])
	for body in physics.bodies:
		body.refresh_com()
	# 灰尘闸门：引擎的 PWorld.step() 在算子步之前先清掉又轻又快的灰尘（pworld.gd:1678）。
	# 本节点接手步进后必须补上这一句，否则 debris_max_mass / debris_min_speed 在游戏里是死旋钮，
	# 而子步数取的是全世界最快的那个刚体 —— 一个灰尘就能把全世界的子步顶满。
	var culled: int = physics.cull_fast_debris()
	physics.last_debris_removed = culled
	if culled > 0:
		_drop_culled_nodes()
	# 速度收口：**必须**在 _compute_substeps 之前（理由见 max_surface_speed 的说明）。
	# 放在灰尘清理之后：清理的判据是「又轻又快」，用的是**原始**运动 —— 先钳就清不掉了。
	last_speed_clamped = _clamp_speeds(physics)
	var count: int = physics._compute_substeps(delta)
	var capped: int = _apply_substep_budget(physics, count)
	last_substeps_capped = count - capped
	count = capped
	physics.last_substeps = count
	if profile_enabled:
		_profile.fixed_steps = _profile.get("fixed_steps", 0) + 1
		_profile.substeps = _profile.get("substeps", 0) + count
	var result: Dictionary = {"removals": {}, "player_damage": 0.0}
	for i in count:
		physics.contacts.clear()
		var native_start: int = Time.get_ticks_usec() if profile_enabled else 0
		physics._substep_rapier(delta / count)
		if profile_enabled:
			_profile.native_us = _profile.get("native_us", 0) + Time.get_ticks_usec() - native_start
		var impact: Dictionary = calculate(physics, _player.body, _protected)
		result.player_damage += impact.player_damage
		for body in impact.removals:
			if not result.removals.has(body):
				result.removals[body] = impact.removals[body]
				continue
			for shape in impact.removals[body]:
				if not result.removals[body].has(shape):
					result.removals[body][shape] = impact.removals[body][shape]
				else:
					result.removals[body][shape].merge(impact.removals[body][shape], true)
	if profile_enabled:
		_profile.step_us = _profile.get("step_us", 0) + Time.get_ticks_usec() - profile_start
	return result


## cull_fast_debris() 绕过节点层删刚体，而 _body_nodes 与 world.bodies 是按下标一一对应的
## （引擎在 pixel_world.gd:717 realign_body_nodes() 的注释里写明这条不变量与静默错配的后果）。
## 所以删完必须重新对齐，并把已经不在世界里的刚体节点回收掉。
## 被清的灰尘一定不带关节：cull_fast_debris 用 _interactive_bodies() 放过了抓着的和挂关节的
## （pworld.gd:2831），所以这里不用碰关节表。
## 渲染不在这里全量同步 —— _physics_process 末尾已经 prune 过一次。
func _drop_culled_nodes() -> void:
	var live: Dictionary = {}
	for body in _main.world.bodies:
		live[body] = true
	var nodes: Array = _main._body_nodes.duplicate()
	_main.realign_body_nodes()
	for node in nodes:
		if not is_instance_valid(node):
			continue
		var body = node.get("body")
		if body != null and not live.has(body):
			node.queue_free()


## 按**表面速度**收口所有动态刚体的速度（线速度 + |w| x 外接半径）。返回被钳的次数。
##
## ⚠️ 这是「把子步估计读到的值先钳一遍」，不是替代引擎的钳制 —— 引擎那两道
##    （Rapier 内部的 rp_max_linear_velocity、读回时的 max_angular_velocity）都发生在
##    子步估计**之后**，所以挡不住「fracture 的速度场继承 + 本帧立刻算子步」这条路。
## ⚠️ 冻结体也钳：它们不参与子步估计，但**解冻那一帧会**（速度是留着解冻用的，
##    实测有 frozen 的碎片带着 24964 px/s 停在相机外）。钳它不影响「解冻后接着跑」。
func _clamp_speeds(physics) -> int:
	if max_surface_speed <= 0.0:
		return 0
	var vmax: float = max_surface_speed
	var clamped: int = 0
	for body in physics.bodies:
		if body.is_static:
			continue
		var v: Vector2 = body.linear_velocity
		if v.length_squared() > vmax * vmax:
			body.linear_velocity = v.normalized() * vmax
			clamped += 1
		var r: float = body.bounding_radius()
		if r > 1e-6:
			var wmax: float = vmax / r
			if absf(body.angular_velocity) > wmax:
				body.angular_velocity = clampf(body.angular_velocity, -wmax, wmax)
				clamped += 1
	return clamped


## 子步数的**时间预算**闸门：按世界大小把子步数压到「这一步最多花 ccd_substep_budget_us」。
##
## 公式与引擎的 grab_substep_cap 同源（pworld.gd:1490）：
##     子步上限 = 预算 / (总矩形数 x CCD_RECT_COST_US)
## 区别只有一个 —— 那个只在抓取时生效，这个任何时候都生效。
## ⚠️ 常数直接读引擎的 const，避免两边标定漂移（引擎注释里记过「测试自己抄了一遍
##    公式，引擎改了标定而测试没改，闸门静默失效」这个坑）。
func _apply_substep_budget(physics, count: int) -> int:
	if ccd_substep_budget_us <= 0.0:
		return count
	var total_rects: int = 0
	for body in physics.bodies:
		total_rects += body.rects.size()
	if total_rects <= 0:
		return count
	var cap: int = maxi(1, int(ccd_substep_budget_us / (float(total_rects) * physics.CCD_RECT_COST_US)))
	return mini(count, cap)


#endregion


#region 碰撞结算
## 返回 {removals: {PBody: {PixelShape: {Vector2i: true}}}, player_damage: float}。
## 重叠删除取并集；每条 lane 独立消费预算，未满一个像素的余量舍弃。
func calculate(world, player_body: PBody = null, protected_bodies: Array = []) -> Dictionary:
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var result: Dictionary = {"removals": {}, "player_damage": 0.0}
	var contacts_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var contacts: Array = _contacts(world)
	if profile_enabled:
		_profile.contacts_us = _profile.get("contacts_us", 0) + Time.get_ticks_usec() - contacts_start
		_profile.contact_pairs = _profile.get("contact_pairs", 0) + contacts.size()
	if is_instance_valid(_forces):
		_forces.sample_contacts(contacts, _main.fixed_dt / world.last_substeps)
	if is_instance_valid(_feet):
		_feet.update_support(contacts)
	# 轻碎片豁免：一个子步只建一次集合，别在每对接触上重建（见 _dust_bodies）。
	var dust: Dictionary = _dust_bodies(world, player_body, protected_bodies)
	for contact in contacts:
		if contact.approach <= min_approach:
			continue
		# 两头都是灰尘：两侧都被豁免，连冲量合成都不必算。
		if dust.has(contact.a) and dust.has(contact.b):
			continue
		var impact: Dictionary = _impact(contact.points)
		if impact.is_empty():
			continue
		var point: Vector2 = impact.position
		var normal: Vector2 = impact.normal
		var a_origin: Vector2 = point - normal * 0.001
		var b_origin: Vector2 = point + normal * (maxf(impact.dist, 0.0) + 0.001)
		var a_material: int = _material_at(contact.a, a_origin)
		var b_material: int = _material_at(contact.b, b_origin)
		if a_material == 0 or b_material == 0:
			continue
		for side in [[contact.a, a_origin, -normal, a_material, b_material, -1.0],
				[contact.b, b_origin, normal, b_material, a_material, 1.0]]:
			var body: PBody = side[0]
			if protected_bodies.has(body) or dust.has(body):
				continue
			var strength: float = world.material_strength(side[3]).x
			if strength <= 0.0 and body != player_body:
				continue
			strength = strength if strength > 0.0 else reference_strength
			var attacker: float = world.material_strength(side[4]).x
			attacker = attacker if attacker > 0.0 else reference_strength
			var budget: float = damage_scale * impact.impulse * attacker / strength
			if body != player_body and budget < strength:
				continue  # 连第一层都删不掉，不必扫描厚度。
			var path: Array = _trace(body, side[1], side[2], world, 0.0 if body == player_body else budget, body == player_body)
			var seed: int = hash(Vector3i(roundi(point.x * 16.0), roundi(point.y * 16.0), roundi(impact.impulse)))
			_damage_side(world, body, path, side[4], impact.impulse, player_body,
				protected_bodies, result, side[1], side[2], seed, side[5])
	if profile_enabled:
		_profile.damage_us = _profile.get("damage_us", 0) + Time.get_ticks_usec() - profile_start
	return result


## 轻碎片豁免：阈值直接用世界的 ccd_ignore_mass（0 = 关，引擎默认），与引擎
## _exempt_bodies()（pworld.gd:1488）是同一个「灰尘」定义 —— 引擎既然不为「质量 <= 它」
## 的刚体做防穿（一个 2x2 碎片就能逼全世界跑 334 子步，pworld.gd:93-103），也就不必为
## 它们跑 _trace()/_damage_side() 那趟逐层厚度扫描；calculate() 是每个子步跑一次的
## （_step 的子步循环里），碎块一多这趟扫描就是纯开销。
## 豁免只针对「被撞的一方」；玩家、手臂/手、抓着的、挂关节的一律不在集合里
## （与引擎 _exempt_bodies() 末尾 erase(_interactive_bodies()) 同义）。
func _dust_bodies(world, player_body: PBody, protected_bodies: Array) -> Dictionary:
	var out: Dictionary = {}
	var limit: float = world.ccd_ignore_mass
	if limit <= 0.0:
		return out
	var interactive: Dictionary = world._interactive_bodies()
	for body: PBody in world.bodies:
		if body == player_body or protected_bodies.has(body):
			continue
		if body.is_static or body.frozen:
			continue
		if body.mass <= limit and not interactive.has(body):
			out[body] = true
	return out


func _damage_side(world, body: PBody, path: Array, attacker_material: int,
		impulse: float, player_body: PBody, protected_bodies: Array, result: Dictionary,
		origin: Vector2 = Vector2.INF, direction: Vector2 = Vector2.ZERO, seed: int = 0,
		mirror: float = 1.0) -> void:
	if protected_bodies.has(body) or path.is_empty():
		return
	var surface_strength: float = world.material_strength(path[0].material).x
	if surface_strength <= 0.0:
		if body != player_body:
			return
		surface_strength = reference_strength
	var attacker_strength: float = world.material_strength(attacker_material).x
	if attacker_strength <= 0.0:
		attacker_strength = reference_strength
	var support: float = 0.0
	for pixel in path:
		var strength: float = world.material_strength(pixel.material).x
		if body == player_body and strength <= 0.0:
			strength = reference_strength
		# 不可破坏的内层提供最大支撑，且逐层消耗时会阻挡贯穿。
		support = minf(support_max, support + (strength / surface_strength if strength > 0.0 else support_max))
		if support >= support_max:
			break
	var factor: float = min_thickness_factor + (1.0 - min_thickness_factor) / (1.0 + thickness_scale * log(1.0 + support))
	var budget: float = damage_scale * impulse * attacker_strength / surface_strength * factor
	if body == player_body:
		result.player_damage += budget
		return
	if not origin.is_finite() or direction.is_zero_approx():
		_consume_path(world, body, path, budget, result)
		return
	var count: int = _crack_count(budget / surface_strength)
	var branch_budget: float = budget / float(count)
	for i in count:
		var spread: float = 0.0 if count == 1 else remap(float(i), 0.0, float(count - 1), -1.0, 1.0)
		var jitter: float = (_noise(seed, i) * 2.0 - 1.0) * crack_turn_degrees
		var angle: float = deg_to_rad((spread * crack_spread_degrees + jitter) * mirror)
		var crack: Array = _crack_path(body, origin, direction.rotated(angle), world,
			branch_budget, seed + i * 97, mirror)
		_consume_path(world, body, crack, branch_budget, result)


func _crack_count(pixel_budget: float) -> int:
	return clampi(1 + floori(maxf(0.0, pixel_budget - 1.0) / crack_pixels_per_branch), 1, crack_max_count)


func _consume_path(world, body: PBody, path: Array, budget: float, result: Dictionary) -> void:
	for pixel in path:
		var cost: float = world.material_strength(pixel.material).x
		if cost <= 0.0 or budget < cost:
			break
		budget -= cost
		if not result.removals.has(body):
			result.removals[body] = {}
		if not result.removals[body].has(pixel.shape):
			result.removals[body][pixel.shape] = {}
		result.removals[body][pixel.shape][pixel.position] = true
#endregion


#region 接触面
## 只查询冲量，避免接触事件逐像素计算宽度与应力。
func _contacts(world) -> Array:
	if not world.contacts.is_empty():
		return world.contacts
	var bodies: Dictionary = {}
	for body in world.bodies:
		bodies[body.rapier_id] = body
	var contacts: Array = []
	for i in world.contact_pair_count():
		var info: Dictionary = world.contact_info(i)
		var a = bodies.get(info.id_a)
		var b = bodies.get(info.id_b)
		if a == null or b == null or info.points.is_empty():
			continue
		var point: Dictionary = info.points[0]
		var ra: Vector2 = point.position - a.com_world()
		var rb: Vector2 = point.position - b.com_world()
		var va: Vector2 = Vector2(a.pre_vx, a.pre_vy) + Vector2(-ra.y, ra.x) * a.pre_w
		var vb: Vector2 = Vector2(b.pre_vx, b.pre_vy) + Vector2(-rb.y, rb.x) * b.pre_w
		contacts.append({"a": a, "b": b, "points": info.points,
			"approach": -(vb - va).dot(point.normal)})
	return contacts


## 同一碰撞对只形成一次撞击；多接触点按各自冲量合成，避免 N 个点产生 N 份伤害。
func _impact(points: Array) -> Dictionary:
	var total: float = 0.0
	var position: Vector2 = Vector2.ZERO
	var normal: Vector2 = Vector2.ZERO
	var dist: float = 0.0
	for point in points:
		if point.impulse <= 0.0:
			continue
		total += point.impulse
		position += point.position * point.impulse
		normal += point.normal * point.impulse
		dist += point.dist * point.impulse
	if total <= 0.0 or normal.is_zero_approx():
		return {}
	normal = normal.normalized()
	var tangent: Vector2 = Vector2(-normal.y, normal.x)
	var first: float = INF
	var last: float = -INF
	for point in points:
		if point.impulse > 0.0:
			first = minf(first, point.position.dot(tangent))
			last = maxf(last, point.position.dot(tangent))
	var width: int = maxi(1, ceili(last - first))
	return {"position": position / total, "normal": normal, "dist": dist / total,
		"impulse": total / float(width), "total_impulse": total, "width": width}
#endregion


#region 像素路径
func _material_at(body: PBody, point: Vector2) -> int:
	var cell: Vector2i = Vector2i(body.to_local(point).floor())
	for shape in body.shapes:
		var material: int = shape.get_pixel(cell.x, cell.y)
		if material != 0:
			return material
	return 0


## 局部网格 DDA：每个进入的像素只访问一次；第一处空洞停止，跨材料继续。
## 支撑已饱和且累计像素成本覆盖未经减伤的预算时，后续深度不再影响结果。
func _trace(body: PBody, origin: Vector2, direction: Vector2, world = null,
		budget: float = INF, player: bool = false) -> Array:
	var point: Vector2 = body.to_local(origin)
	var ray: Vector2 = direction.rotated(-body.rotation)
	var cell: Vector2i = Vector2i(floori(point.x), floori(point.y))
	var step: Vector2i = Vector2i(int(signf(ray.x)), int(signf(ray.y)))
	var delta: Vector2 = Vector2(INF if ray.x == 0.0 else absf(1.0 / ray.x), INF if ray.y == 0.0 else absf(1.0 / ray.y))
	var edge: Vector2 = Vector2(cell) + Vector2(1.0 if ray.x > 0.0 else 0.0, 1.0 if ray.y > 0.0 else 0.0)
	var next: Vector2 = Vector2(INF if ray.x == 0.0 else (edge.x - point.x) / ray.x, INF if ray.y == 0.0 else (edge.y - point.y) / ray.y)
	var path: Array = []
	var support: float = 0.0
	var cost: float = 0.0
	var surface: float = 0.0
	while true:
		var hit = null
		for shape in body.shapes:
			var material: int = shape.get_pixel(cell.x, cell.y)
			if material != 0:
				hit = {"shape": shape, "position": cell, "material": material}
				break
		if hit == null:
			return path
		path.append(hit)
		if world != null:
			var strength: float = world.material_strength(hit.material).x
			if player and strength <= 0.0:
				strength = reference_strength
			if surface == 0.0:
				surface = strength
			support += strength / surface if strength > 0.0 else support_max
			cost += strength if strength > 0.0 else INF
			if support >= support_max and cost >= budget:
				return path
		# 正好经过格点时同时跨两轴，不把仅触碰角点的邻格算作实体层。
		if is_equal_approx(next.x, next.y):
			cell += step
			next += delta
		elif next.x < next.y:
			cell.x += step.x
			next.x += delta.x
		else:
			cell.y += step.y
			next.y += delta.y
	return path


## 半像素步进保证不跨格；每段只改变方向，不增加破坏预算。
func _crack_path(body: PBody, origin: Vector2, direction: Vector2, world,
		budget: float, seed: int, mirror: float = 1.0) -> Array:
	var point: Vector2 = body.to_local(origin)
	var base: Vector2 = direction.rotated(-body.rotation).normalized()
	var ray: Vector2 = base
	var last: Vector2i = Vector2i(1 << 30, 1 << 30)
	var path: Array = []
	var cost: float = 0.0
	var turn: int = 0
	while true:
		var cell: Vector2i = Vector2i(point.floor())
		if cell != last:
			last = cell
			var hit = null
			for shape in body.shapes:
				var material: int = shape.get_pixel(cell.x, cell.y)
				if material != 0:
					hit = {"shape": shape, "position": cell, "material": material}
					break
			if hit == null:
				return path
			path.append(hit)
			var strength: float = world.material_strength(hit.material).x
			if strength <= 0.0:
				return path
			cost += strength
			if cost >= budget:
				return path
			if path.size() % crack_turn_pixels == 0:
				var angle: float = (_noise(seed, turn + 31) * 2.0 - 1.0) * crack_turn_degrees * mirror
				ray = base.rotated(deg_to_rad(angle))
				turn += 1
		point += ray * 0.5
	return path


func _noise(seed: int, index: int) -> float:
	var value: int = absi(seed % 2147483647)
	value = (value + (index + 1) * 48271) % 2147483647
	value = (value * 1103515245 + 12345) % 2147483647
	return float(value) / 2147483647.0


## 预留剪切入口；第一版不消费切向摩擦冲量。
func calculate_shear() -> void:
	pass
#endregion


#region 现有破坏接口
## 每个受损物体提交一次掩码，分片由引擎负责。
func commit(physics, removals: Dictionary) -> Dictionary:
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var changed: Array = []
	var removed: int = 0
	var fragments: int = 0
	for body in removals:
		var anchor_points: Dictionary = body.tags.get(ANCHOR_TAG, {})
		var result: Dictionary = physics.fracture_pixels(body, removals[body], 0.0, true,
			_anchor_map(body, anchor_points))
		removed += result.removed
		fragments += result.fragments.size()
		# 档 C-1：够薄的碎片挪到灰尘层（只跟静态世界碰）。
		_isolate_debris(result.fragments)
		# 档 C-3：太薄、**没进物理**的碎片交给灰尘层 —— 还看得见，只是不再参与物理。
		if _dust != null:
			_dust.spawn(result.get("downgraded", []))
		if result.removed > 0:
			changed.append(body)
			changed.append_array(result.fragments)
			for changed_body in [body] + result.fragments:
				_update_anchors(changed_body, anchor_points)
	if profile_enabled:
		_profile.commit_us = _profile.get("commit_us", 0) + Time.get_ticks_usec() - profile_start
		_profile.commit_calls = _profile.get("commit_calls", 0) + removals.size()
		_profile.removed_pixels = _profile.get("removed_pixels", 0) + removed
		_profile.fragments = _profile.get("fragments", 0) + fragments
	return {"changed": changed, "calls": removals.size()}


## 【档 C-1】把够薄的碎片挪到**灰尘层**：它们只跟地形/道具碰，碎片之间、与玩家都不碰。
##
## ⚠️ 语义（引擎的 collision_layer/mask）：两个刚体要碰必须**双方都同意** ——
##      (A.layer & B.mask) != 0  且  (B.layer & A.mask) != 0
##    灰尘 layer=2 / mask=1（只要「默认层」那一层）；地形/道具 layer=1 / mask 全开
##    -> 两边都同意 -> 照碰。灰尘 vs 灰尘：(2 & 1) == 0 -> 不碰。
##    ⚠️ **玩家必须离开第 1 层**，否则这里等于没做（见 PLAYER_LAYER 的说明）。
## ⚠️ 判据用 visible_short_side()（**外接盒**短边），不是 thinnest_extent()（最薄矩形）：
##    后者会被斜边切出的 1 像素矩形骗到 —— 一块 29x29 的斜切块 thinnest=1，
##    于是它明明看得见、却被判成灰尘（或在这里被隔离）。实测踩过，见 PBody 的墓碑。
## ⚠️ 大块**不动**（thinnest > 阈值就跳过）：否则「大块落在碎块堆上」会直接穿过去。
## ⚠️ 引擎在 rebuild() 之后会把 layer/mask 重推给 Rapier（op 32）——
##    所以这里改完立刻生效，不需要额外的「通知」步骤。
func _isolate_debris(fragments: Array) -> void:
	if debris_isolate_thickness <= 0.0:
		return
	for f in fragments:
		if f == null or f.is_static:
			continue
		# ⚠️⚠️ **只动还留在默认过滤器上的碎片。** 调用方显式设过的层/掩码不碰 ——
		#    那是它的配置。engine 的 fracture_pixels 本来就保证「碎片继承母体的
		#    层/掩码」，在这里无条件覆盖等于把那条保证作废。
		#    test_collision_damage 的「fracture preserves material and collision
		#    properties」正是钉这条 —— 我第一版无条件覆盖，当场把它打红（41/0 -> 40/1）。
		if f.collision_layer != DEFAULT_LAYER or f.collision_mask != DEFAULT_MASK:
			continue
		if f.visible_short_side() > debris_isolate_thickness:
			continue
		f.collision_layer = DEBRIS_LAYER
		f.collision_mask = WORLD_LAYER


func _anchor_map(body: PBody, points: Dictionary) -> Dictionary:
	var anchors: Dictionary = {}
	for shape in body.shapes:
		for point: Vector2i in points:
			if shape.get_pixel(point.x, point.y) == InkPalette.nail_material_id():
				if not anchors.has(shape):
					anchors[shape] = {}
				anchors[shape][point] = true
	return anchors


func _update_anchors(body: PBody, points: Dictionary) -> void:
	var live: Dictionary = {}
	for shape in body.shapes:
		for point: Vector2i in points:
			if shape.get_pixel(point.x, point.y) == InkPalette.nail_material_id():
				live[point] = true
	if live.is_empty():
		body.tags.erase(ANCHOR_TAG)
	else:
		body.tags[ANCHOR_TAG] = live
#endregion
