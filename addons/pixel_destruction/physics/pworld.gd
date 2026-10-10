extends RefCounted
## 物理世界：固定步长管线 + 岛屿休眠 + 破坏/分裂。
##
## 管线（与参考实现一致）：
##   IntegrateForces -> Broadphase -> Narrowphase -> Solve -> IntegrateTransform -> Sleep
## 破坏发生在窄相之前：先改拓扑，再让物理看到最新数据。

const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const Collide := preload("res://addons/pixel_destruction/physics/collide.gd")

const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Grab := preload("res://addons/pixel_destruction/physics/grab.gd")
const PJoint := preload("res://addons/pixel_destruction/physics/joint.gd")
const Sweep := preload("res://addons/pixel_destruction/physics/sweep.gd")

const Query := preload("res://addons/pixel_destruction/physics/query.gd")

var bodies: Array = []
## 刚体**增删**的版本号（add_body / remove_body 各 +1）。
##
## ⚠️ 存在的理由：节点层的 `_body_nodes` 与 `bodies` 有一条**硬不变量**（按下标一一对应），
##    而任何绕过节点层增删刚体的路径都会破坏它 —— 直接调 `fracture_pixels`、门面 `spawn_*`、
##    灰尘策略里的 `remove_body`、调试脚本里的 `add_body`。
##    症状**不是报错**：数组变长时静默错位（节点层的渲染归属会去问**别人的节点**）；
##    数组变短时会让"按下标取节点"的消费方（游戏层的同步循环）**越界中断** ——
##    那之后的刚体（通常正是新碎片）这一帧不再被 sync，贴图停在旧位姿，
##    看起来就是"碎片有位置偏差"。
##    `PixelWorld` 现在按这个版本号自动调 `realign_body_nodes()`，所以**消费者不用再记这条规矩**。
var bodies_rev := 0
var shapes_needing_coarse_proxy := 0
## 重力要按**可见尺度**定，不是按世界坐标的绝对值。
## 缩放 3 倍时可见高度只有 180 世界单位，900 的重力意味着物体 1 秒后
## 每秒下落 2.5 个屏幕高度 —— 快到看不清。600 下从静止落满一屏约 0.8 秒。
var gravity := Vector2(0.0, 600.0)
## 终端速度：只钳下落分量（不影响水平抛出和爆炸的冲量），
## 这样"掉多久"和"从多高掉"无关，手感可预测。
var terminal_speed := 650.0
## 角速度上限（rad/s，<= 0 = 不钳）。**只钳角速度，不动线速度**。
##
## ⚠️ 为什么需要它：Rapier 2D 0.36 **只有线速度上限**（normalized_max_linear_velocity），
##    **没有角速度上限**（把 crate 源码翻过：全库搜 max_angular_velocity 零命中）。
##    而角速度恰恰是**质量放大**的那个通道：Δω = J·r/I，而 **I ∝ m** ——
##    同一个力矩，轻 100 倍的碎片角速度大 100 倍。
##    症状与线速度那条同源：子步估计里有一项 |ω| x 外接半径，
##    所以一个疯狂自转的小碎片就能把全世界拖进几百个子步。
##
## ⚠️ 默认给一个**宽松但有限**的值（与 rp_max_linear_velocity = 40000 同一个哲学：
##    它用来挡数值爆炸，不是手感旋钮）。要按玩法收紧就调小它。
## ⚠️ 它**不**替代 debris_max_mass：那个是"清掉灰尘"，这个是"别转到离谱"。
var max_angular_velocity := 1000.0
var fixed_dt := 1.0 / 60.0
var max_substeps := 4

var sleeping_enabled := true
var sleep_linear := 6.0
## 角速度那一半判据用**表面速度**（px/s），不是裸角速度。
## 绝对角速度阈值会把小碎块永久钉在"醒着"（见 PBody.is_slow 的实测数据）。
## 睡眠的**表面速度**容差：|ω| * bounding_radius() 要小于它才算「慢」。
## 休眠的表面速度阈值：接触点处速度 = 线速度 + 角速度 × 力臂。
##
## ⚠️ 这个值曾经**和接触点公式绑死**，现在解开了 —— 现在的 6.0 是接触点修好
## 之后重新量出来的（数值和最初那个 6.0 相同，但理由完全不同，别再混为一谈）。
##
## 历史：接触点公式错误时（合成点落在窄物体的形心上），推测接触实际是死的，
## 静止堆叠会残留 0.43~0.48 rad/s 的角速度；20x20 方块的对角半径约 14，
## 表面速度 ≈ 6.7 刚好压过 6.0 —— 于是"几乎不动"的箱子永远醒着。
## 当时把阈值提到 12.0 把它盖住了 —— **那是在盖症状，不是修问题**。
##
## 接触点改回真实几何（见 collide.gd 的墓碑注释）之后重新扫过：
##   · 单场景扫描（sleep_box / sleep_frag，各扫 4/6/8/10/12）：
##       surf=4.0  → sleep_box 12/12 清醒（最大表面速度 7.624）
##       surf>=6.0 → 两个场景全部入睡，最大表面速度 0.000
##   · 当初促成 12.0 的那条诊断（tests/diag_sleep_surface.gd，gap=4/8 的三层
##     堆叠）在 6.0 下**全部入睡**（vmax / wmax 都是 0）
## 所以 6.0 已经够用，12.0 偏松（会让真正在慢慢转的堆叠也睡着）。已改回 6.0。
##
## ⚠️ 改这个值会动两条休眠基准。**当前基准（6.0）**：
##     sleep_box  -4.465181229425  (0/12)
##     sleep_frag -39.158215979656 (0/120)
## 参考：12.0 时是 -4.415035308716 / -39.175550847507（已废弃）。
## 另外四条非休眠基准不受影响（那些场景 sleeping_enabled = false）。
##
## ⚠️ 它还和 _wake_pair 耦合：那里用 sleep_surface * 2.0 判"邻居算不算在动"，
##    所以这个值一变，"睡着的物体被谁唤醒"也跟着变（6.0 → 唤醒门槛 12.0，
##    12.0 时是 24.0）。改它之前先看一眼 _wake_pair 与坑 37。
var sleep_surface := 6.0
var sleep_delay := 0.4

## ---- 连续碰撞（CCD）：自适应子步 ----
## 高速度下"一步跨过薄物体"是离散碰撞的固有缺陷。这里不去做复杂的扫掠，
## 而是按"本步最大位移"把这一步切成若干子步，保证任何物体每个子步
## 移动不超过 ccd_max_motion。朴素但极稳，也是 Dennis 新引擎的思路
## （sub-stepping instead of solver iterations）。
var ccd_enabled := true
var ccd_max_motion := 2.0      ## 每个子步允许的最大位移（世界单位）
## 全局子步数的**硬上限**（0 = 不限，**默认**）。
##
## ⚠️⚠️ 这个声明曾经是**死的**：写成 16，而全引擎没有一处读它 —— 真实的钳制是
##    ccd_substep_budget = 600（在 _compute_substeps 的 clampi 里），两者差 37 倍。
##    历史：Rapier 迁移**之前它是活的**（开发日志：「_ccd_saturated = (n >= ccd_max_substeps)
##    —— 只有顶满才需要兜底」），迁移时对象路径整块删掉，把这个上限一起带走了，
##    而手册 docs/manual/performance.md 一直写着「手动调 ccd_max_substeps 要小心：
##    子步数会改变接触时序」—— **文档说它有用，代码里它什么都不做**。
##    静默失效是最坏的失败方式，所以现在接回来。
## ⚠️ 默认 **0 = 不限**（保持 8 条逐位基准不变）；要收口就显式设一个值。
##    与 ccd_substep_budget 的分工：那个是「按世界大小的代价预算」，
##    这个是「不管世界多大，步数都不许超过 N」。
var ccd_max_substeps := 0
## 子步是**全局**的：最快的那个物体会逼着所有物体陪它把整条管线重跑 N 遍。
## 所以子步数必须按物体数摊一个预算，否则一屏碎块会把帧时间直接乘 16。
## （实测 240 个高速碎块时 60 帧里有 57 帧跑满 16 子步，帧时间 500 ms。）
var ccd_substep_budget := 600
## 子步循环的**时间预算**（微秒/固定步，0 = 关，**默认**）。
##
## ⚠️ 与 ccd_grab_substep_cost_budget_us 的唯一区别：那个**只在抓取时**生效，
##    这个**任何时候**都生效。换算公式同源（见 grab_substep_cap）。
## ⚠️ 为什么需要「任何时候」的那一道：「抓着一个东西拖动」和「一个碎片飞过去」
##    对帧时间的破坏是**同一个机制** —— 子步数只由**一个**最快的刚体决定，
##    而子步是全局的（每子步都要步进整个世界）。抓取那道闸门恰好漏掉了后者。
##    实测（876 矩形 = 真实地图规模，tests/ 外的使用方场景）：
##      一个 2x2 碎片以 20000 px/s 飞过 -> 167 子步 -> 307 ms/固定步
##      以 40000 px/s                    -> 334 子步 -> 593 ms/固定步
##    配合「一帧追 4 个固定步」的累加器，一帧能叠到几秒。
## ⚠️ 代价：重场景里子步变少 -> 每子步位移变大 -> 超高速物体**穿模**。
##    这是「用穿模换帧时间」的旋钮；引擎自带的第二层防穿（Rapier 的逐体 CCD）
##    还在，所以不是必然穿（见 ccd_ignore_mass 的墓碑）。
var ccd_substep_cost_budget_us := 0.0
## 只有**最薄尺寸 >= 本值**的刚体才参与「全世界最快运动」的统计（0 = 关，全都参与）。
##
## 比它薄的算**灰尘**：不驱动子步（一个 2x2 碎片不该让全世界重跑 N 遍），
## 防穿交给 Rapier 的逐体 CCD（rp_ccd_substeps）或者干脆放它们穿。
##
## ⚠️ 与 ccd_ignore_mass 的分工：那个按**质量**判，而质量 = 像素数 x **密度** ——
##    同一个「看起来一样大」的碎片，石头（2.5）和金属（7.8）差 3 倍，换个材质就跨过阈值。
##    **看得见看不见是尺寸说了算，不是密度。** 两个都开就取并集（各自独立豁免）。
## ⚠️ 判据是 PBody.thinnest_extent()（逐体按尺寸），**不是** bounding_radius：
##    一根 1x100 的细条外接半径约 50，但它只有 1 像素厚，照样穿得过去。
##    实测（本引擎的 diag_dust_substep 场景）：一个 2x2 碎片以 40000 px/s 飞行，
##    子步 3 -> 334，那一帧 3.2 ms -> 346 ms —— 而那是个**看不见**的东西。
var ccd_min_driver_thickness := 0.0
## 轻碎片**豁免子步估计**（0 = 关，**默认关**）。质量 <= 它的刚体不参与"全世界最快"的统计。
##
## ⚠️ 为什么需要它（实测 tests/diag_dust_substep.gd）：子步数取的是**全世界最快**的
##    那个刚体，所以**一个** 2x2 的碎片就能拖慢全世界 —— 240 个碎片的场景里，
##    一个 2x2 碎片以 40000 px/s 飞行：子步 3 -> **334**，那一帧 **3.2 ms -> 346 ms**。
##    而防穿的意义是"别让**看得见的东西**穿墙"：2x2 的灰尘穿过去没人看得出来。
##
## ⚠️ 豁免 = **放松防穿**：这些碎片会穿墙（然后掉出世界、被 cull_outside 收走）。
##    ⚠️ 但实测（tests/diag_ccd_tunnel.gd）代价比这句话小得多：防穿有**两层** ——
##    ① 本引擎的子步（豁免掉的就是这一层）；② **Rapier 自己的 CCD**（rp_ccd_substeps，
##    默认 1）。第 ② 层还在时，豁免体照样被 swept 挡住：10x10 以 30000 px/s 撞 4 像素
##    薄墙、子步只有 1，结果**挡住**；只有把 rp_ccd_substeps 也设成 0 才真的穿过去。
##    所以"会穿墙"是**第 ② 层也关掉时**的后果，不是必然。
## ⚠️ 抓着的 / 挂着关节的**永不豁免** —— 那些是要交互的，穿墙会被玩家看见。
## ⚠️ 它只治"拖慢"，不治"灰尘还在飞"（那个见 debris_max_mass）。
var ccd_ignore_mass := 0.0
## 灰尘**直接删掉**（默认关：debris_max_mass = 0）。
## 判据：mass <= debris_max_mass **且**（若 debris_min_speed > 0）运动 >= debris_min_speed。
##
## ⚠️ **debris_min_speed = 0 表示"不限速度"**（只按质量清，静止的也清）。这不是笔误 ——
##    甲方把 speed 设成 1 期望"清掉小碎片"，结果一个都没清：**静止的碎片 motion 恒为 0**，
##    任何正阈值都拦得住躺在地上的碎块（实测 speed = 1 / 0.5 / 0.1 / 0.01 / 0.001
##    全都没清，见 tests/diag_debris_port.gd）。两种需求用这一个旋钮表达：
##      · speed > 0 = 只清"**正在高速飞的**灰尘"（挡子步尖峰，demo 用的就是这种）；
##      · speed = 0 = 清掉所有够轻的（"扫地"，不管它动不动）。
## ⚠️ 质量要按**密度**算：mass = 像素数 x 该材质密度。4x4 的碎片在密度 2.5 下是
##    **质量 40**、密度 7.8 下是 124.8 —— 别拿像素数当质量。
##
## ⚠️ 为什么是**两个阈值**、而不是"质量/速度的比值"：它们回答两个不同的问题 ——
##    速度 = "它要全世界陪它跑多少子步"（每步位移 > ccd_max_motion 才有影响）；
##    质量 = "没人会在意它穿墙/消失吗"。比值把两者耦合，形状是**锥形** v >= R*m：
##      · 会删掉"很轻但很慢"的无害灰尘（mass=1、v=200 -> 比值 200，而它只要 2 子步）；
##      · 会留下"很重但很快"的（mass=1000、v=3000 -> 比值 3，而它要 25 子步）。
##    两个阈值是**角形**判据 {m <= M, v >= V}，正好对应"贵 **且** 不值钱"。
##
## ⚠️ 删掉会**打破体素守恒**（detach 的不变量）—— 玩家会看到碎片凭空消失。
##    所以默认关。与 ccd_ignore_mass 的分工：那个是"留着但别拖慢世界"，这个是"清掉"。
## ⚠️ 静态 / 冻结 / 抓着 / 挂着关节的**永不删**。
var debris_max_mass := 0.0
var debris_min_speed := 0.0
## 上一次 step 里删掉的灰尘数（诊断用，与 last_substeps 同源）。
var last_debris_removed := 0
## 抓着东西时，子步数**只涨不落**（迟滞开关）。
##
## ⚠️⚠️ 为什么需要它：子步数是按**全世界最快的那个刚体**算的，而它一变，**所有**刚体
##    的积分步长就跟着变。拖动一个物体时速度是连续变化的，于是子步数每帧都在跳
##    （实测拖动 4 秒：{1:36, 2:30, 3:46, 4:62, 5:58, 6:8}，采样 [4,1,5,3,2,5]）——
##    静止物体的亚像素平衡位置随之来回变，画面上就是"抓起别的物体时，吊桥跟着抽搐"
##    （甲方报的正是这个）。
##
## ⚠️ 迟滞**只在抓着东西时**生效：不抓时保持原来的行为（need 是多少就多少），
##    否则 dump_state 的 sleep_frag 会变（实测 -35.696264844083 -> -35.760093441963）——
##    那是把"拖动时的稳定性"和"基准不动"这两件事分开的唯一办法。
# ⚠️ 这里曾经有个 ccd_substep_hold := 0.25（"保持期"开关），但**代码从没读过它** ——
#    迟滞实际由 _compute_substeps 里的 grabs.is_empty() 实现（见那里的说明）。
#    我在提交 0e26d1c 的信息里写过"把它删掉"，其实没删；现在真删了，别再让它假装是个开关。

## 抓取时**每个物理步**允许花在子步循环上的代价上限（微秒）。
## 抓着东西时，子步数还要再按**世界大小**压一遍：need = 本值 / (总矩形数 x CCD_RECT_COST_US)。
##
## ⚠️⚠️ 为什么：子步是**全局**的 —— 每个子步都要把整个世界步进一遍，所以帧时间随
##    "子步数 x 世界大小" 涨。用户报的"1000 矩形时按住 Ctrl 左键拖动掉到 8 帧"就是这条：
##    一次快速拖动 = 25 子步 x 每个子步都要步进 1000 个矩形。
##
## ⚠️⚠️ 标定（2026-10 重测）：**每矩形每子步不是 1 us**。旧注释写 1 us 是在
##    "单个静态刚体扛 1000 个矩形"的场景量的（tests/validation_grab_budget.gd：
##    1001 矩形 / 5 子步 / 最坏一帧 5.66 ms = 1.13 us/矩形）。静态矩形只进宽相、
##    不进求解器，那是**最便宜**的一头。
##    碎块场景（动态刚体多、接触对多）实测 **2.8~4.9 us/矩形**
##    （tests/bench_contact_light.gd：506/1006/2006/4006 矩形 -> 2.77/2.96/3.51/4.86 us，
##    边际 3.15/4.07/6.21 us；两次独立跑动的散布约 ±0.3）—— 旧标定让这个保护上限
##    在**它最该起作用的场景里松了 4 倍多**，所以常数取 4.4（见 CCD_RECT_COST_US）。
##
## ⚠️ 它仍然是"每帧 6 ms"这个量级的上限：6000 us / (4.4 us/矩形) ≈ 1364 个
##    "矩形·子步"。510 矩形的场景 -> 2 子步；1000 矩形 -> 1 子步。
##
## ⚠️ 只在**抓取时**生效 —— 不抓时完全走原来的行为，所以 8 条基准**逐位不变**
##    （它们不抓东西）。这和迟滞（_compute_substeps 里 grabs.is_empty() 那一段）的取舍同源：
##    把"拖动时的可用性"和"基准不动"这两件事分开。
##
## ⚠️ 代价：重场景里子步变少 -> 每子步位移变大 -> 被 ccd_clamp_motion 钳住 ->
##    那一帧**变慢动作**（绝不穿模，和子步上限被顶满时同一个取舍）。
##    ⚠️ 标定更正之后这个上限**更容易被碰到**：510 矩形 -> 2 子步，也就是拖动超过
##    ~240 px/s 就会被钳（旧标定下是 11 子步、~1320 px/s 才碰到）。觉得拖不动就把
##    本值调大 —— 那是"用帧时间换手感"的旋钮。但**别把 CCD_RECT_COST_US 改小来
##    假装保护还在**：它量的是真实代价，改它只是让上限说谎。
## 关节感知的 CCD 子步（表 ③）：把**焊接组件**当成一个整体估运动，而不是逐刚体取最快。
##
## ⚠️ 为什么需要：子步数是按"全世界最快的那个刚体"算的，而焊接组件里的**轻质件**在关节
##    求解之前的**瞬态**速度可以非常大 —— 它不是真的在飞，是求解器还没把它按住。
##    甲方在 ink-2 实测：轻手焊在地面上被拖动时子步数峰值 **53**，而帧时间随
##    "子步数 x 世界大小" 涨（子步是全局的）。
##
## 判据（三种情况）：
##   · 组件**被静态世界焊住**（直接或间接、且焊接**断不开**）-> 它整体动不了 -> 记 0；
##   · 组件里有多个动态刚体 -> 记**质量加权**的整体运动（质心速度 + 角速度 x 组半径），
##     轻质件的瞬态被重的那些压下去；
##   · 其余 -> 和以前一样，记自己的运动。
##
## ⚠️⚠️ 为什么默认**关**：它拿掉了"瞬态速度"这道安全余量。
##    能用它的理由是：关节求解器**在同一步内**就把速度纠正回来（位置积分用的是纠正后的
##    速度），所以"瞬态"不会变成真实位移。但**薄壁防穿必须自己验过**再开 ——
##    闸门 tests/validation_ccd_joint_aware.gd 里有"焊在静态世界 + 瞬态冲向 2 像素薄墙"那一组。
## ⚠️ 安全阀：只要组里有**断得开**的焊接（`break_impulse` 有限），这个组就**不摊平**
##    （退回逐刚体最大）—— 焊接断掉那一帧刚体是真在飞，摊平它等于放松防穿。
var ccd_joint_aware := false

## **逐体** CCD（默认 false = 老行为：ccd_enabled 一开，全世界每个刚体都是 Rapier 的 bullet）。
##
## ⚠️⚠️ 为什么需要：Rapier 的 CCD 有**两档**（官方文档 rigid_body_ccd）——
##   ① 「每个快速动态刚体都会被扫过**固定**碰撞体」，**自动的、不用开**，
##      用来挡「快物体 vs 静态世界」（掉下来的箱子、飞出去的子弹撞墙）；
##   ② 「开了 CCD 的刚体（bullet）连**运动学/动态**目标一起扫」——文档原话
##      "This is more expensive, therefore it is disabled by default and should be
##       reserved to the objects that must not tunnel through moving obstacles."
##    而本引擎推的是 `1 if ccd_enabled else 0` —— **全世界每个刚体都变成 bullet**。
##    第 ① 档本来就在挡最常见的那种穿模，把每个碎片都升成 bullet 是纯浪费：
##    bullet 的扫掠目标集包含动态体，而碎片堆里动态体最多。
## ⚠️ 开着时：ccd_enabled 只当**总闸**，具体谁开由 PBody.ccd 决定
##    （ccd_auto 已经能给「按自身尺寸需要它」的刚体自动打标，见 PBody.needs_ccd）。
## ⚠️ 默认 **false** -> 8 条逐位基准与既有闸门逐位不变。
var ccd_per_body := false

## 速度的**表面速度**上限（px/s，0 = 关，**默认**）。
##
## ⚠️⚠️ 为什么角速度要按表面速度收：max_angular_velocity 是**绝对 rad/s**，
##    而子步估计用的是 |w| x 外接半径（表面速度，见 _motion_of）。同一个物理量，两把尺子：
##      · 线速度上限 1000 px/s 只值 ceil(1000/120) = **9 子步**；
##      · 60 rad/s x 300 px 外接半径 = 17860 px/s -> **151 子步**。
##    Rapier 自己在 CCD 组件上把角速度钳成 "~45°/step **to keep CCD reliable**" ——
##    它关心的是**表面走了多远**，不是转了多少弧度。引擎对**睡眠**用的也是表面速度
##    （sleep_surface 的墓碑：「绝对角速度阈值会把小碎块永久钉在醒着」），
##    只有 CCD 这一侧用了裸 rad/s。
## ⚠️ 它与 max_angular_velocity **并存**（取更紧的那个）：
##    那个是"绝对转速别离谱"（数值安全），这个是"表面速度别离谱"（CCD 成本）。
## ⚠️ 默认 **0 = 关** -> 基准逐位不变。
var max_surface_speed := 0.0

## **不做全局子步**：子步数恒为 1，防穿完全交给**逐体 CCD**（默认 false = 老行为）。
##
## ⚠️⚠️ 为什么这才是对的：子步是**全局**的（每个子步都要把整个世界重跑一遍），
##    而防穿是**逐体**的。用全局子步防穿 = 让一个最快的小碎片决定全世界的帧时间。
##    实测（4 像素薄墙 + 12x12 块，tests/_probe_tunnel2.gd 的同款用例）：
##      · 全局子步 开 + 逐体 CCD 软预测 0.0：20000 px/s -> 峰值 **167 子步**，停在 x=188.1
##      · 不做全局子步 + 逐体 CCD 软预测 1.5：20000 px/s -> 峰值 **1 子步**，停在 x=188.0
##    花 167 倍的代价，换来的是一个**更差**的结果。
##    对照：把 Rapier 的 CCD 也关掉 -> 20000 px/s 停在 x=3247（穿过去了）。
##
## ⚠️ 打开后，下面这一整组「怎么算子步数」的旋钮都不再参与：
##    ccd_max_motion / ccd_substep_budget / ccd_ignore_mass / ccd_min_driver_thickness /
##    ccd_max_substeps / ccd_substep_cost_budget_us / ccd_joint_aware / grab_substep_cap。
##
## ⚠️⚠️ **开了它就必须确认逐体 CCD 真的武装好了**，否则这是「把防穿整个关掉」。
##    两个前提：`rp_ccd_substeps >= 1`（Rapier 的总闸）**且**
##    `rp_soft_ccd_prediction > 0`（没有提前量的逐体 CCD 约等于半开 —— 见那个旋钮的说明）。
##    缺任何一个，下面会 push_warning 吵一声（静默失效是最坏的失败方式）。
var ccd_per_body_only := false
## 逐体模式下用**固定**几个子步（默认 1）。
##
## ⚠️⚠️ **为什么不是恒为 1**：子步不只是防穿 —— 它**同时**是求解器的收敛手段
##    （TGS / Box2D v3 的「Soft Step」：用更小的时间步代替更多迭代）。
##    实测：把子步从 2~4 塌到 1，使用方的 test_hand_physics 里
##    「grounded/held object lifted」当场变红（抬升 46.25 -> 39.88）—— **抓取变软了**。
##    所以逐体模式的正确形态是「步数**固定且小**」，不是「恒为 1」。
## ⚠️ 它必须是**常数**：要拿掉的是「按最快刚体自适应」，不是子步本身 ——
##    前者才是「一个碎片决定全世界帧时间」的来源。
## ⚠️ 默认 1 = 保持既有基准（8 条逐位基准跑的就是这条路，而它们不开逐体模式）。
var ccd_fixed_substeps := 1
## 上面那个警告只吵一次（不然每步一条，日志会被淹掉）。
var _ccd_per_body_warned := false

var ccd_grab_substep_cost_budget_us := 6000
## 每个**矩形每子步**的实测代价（微秒）。抓取时的子步上限按它换算成时间。
##
## ⚠️⚠️ 旧注释写的是 **1**（"1000 矩形 ≈ 1.0 ms/子步"）—— 那是在**单个静态刚体**
##    扛 1000 个矩形的场景量的，而静态矩形只进宽相、不进求解器，是最便宜的一头。
##    碎块场景实测 2.8~4.9 us/矩形（数字与测法见上面 ccd_grab_substep_cost_budget_us
##    的说明）。**保护上限必须按最坏场景标定** —— 按最便宜的场景标定，等于在
##    需要它的地方恰好失效（旧值在碎块场景里松了 4 倍多）。
##
## ⚠️ 这个常数是**场景相关**的（静态多的场景实测能低到 1.1）：它是"保护上限"，
##    宁可偏保守 —— 偏保守的代价是重场景里拖动变慢动作（见 ccd_clamp_motion），
##    偏松的代价是掉帧。
const CCD_RECT_COST_US := 4.4
## ⚠️⚠️ **这个旋钮现在是死的**（Rapier 迁移的遗留）：全引擎没有一处读它。
##    它描述的行为（"子步被顶满时把每子步位移硬钳在 ccd_max_motion"）属于**已删除的
##    对象路径**里的 _integrate_transforms —— 现在位置由 Rapier 积分，引擎只在**读回时
##    钳速度**（max_angular_velocity / terminal_speed / max_surface_speed），
##    没有"事后把位移拉回来"这个环节。
##
##    历史（开发日志坑）：那条硬钳曾经**无条件生效**，把"偶发穿模"升级成"全局慢动作"
##    —— 每子步 2 像素 = 60 fps 下 120 px/s 上限，而重力是 900 px/s²，
##    箱子根本落不下来，看起来像浮在半空。教训原文：
##      「安全网必须挂在它该生效的条件上。无条件生效的"保护"不是保护，
##        是把故障从"偶发穿模"升级成"全局慢动作"。」
##    **不要**为了让它"看起来有用"就把它接到 Rapier 路径上 —— 那等于把那个坑再踩一遍。
##    真要硬保证就调 ccd_max_motion（每子步位移上限）或 ccd_max_substeps（步数上限）。
##
## ⚠️ 保留声明而不是删掉：它是**已发布的 API**（v0.3.2 起的 release notes 与
##    tests/diag_* 都在引用），删掉会让下游代码直接报"属性不存在"。
##    但它**什么都不做** —— 这一点必须写在脸上，不能让下一个人再猜一次。
var ccd_clamp_motion := true
## 自动给刚体打**逐体 CCD** 标记：本步运动超过**自身最薄尺寸一半**的刚体
## （PBody.needs_ccd，即 Rapier / Box2D v3 的判据）会被标成 Rapier 的 bullet。
##
## ⚠️ 只在 ccd_per_body = true 时有意义：那个关着时 ccd_enabled 已经把**所有**刚体
##    都推成 bullet 了（老行为），这个开关自然无所谓。
## ⚠️⚠️ **必须**同时开 ccd_min_driver_thickness，否则这个开关是**有害**的：
##    needs_ccd 的判据对小碎片是**反向**的（物体越小，变成"快体"所需速度越低 ——
##    60 Hz 下 1 像素碎片只要 30 px/s 就永久满足），无脑开等于把每个碎片都升成 bullet，
##    而 bullet 的扫掠目标集**包含动态体**，碎片堆里动态体最多。
##    代码里已经硬性排除了比 ccd_min_driver_thickness 薄的刚体（见推 op 19 那段）。
## ⚠️ 它**不**控制 Rapier 那一档"自动扫快物体 vs 固定碰撞体"—— 那一档永远开着，
##    是引擎免费的防穿第一层（见 ccd_ignore_mass 的墓碑：薄墙 + 子步 1 仍然挡住）。
##
## 历史：这个声明的旧注释描述的是"接进 _integrate_transforms 做精确 OBB 扫掠"，
##    而那条路径（对象路径 / GDScript 扫掠）**已经被删掉**（物理全交 Rapier）。
##    旧注释里那句待办"等根因 B 解决后，应当改成按**物体自身尺寸**判定是否需要 CCD"
##    **就是现在这件事** —— 判据已经是 PBody.needs_ccd（逐体按尺寸）。
var ccd_auto := true
var ccd_max_rotation := 0.25   ## 每个子步允许的最大转角（弧度）
## 推测接触的边际上限。
##
## ⚠️ 这个值**必须小于子步位移上限** @@ccd_max_motion(2.0)@@。1.5 对 2.0 是量出来的甜点：
##   · 边际 ≈ 每子步位移（实测 1.8/2.0）时，@@bias = -sep/dt@@ 允许物体**全速**撞上去，
##     接触出现的那一子步完全不刹车 —— 高速撞击会翻成陀螺并反弹
##     （实测 600 px/s：x 188 → 124、rot → -1.72、ω 峰值 8.45）；
##   · 边际太小（<= 1.0）时缓冲不够，落地轻微抖动 → @@sleep_box@@ 从 0/12 变 4/12 睡不着。
##
## 1.5 两边同时满足：撞墙 600/1500/3000 全部停在 188.0~188.1、rot 0；
## @@sleep_box@@ 保持 0/12 且摘要值与旧基线**逐位相同**。
## 顺带把子步数从 5/13/16 降到 1/1/1。
##
## 旧注释说"上限是为了限制接触点偏移产生的扭矩"—— 那是接触点公式错误
## （合成点偏出真实接触区，见坑 34）时的 workaround。
## 那个公式已经被删掉了（见 collide.gd 的墓碑注释）：现在分离与穿透走**同一套**
## 参考面/入射面裁剪，接触点就是真实几何，不再有"偏移"这回事。
## 上面那条（边际必须小于子步位移上限）仍然是**独立成立**的理由。
var max_speculative_margin := 1.5
var last_substeps := 1
var _substeps_held := 1

var _aabb_cache: Array = []


## ⚠️ 这里曾有 `_ccd_saturated`（"子步被顶满"的标记，给位移硬钳用）—— 已删：
##    它只被 tests/diag_grab.gd 读过一次，而它驱动的那个硬钳属于**已删除的对象路径**
##    （见上面 ccd_clamp_motion 的墓碑）。删掉它而不是留一个永远 false 的变量 ——
##    "永远为假的状态位"比没有更糟，它会让人以为某处还在用它做判断。

## ---- 多线程 ----
## WorkerThreadPool 并行度阈值：工作量太小的时候线程开销大于收益
const PARALLEL_MIN_CHUNKS := 96


## 并行任务参数（可在运行时扫描，见 tests/bench_priority.gd）。
## tasks_needed 控制把一个 group task 拆成几个并发任务；-1 = 自动。
##
## ⚠️ high_priority 默认 **false**，这是**量出来的**结论，不要随手改成 true：
##   · 低优先级通道只占线程池的约 30%（实测 4/16），看起来吃亏；
##   · 但真改成 true 之后，16 个线程并发跑求解器会让**每个任务自己的耗时涨 17 倍**
##     （实测 各任务合计 26.65 ms -> 452.66 ms），整体反而慢一倍
##     （36 塔场景整步 14.5 ms -> 35.3 ms，0.48x）。
##   原因见 tests/bench_isolation.gd：GDScript 的**对象属性读写**在 16 线程下
##   单元耗时会膨胀 93 倍（4 线程只有 4.2 倍）。求解器整条路径都是属性读写。
##   所以"线程池没给满"在这里反而是一种保护：更少的并发 = 更少的争用。
var parallel_high_priority := false


var _bp_count := 0


## 诊断用：_broadphase 两个阶段各花多久（收集候选 vs 求解）
var bp_collect_us := 0
## 宽相细分：GDScript 侧准备（扫掠 AABB + 排序 + 编码） vs 纯 C++ 调用
var bp_encode_us := 0
var bp_native_us := 0
var bp_sweep_us := 0     ## 扫掠 AABB
var bp_sort_us := 0      ## 排序
var bp_prep_us := 0      ## 编码打包表
var bp_resolve_us := 0


var last_parallel_tasks := 0

var min_fragment_pixels := 4
## 碎片的最薄尺寸低于它就不生成刚体（0 = 关，**默认**）。
##
## ⚠️ 与 min_fragment_pixels 是**两个轴**，不是同一件事的两种写法：
##    那个数**像素个数**（一个 1x20 的细条有 20 像素，照样过），
##    这个数**最薄尺寸**（同一条细条是 1，被挡住）—— 而厚度正是「能不能穿过去」的那个量。
##
## ⚠️ 命中的碎片**不消失**：它们随结果一起交回调用方（result.downgraded），
##    由美术层决定怎么处理（本仓库使用方的用法是降级成短命灰尘）。
##    为什么不能直接删：那会**打破体素守恒**（detach 的不变量），玩家会看见东西凭空消失。
##
## ⚠️ 为什么值得做：PBody.needs_ccd 的判据对小碎片是**反向**的（越小越容易满足），
##    所以「每个碎片都值得 CCD」是个陷阱 —— PhysX 官方把它写成失败模式警告
##    （paper-thin rigid body -> always above its CCD velocity threshold）。
##    业界做法是**根本不给它们刚体**：Teardown 有最小碎片尺寸、Noita 从不把散像素
##    升格成刚体、roxlap 让碎片落地即碎成纯表现粒子。
var min_fragment_thickness := 0.0
## 碎片**像素数**低于它也不生成刚体（0 = 关，**默认**）。
##
## ⚠️ 与 min_fragment_thickness 是**两个触发器、取并集**，各自管一件事：
##   · min_fragment_thickness  按**厚薄** —— 细长条会穿墙，而且穿过去没人看得出来
##   · min_fragment_pixels_downgrade 按**大小** —— 一小撮像素不值得一个刚体
##
## ⚠️⚠️ **为什么两个都要**：只按厚薄会**反直觉**。实测（使用方报的）：
##    一条 3x200 的细长条（600 像素，看着不小）因为「薄」变成灰尘，
##    而一颗 5x5 的方块（25 像素，看着很小）因为「不薄」留下来 ——
##    玩家看到的正是「大的成了灰尘、小的没成」。
##    反过来只按像素数也不行：1x20 和 4x5 都是 20 像素，但前者会穿墙。
##    **厚薄决定能不能钻过去，大小决定值不值得存在，两个问题，两个判据。**
var min_fragment_pixels_downgrade := 0
# 0 = 不设上限，永远精确。
# 精确覆盖与矩形上限不可兼得，宁可多几个矩形也不要幻影碰撞体。
var max_rects_per_shape := 0

## ---- 碰撞体多边形拟合（Noita 式）----
##
## 默认把**矩形集合拟合成凸多边形**再交给 Rapier：斜边是**直的**（锯齿被拉平）、
## 块数远少于矩形（实心地面 1 个、圆盘 1 个、平滑斜坡 4 个、楼梯 1 个）。
##
## ⚠️ 代价是**幻影**：凸包会把凹处填平，碰撞体比像素厚一点（上限 = poly_dev_tol）。
##    这是**有意的取舍**（Noita 也这么做：像素只是真源，交给 Box2D 的是凸形状）。
##    与 max_rects_per_shape 那条注释不冲突：那条管的是"矩形上限被顶到时怎么近似"，
##    这条管的是"要不要用多边形当碰撞体"—— 想要逐像素精确就把它设 false。
## ⚠️ 关掉（false）= 回到"一堆轴对齐矩形"，8 条逐位基准跑的就是那条路。
var poly_colliders := true
## 偏离容差（像素）：碰撞体允许比像素表面"厚"多少。
## 1 像素的台阶会被拉成斜线；12 像素的锯齿不会被填平（洞也不会被封死）。
## 判据与实测见 src/core/poly_fit.gd 与 tests/validation_poly.gd。
## ⚠️ 默认 1.0 而不是 2.0：判据是**平均**厚度，深而窄的凹口会被低估
##    （实测"墙+洞"在 2.0 时会封掉半个洞）。详见 poly_fit.gd 的说明。
var poly_dev_tol := 1.0
## 矩形数超过它就**不拟合**，退回精确矩形。
##
## ⚠️ 为什么要有这条闸：拟合是 O(矩形数 x 邻居数)，而且每次几何变化都要重算整块。
##    768x100 的高频锯齿地形有 769 个矩形 —— 那种形状拟合出来的块数几乎不减少
##    （高频锯齿本来就不是凸的），却要付整趟拟合的钱。默认 256 是实测的拐点。
var poly_max_rects := 256


## ---- 剖面计数（默认关）----
## 教训：只统计**累计耗时**会漏掉"每个阶段都不慢、整帧很慢"这类问题
## （典型原因是有个乘数在放大一切，比如子步被顶满）。
## 所以剖面必须同时给出**调用次数**：SAP 配对数 / 矩形对测试数 / SAT 调用数 / 流形数。
## 热路径上只多一次局部 int 自增，不用方法调用，profile_enabled 为 false 时开销可忽略。
var profile_enabled := false
var profile_counts: Dictionary = {}

## ⚠️ 墓碑：这里原来有 `var manifolds: Array` 与 `var _packed_manifolds := false`。
##
## 它们是「GDScript 宽相把接触装配成对象数组、再由 GDScript 求解器消费」那套路径的
## 产物。宽相 / 求解交给 Rapier 之后：
##   · `manifolds` **从来没被填过**（唯一的读者是 debug_overlay 的一个空循环）；
##   · `_packed_manifolds` 只剩声明（宽相里确实判过一次，但那条路已经不存在了）。
## 两个都已删除。这段留着是因为它记的教训仍然有效：
##
##   最初三处消费者各自判断 @@use_native_solve@@，而且宽相与求解看的口径还不一样 ——
##   按住拖动时宽相跳过对象装配、求解器却因为「有抓取」退回对象路径，拿到空数组，
##   于是**所有接触约束消失**（症状：拖动一个方块，其它方块全部掉穿地面）。
##   **同一子步内「走哪条路」只能有一个真源** —— 以后新增开关别再让两个地方各判一次。


var grabs: Array = []
## 关节（约束）。见 src/physics/joint.gd。
var joints: Array = []
## 断掉/移除掉的关节（诊断用：游戏层可以轮询它做音效/特效，然后自己 clear）。
var broken_joints: Array = []
var max_dynamic_bodies := 400

## 上一子步的接触点数（只读统计，给 debug_overlay / demo 用）。
##
## ⚠️ 它曾经在手写后端里由宽相填，换成 Rapier 后一度**永远是 0** ——
##    而 game.gd / debug_overlay.gd / bench.gd 都在读它。静默为 0 的统计
##    比没有统计更糟：看板上显示"接触 0"会让人以为物理没在跑。
var last_contacts := 0
var _accum := 0.0
var _next_id := 1


## 材质 id -> 密度。add_body 没显式给 density_of 时用它。
##
## 默认空表 = 全部按 1.0 算，也就是**质量 == 像素数**（1 像素 1 单位质量）。
## 想让石头比木头重就 set_material_density(1, 2.5)。
var material_density := PackedFloat32Array()
# ⚠️ 这里曾经有个 _density_fn 缓存字段，**已删除** —— 见 density_callable() 的说明。

## 材质 id -> 摩擦系数 / 碰撞恢复系数（与 material_density 同构）。
##
## ⚠️ Rapier 的接触系数由**两个碰撞体合成**（CoefficientCombineRule，默认 Average）：
##    地面 0.8 + 箱子 0.2 -> 接触处 0.5。所以"让某个材质说了算"要两边设同一个值。
var material_friction := PackedFloat32Array()

## op 5（重建碰撞体）给**新**碰撞体设的初始摩擦系数。
##
## ⚠️ 它原来叫 `solver.global_friction` —— 求解内核整体删除后，它是 Solver 里
##    **唯一**还有读者的参数（op 5 的命令流尾巴带着它），所以搬到这里。
##    默认 0.5 = Rapier 自己的默认值；重建之后每体的 b.friction 会紧跟着重推一次
##    （见「新碰撞体的摩擦/恢复回到 Rapier 默认」那一段）。
var global_friction := 0.5

## 允许的穿透深度（像素）——**判据用的容差，不是求解参数**。
##
## ⚠️ 它原来是 Solver 的求解参数（穿透修正 / 推测接触的配套）。求解交给 Rapier
##    之后它不再参与任何计算，但「盒子不能陷进地面」这条判据需要一个**引擎侧**的
##    阈值：在测试里硬编码数值正是开发日志记过的坑（test_parallel 把「不该陷过 1.0」
##    写死，参数一调就误报）。所以留成 PWorld 的常量，判据读它。
const PENETRATION_SLOP := 1.0
var material_restitution := PackedFloat32Array()
# ⚠️ 这里曾经有个 _friction_fn 缓存字段，**已删除** —— 见 friction_callable()。
# ⚠️ 这里曾经有个 _restitution_fn 缓存字段，**已删除** —— 见 restitution_callable()。


## 世界自己登记到查询模块，销毁时自己注销。
##
## ⚠️ 为什么不让调用方手动 attach：Query 的注册表是**静态变量**，
## 忘了注销就会一直持有刚体引用，Godot 退出时报
## "resources still in use at exit" / "Orphan StringName: RefCounted (static: 1)"。
## 让拥有者负责生命周期，调用方就没有"记得注销"这件事。
func _init() -> void:
	Query.attach(self)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		Query.detach(self)


## 设置某材质的密度（会自动扩容表，中间没设过的按 1.0 算）。
## ---- 材质强度表 ----
##
## 与 material_density 同构：下标即材质 id，缺省 0（= 不破坏，需要显式设）。
##
## 两种强度分开是因为**同一种材料抗压远强于抗剪** —— 这正是"矛能破盾、
## 盾不能破矛"的物理来源：矛尖对盾面是压缩，盾缘对矛杆是剪切/弯曲。
##
## 单位是"应力"，即 冲量 / 接触宽度，与 Contact.impulse / Contact.contact_width 同量纲。
var material_compress := PackedFloat32Array()
var material_shear := PackedFloat32Array()


## 设某材质的抗压/抗剪强度。shear 省略时取 compress 的 30%（多数固体的大致比例）。
func set_material_strength(material: int, compress: float, shear: float = -1.0) -> void:
	# ⚠️ shear <= 0 一律按抗压的 30% 处理，**不允许真的设成 0**。
	#
	# 这套 API 里 0 的语义是「不参与破坏」（调用方用 strength_for() > 0 判断）。
	# 如果 shear=0 被当成字面的 0，那么宽接触（shear_ratio → 1）算出的强度就是
	# lerpf(100, 0, 1) = 0 → 调用方跳过 → **配了强度的材质在剪切方向永远不破坏**，
	# 而且不报任何错。PixelMaterial.shear_strength = 0 正好会走到这条路。
	var s := compress * 0.3 if shear <= 0.0 else shear
	if material_compress.size() <= material:
		var n := material + 1
		material_compress.resize(n)
		material_shear.resize(n)
	material_compress[material] = compress
	material_shear[material] = s


func material_strength(material: int) -> Vector2:
	# ⚠️ 两张表的长度可能不同（material_shear 若被直接赋值就会更短），
	#    只按其中一张做界检查会越界。
	var n := mini(material_compress.size(), material_shear.size())
	if material < 0 or material >= n:
		return Vector2.ZERO
	return Vector2(material_compress[material], material_shear[material])


## 按 Contact 的 shear_ratio 插值出该用哪个强度。返回 0 表示"这个材质不破坏"。
func strength_for(material: int, shear_ratio: float) -> float:
	var s := material_strength(material)
	if s.x <= 0.0 and s.y <= 0.0:
		return 0.0
	return lerpf(s.x, s.y, clampf(shear_ratio, 0.0, 1.0))


func set_material_density(material: int, density: float) -> void:
	if material < 0:
		return
	if material_density.size() <= material:
		material_density.resize(material + 1)
	material_density[material] = density
	# （这里原本要让密度回调的缓存失效 —— 现在不缓存了，不需要）


func set_material_friction(material: int, v: float) -> void:
	if material < 0:
		return
	if material_friction.size() <= material:
		material_friction.resize(material + 1)
	material_friction[material] = v
	# （这里原本要让摩擦回调的缓存失效 —— 现在不缓存了，不需要）


func set_material_restitution(material: int, v: float) -> void:
	if material < 0:
		return
	if material_restitution.size() <= material:
		material_restitution.resize(material + 1)
	material_restitution[material] = v
	# （这里原本要让恢复系数回调的缓存失效 —— 现在不缓存了，不需要）


func friction_of_material(material: int) -> float:
	if material >= 0 and material < material_friction.size():
		return material_friction[material]
	return 0.5


func restitution_of_material(material: int) -> float:
	if material >= 0 and material < material_restitution.size():
		return material_restitution[material]
	return 0.0


## 同 density_callable()：惰性构造一次并复用。
func friction_callable() -> Callable:
	# ⚠️ 与 density_callable() 同一个坑：**不缓存**。缓存"捕获 self 的 lambda"
	#    到自己的字段就是引用环（实测：清掉这两个缓存后退出泄漏从 12 降到 8）。
	return func(m: int) -> float: return friction_of_material(m)


func restitution_callable() -> Callable:
	# ⚠️ 同 density_callable()：**不缓存**（缓存 = 引用环）。
	return func(m: int) -> float: return restitution_of_material(m)


func density_of_material(material: int) -> float:
	if material >= 0 and material < material_density.size():
		var d := material_density[material]
		if d > 0.0:
			return d
	return 1.0


## 惰性构造一次密度函数并复用它 —— 每帧 add_body 时新建 lambda 是白烧。
func density_callable() -> Callable:
	# ⚠️⚠️ **故意不缓存** —— 缓存它必然成环：把"捕获 self 的 lambda"存进 PWorld
	#    **自己的字段**，就是 PWorld -> lambda -> PWorld，而 RefCounted 不回收环 -> 实例泄漏。
	#    实测（tests/diag_leak_repro.gd，mode=body）：缓存 = 3 个实例泄漏；
	#    缓存"weakref 绕一圈的版本" = **13 个**（更糟，weakref 解决不了，lambda 仍隐式捕获 self）；
	#    不缓存 = 0（见 tests/validation_leak_clean.gd）。
	#    代价只是每次调用新建一个 lambda，而它只在 add_body / rebuild / refresh_mass 里调，
	#    **不是每帧路径**（原来那句"每帧 add_body 时新建 lambda 是白烧"高估了频率）。
	return func(m: int) -> float: return density_of_material(m)


## 已建好的刚体在质量变了之后重算：改密度表、或者在形状上加了像素之后调用。
##
## ⚠️ **破坏之后不需要它**（fracture / detach / fracture_pixels 在破坏里就把密度/摩擦/恢复
##    一起重算了）。它现在的用途是：换了材质表、或绕过引擎直接改像素之后重算一次。
##    以前破坏路径不传 Callable，母体的质量/摩擦是错的，游戏层只能自己补一次 —— 代价是
##    逐像素扫描 + 贪心分解 + 碰撞体重推 + 整张贴图重建**再付一遍**。见 PBody.rebuild 的说明。
func refresh_mass(body: PBody, density_of: Callable = Callable()) -> void:
	body.rebuild(body.shapes, density_of if density_of.is_valid() else density_callable(),
		max_rects_per_shape, Rect2i(), friction_callable(), restitution_callable())


## 保证 body 的每个 shape 都是**单连通**的：多岛屿就地拆成独立刚体。
##
## ⚠️⚠️ 为什么要有它：引擎的破坏路径一直维持着"body 的 shape 单连通"这条不变量
##    （fracture 要么**证明**破坏后仍连通，要么把分量拆成独立刚体），
##    但**游戏层直接造出来的** shape 不受约束 —— 一张有两团不相连像素的贴图
##    就是一个多岛屿 body。
##    以前它只会在"贴着边界擦一下"时被 split 顺手拆开 —— 那是**副作用**：
##    既不是契约，也不可预期（内部擦除永远不会拆它，边缘擦除会）。
##    现在把它变成**建造时的一次性保证**：body 进世界时就拆干净，
##    于是"破坏前连通"这个前提对**所有** body 都成立。
##
## ⚠️ min_pixels 必须用 1：建造时丢像素是**删内容**，不是清理碎片。
##    （破坏路径用 min_fragment_pixels，是因为那些碎片确实是渣。）
##
## ⚠️ 拆出来的岛**继承 is_static**（地形拆出来还是地形），
##    而 fracture 的碎片刻意是动态的（崩下来的料要会掉）—— 两者语义不同，别合并。
## dirty_rect：本次改动的**局部像素范围**（可选的性能提示，见 PBody.rebuild 的 dirty_rects）。
## 破坏路径（detach）知道自己的伤害范围，顺手传进来 -> 渲染器只重建脏块而不是整张。
func ensure_connected(body: PBody, min_pixels: int = 1, dirty_rect: Rect2i = Rect2i()) -> Array:
	var spawned: Array = []
	var kept: Array = []
	var changed := false
	for s in body.shapes:
		var parts: Array = Destruction.split(s, min_pixels, true)
		if parts.size() <= 1:
			kept.append(s)
			continue
		changed = true
		# 最大的那块留在原 body（与 fracture 的选择一致）
		var best := 0
		var best_n := -1
		for i in parts.size():
			var cnt: int = parts[i].pixel_count()
			if cnt > best_n:
				best_n = cnt
				best = i
		kept.append(parts[best])
		for i2 in parts.size():
			if i2 == best:
				continue
			var frag := PBody.new()
			frag.position = body.position
			frag.rotation = body.rotation
			frag.linear_velocity = body.linear_velocity
			frag.angular_velocity = body.angular_velocity
			frag.is_static = body.is_static
			frag.awake = body.awake
			spawned.append(add_body(frag, [parts[i2]], Callable(), true))
	if changed:
		# ⚠️ 摩擦/恢复系数也要传：不传的话 PBody.rebuild 会**保持原值**（它不再写 0），
		#    但**质量**会按"像素数"算错 —— 破坏之后必须重算，且要按材质密度算。
		body.rebuild(kept, density_callable(), max_rects_per_shape, dirty_rect,
			friction_callable(), restitution_callable())
	return spawned


## 方便的"按当前密度建一个动态体"。
##
## ⚠️ connected_known：调用方**已经知道**这些 shape 是单连通的（例如 fracture 的碎片
##    来自 split 的分组，天然单连通）。默认 false = 不确定 -> 走一次连通性标注
##    （768x100 实测 ~14 ms，只在**建造**时付一次，不是每帧）。
##    破坏路径必须传 true，否则每生成一个碎片都要白跑一次标注。
func add_body(body: PBody, shape_list: Array, density_of: Callable = Callable(),
		connected_known: bool = false) -> PBody:
	body.id = _next_id
	_next_id += 1
	body.rebuild(shape_list, density_of if density_of.is_valid() else density_callable(),
		max_rects_per_shape, Rect2i(), friction_callable(), restitution_callable())
	bodies.append(body)
	bodies_rev += 1
	if not connected_known:
		ensure_connected(body)
	return body


func remove_body(body: PBody) -> void:
	if _rp != null and body.rapier_id > 0:
		var cmds := PackedByteArray()
		_rp_u8(cmds, 4)
		_rp_u32(cmds, body.rapier_id)
		_rp_send(cmds, 4)
		_rp_by_id.erase(body.rapier_id)
		body.rapier_id = 0
	# 挂在这个刚体上的关节必须一起清。
	# ⚠️ Rapier 侧其实已经随刚体一起删了（rb_body_remove 会调 purge_joints），
	#    但 GDScript 这边的 PJoint 对象还在 joints 里 —— 留着就是悬空引用：
	#    游戏层再调 j.movement() 会去读一个已经被删掉的刚体的位姿。
	if not joints.is_empty():
		for j in joints_of(body).duplicate():
			_joint_drop_silent(j)
	bodies.erase(body)
	bodies_rev += 1


## ---------- 标签查询 ----------
##
## 让游戏逻辑"按名字找东西"，而不是自己维护一张 id -> 刚体 的表
## （那张表一旦漏掉删除分支就会变成悬空引用）。
## 标签存在 PBody.tags 里：tag -> value（value 可以是任意值，含 null）。

func find_bodies(tag: String) -> Array:
	var out: Array = []
	for b: PBody in bodies:
		if b.tags.has(tag):
			out.append(b)
	return out


func find_body(tag: String) -> PBody:
	for b: PBody in bodies:
		if b.tags.has(tag):
			return b
	return null


## 带某个标签的刚体所拥有的全部形状。
func find_shapes(tag: String) -> Array:
	var out: Array = []
	for b: PBody in find_bodies(tag):
		for s in b.shapes:
			out.append(s)
	return out


## 与矩形范围相交的刚体。
func bodies_in(bounds: Rect2) -> Array:
	var out: Array = []
	for b: PBody in bodies:
		if not b.rects.is_empty() and bounds.intersects(b.aabb):
			out.append(b)
	return out


var _rp: Object = null
var _rp_gravity_pushed := Vector2(INF, INF)
var _rp_cmd_us := 0
## rapier_id -> PBody。接触事件从 Rapier 拿回来的是 id，要映射回刚体。
var _rp_by_id := {}
## 本子步被抓住的刚体（每子步重建）。
var _rp_grabbed := {}
## 还没在 Rapier 里建出来的关节（等两端的刚体先拿到 rapier_id）。
var _rp_joints_pending: Array = []

## 阻尼与引擎 _integrate_forces 里那两行**同值**。Rapier 的公式也是 v *= 1/(1+d*dt)，
## 所以直接设进去就等价，不需要自己再乘一遍。
## ⚠️ 改引擎那两行时必须同步改这里，否则两条路径会静默分叉。
## ⚠️ 这里曾有 `_rp_ccd_pushed`（**世界级** CCD 镜像）—— 已删：镜像改成逐体的
##    PBody._rp_ccd（见 _substep_rapier 里推 op 19 的那段）。世界级镜像的毛病是
##    "改一个刚体的 ccd 要把全世界重推一遍"，而逐体 CCD 的意义恰恰是**大多数刚体不开**。
## 临时探针：打印每次 cmd 的容量/实际写入量。
var rp_debug := false
## Rapier 的长度单位：把它的"米"制默认参数换算到本引擎的像素尺度。
##
## ⚠️ **不设会静默错一大片。** Rapier 的 allowed_linear_error / max_corrective_velocity /
##    prediction_distance / max_linear_velocity / contact_recycle_distance
##    全都是"归一化值 × length_unit"，默认 length_unit=1.0 是按米调的。
##    实测症状：自由落体速度无论重力多大都停在 **397.68 px/s**
##    （Rapier 的 normalized_max_linear_velocity 默认 400）。
##
## ⚠️ **实测：设成 100.0 会让"力/力矩"整条失效。**
##    validation_dynamics 的"持续力矩 60 步"变成 ω 恒为 0（1.0 时 16/16 全过）。
##    length_unit 缩放的是**一整组**参数，牵动的不止速度上限 —— 所以这里先留在
##    1.0（Rapier 默认），保证套件全绿；像素尺度该改哪些参数要做**外科式**处理，
##    不能靠一个 length_unit 一刀切。见 docs/development_log.md。
##
## 已经量到的确定问题：normalized_max_linear_velocity 默认 400，
## 于是自由落体速度无论重力多大都停在 **397.68 px/s**（g=900 和 g=600 给出同一个终速，
## 一眼看去很像阻尼，其实不是 —— 阻尼的终速是 g/d，会随重力变）。
var rp_length_unit := 1.0
var _rp_length_unit_pushed := 0.0

## Rapier 的最大线速度（**归一化值**，实际上限 = 它 × length_unit）。
##
## ⚠️ Rapier 默认 400.0，是按"米"调的 —— 在像素世界里表现为
##    "速度无论重力多大都停在 397.68 px/s"（g=900 和 g=600 给出同一个终速，
##    看起来像阻尼，但阻尼的终速是 g/d，会随重力变）。
##
## 为什么不干脆设 length_unit = 100：那会同时缩放 allowed_linear_error /
## max_corrective_velocity / prediction_distance / contact_recycle_distance，
## 实测会让 validation_dynamics 的"持续力矩 60 步"变成 ω 恒为 0。
## 像素尺度要**逐参数**处理。
## 40000 = 400 × 100，与 length_unit=100 时的等效上限一致。
var rp_max_linear_velocity := 40000.0
var _rp_max_linvel_pushed := 0.0

## 三个"像素尺度"参数（**归一化值**，实际值 = 它 × length_unit）。
##
## ⚠️ **prediction_distance 必须留在 Rapier 默认的 0.02 —— 它是幽灵碰撞的开关。**
##
##    实测（tests/diag_ghost_collision.gd，Rapier #669 判据）：
##      pd = 0.02  A 一整块 OK | B 同一 body 内部边 OK | C 60 个独立静态体 OK
##      pd = 1.0   A OK        | B OK                | C **第 8 步开始打转**
##      pd = 2.0   A OK        | B **第 295 步打转**  | C **第 8 步开始打转**
##
##    这解释了整件事：Rapier 修好幽灵碰撞，**主要不是因为有伪法向，
##    而是因为它默认不用推测接触边际**。把 pd 调大 = 把本引擎原来的
##    max_speculative_margin(1.5 px) 又装了回去 —— 坑 39 测到的那个
##    "滑过接缝时出现水平法向的假接触" 会原样回来。
##
##    C（60 个独立静态体）尤其说明问题：那些侧面是**真面**，伪法向救不了，
##    只有"不产生推测接触"才救得了。
##
## ⚠️ 那穿模怎么办？**靠自适应子步**（见 step/_compute_substeps），
##    不是靠推测接触。子步把每步位移压到最薄障碍厚度以下，是几何上就成立的保证。
##    实测：pd=0.02 时 4 px 薄墙对 200/600/1200/2000/3000 px/s 全部挡住。
##    · max_corrective_velocity 默认 3.0 → 3 px/s，穿透挤出慢得离谱
##      （卡进墙里要好几秒才挤出来）。
##    · allowed_linear_error 默认 0.005 → 0.005 px，紧到几乎没有容差。
##
## 取值按引擎原有的像素尺度换算（×100，与 length_unit=100 等效）：
##    推测接触 2.0 px（略大于原来的 1.5，留一点余量）
##    挤出速度 300 px/s
##    允许误差 0.5 px
## **软 CCD 预测距离**（逐刚体，Rapier 默认 **0.0 —— 等于半关**）。
##
## 这是推测 CCD：把碰撞体按这个距离外扩去做连续检测。它就是本引擎原本
## max_speculative_margin(1.5 px) 的对应物。
##
## ⚠️⚠️ **它才是「逐体 CCD 到底有没有在工作」的那个开关**，比 enable_ccd 重要得多。
##    enable_ccd 只决定「要不要连动态目标一起扫」（bullet 旗）；而**自动层**
##    （快动态体 vs **固定**碰撞体）由 rp_ccd_substeps 控制、**不看** enable_ccd。
##    但两层都吃这个提前量：提前量是 0 时，逐体 CCD 只能「正好撞上」才发现，
##    对一步跨几百像素的快物体等于不起作用。
##
## 实测（4 像素薄墙 + 12x12 块，20000 px/s 冲过去）：
##    rp_soft_ccd_prediction = 0.0 -> 靠全局子步：峰值 167 子步，停在 x=188.1
##    rp_soft_ccd_prediction = 1.5 -> 逐体 CCD 单独搞定：峰值 **1** 子步，停在 x=188.0
##    把 rp_ccd_substeps 设成 0（两层全关）时会停在 x=3247（穿过去了）。
##    也就是说：**开了软预测之后，全局子步对「快物体 vs 静态世界」是纯浪费**。
##
## ⚠️ 对**动态-动态**高速相撞它仍然挡不住（Rapier 官方：two CCD-enabled objects
##    might still tunnel，因为两边都在动）。实测 20000 px/s 撞一块会被推动的墙：
##    两个都开 CCD 也穿。那是引擎层面没有便宜解的那一类（Box2D 的建议是自己
##    ray / shape cast），本引擎不做。
var rp_soft_ccd_prediction := 0.0

## CCD 子步上限（世界级，Rapier 默认 **1**）。
## ⚠️ 它同时是**全局 CCD 开关**：0 = 整个世界关掉 CCD（含"快动态体 vs 固定碰撞体"
##    的自动 CCD）。默认 1 太小 —— 大步长下一次子步撑不住。
var rp_ccd_substeps := 1
## ⚠️ 初值必须是 **-1**，不能是 0：这是"值变了才推"的镜像，而 `rp_ccd_substeps = 0`
##    是**合法且有意义的设置**（= 整个世界关掉 CCD）。镜像初值取 0 的话，
##    "在第一步之前设成 0"会被守卫吃掉 —— 用户以为关了，Rapier 那边还是默认 1，
##    而且**不报任何错**（我调这个旋钮做对照实验时正是这么被骗了一次）。
var _rp_ccd_substeps_pushed := -1

var rp_prediction_distance := 0.02
var rp_max_corrective_velocity := 300.0
var rp_allowed_linear_error := 0.5
var _rp_pixel_params_pushed := false

var rp_linear_damping := 0.35
var rp_angular_damping := 0.6

## ---- 关节求解精度（R3）----
##
## ⚠️ 三个都是"**显式设过才推**"：0 / -1 = 不推，保持 Rapier 默认 —— 所以没调过的场景
##    （含 8 条逐位基准）行为**逐位不变**。
##
## 调它们的理由：默认的迭代次数不多，而"长链 / 大质量比 / 一堆焊接堆在一起"的场景
## 需要更多迭代才能把约束误差压下去（用 PJoint.anchor_error() 量）。
## 代价是每步的求解开销按迭代次数线性涨。

## 求解迭代次数（0 = 不推）。
##
## ⚠️⚠️ 它**不是关节专属**旋钮：Rapier 0.36 的 num_solver_iterations 是**整个求解**
##    （含接触与积分）的迭代次数 —— 实测连"没有任何关节"的自由落体结果都会变
##    （tests/validation_joint_solver.gd 里那条断言就是钉这个事实的）。
##    所以调它等于调**全局精度**：更准，但每步开销按迭代次数涨，而且会改变所有场景的
##    数值结果（包括你已经调好的那些手感）。
var rp_joint_solver_iterations := 0
## 关节 warmstart 开关（-1 = 不推；0 = 关；1 = 开）。
##
## ⚠️ warmstart = 用上一子步的冲量当这一子步的初值。关掉它会让**迭代收敛变慢**
##    （同样的迭代次数下误差更大），但能排除"warmstart 把错误的历史冲量带进新接触"
##    这类问题 —— 排查"抖动是不是求解器引起的"时，它是第一个该试的开关。
var rp_warmstart_joints := -1
## warmstart 系数（< 0 = 不推）。
var rp_warmstart_coefficient := -1.0
var _rp_joint_solver_pushed := false

# 命令流的写入辅助（PackedByteArray 必须自己 resize，encode_* 不会自动扩容）
static func _rp_u8(b: PackedByteArray, v: int) -> void:
	b.resize(b.size() + 1)
	b.encode_u8(b.size() - 1, v)

static func _rp_i32(b: PackedByteArray, v: int) -> void:
	var n := b.size()
	b.resize(n + 4)
	b.encode_s32(n, v)

static func _rp_u32(b: PackedByteArray, v: int) -> void:
	var n := b.size()
	b.resize(n + 4)
	b.encode_u32(n, v)

static func _rp_f64(b: PackedByteArray, v: float) -> void:
	var n := b.size()
	b.resize(n + 8)
	b.encode_double(n, v)

static func _rp_f32(b: PackedByteArray, v: float) -> void:
	var n := b.size()
	b.resize(n + 4)
	b.encode_float(n, v)

## Rapier 侧的**质量** —— 判据用（-1 = 拿不到）。
##
## ⚠️ 为什么必须能读到它：碰撞体拟合之后面积 >= 像素面积（幻影），密度得按
##    "质量 / 多边形面积"反算。反算错了**不会报错**，只会让两边质量静默分叉，
##    而所有按 mass 算的力（抓取限力、灰尘判据…）都会跟着错。
func rp_body_mass(b: PBody) -> float:
	if not _rp_ensure() or b.rapier_id <= 0:
		return -1.0
	var cmds := PackedByteArray()
	_rp_u8(cmds, 45)
	_rp_u32(cmds, b.rapier_id)
	var res := _rp_send(cmds, 8)
	if res.size() < 12:
		return -1.0
	return res.decode_double(4)


## Rapier 侧的**角惯量**（-1 = 拿不到）—— 与 rp_body_mass 配套的判据。
func rp_body_inertia(b: PBody) -> float:
	if not _rp_ensure() or b.rapier_id <= 0:
		return -1.0
	var cmds := PackedByteArray()
	_rp_u8(cmds, 46)
	_rp_u32(cmds, b.rapier_id)
	var res := _rp_send(cmds, 8)
	if res.size() < 12:
		return -1.0
	return res.decode_double(4)


## 原生（Rapier）侧的刚体数 —— **诊断用**。
##
## ⚠️ 为什么必须有它：GDScript 侧的 bodies.size() 与 Rapier 侧的刚体数是**两个数**，
##    任何"只删了一边"的路径都会让它们分叉，而分叉的症状是**性能慢慢变差**
##    （僵尸还在被积分），不会有任何报错。cull_outside 就这么漏了很久。
##    判据用 tests/validation_cull_release.gd 钉住：剔 N 个，两边必须同步减 N。
## 返回 -1 表示扩展还没起来（拿不到）。
func rp_body_count() -> int:
	if not _rp_ensure():
		return -1
	var cmds := PackedByteArray()
	_rp_u8(cmds, 13)
	var res := _rp_send(cmds, 4)
	if res.size() < 8:
		return -1
	return res.decode_s32(4)


## 读回一个刚体**真的在用**的碰撞体形状（凸多边形；走矩形那条路时是 4 个角的矩形）。
##
## ⚠️ 这是**问物理要真相**（op 44），不是 GDScript 侧另算一份 —— 那样可视化会和
##    碰撞体悄悄分叉（本仓库为"调试可视化画错"栽过：它比没有可视化更糟）。
## 结果按 rects_rev 缓存：形状没变就不再问（每问一次是一次 _rp_send，约 2.8 us）。
## 用途：调试叠加层 / 门面的 colliders()。编辑器抓手不走这条路（那里不跑物理）。
func fetch_polys(b: PBody) -> Array:
	if b.polys_rev == b.rects_rev:
		return b.polys
	b.polys_rev = b.rects_rev
	b.polys = []
	if not _rp_ensure() or b.rapier_id <= 0:
		return b.polys
	# ⚠️ 第一趟给一个**宽裕**的 cap（4096 字节 ≈ 500 个顶点）：绝大多数刚体一次就够。
	#    别用 cap = 0 去"探大小" —— 那会让原生侧写出 4 字节而 cap 是 0，
	#    触发 "结果段越界" 的假警告（那是命令流错位的指纹，留着会把真问题淹掉）。
	var probe := PackedByteArray()
	_rp_u8(probe, 44)
	_rp_u32(probe, b.rapier_id)
	_rp_i32(probe, 4096)
	var res := _rp_send(probe, 4096)
	if res.size() < 8:
		return b.polys
	var need: int = res.decode_s32(4)
	if need <= 0:
		return b.polys
	if need <= 4096:
		# 一趟就成了：payload 就是块本身（off = 4 是协议头的 written）
		return _read_polys(b, res, 4)
	# 太大了：按 need 精确重开一次（payload = 块本身）
	var cmds := PackedByteArray()
	_rp_u8(cmds, 44)
	_rp_u32(cmds, b.rapier_id)
	_rp_i32(cmds, need)
	var res2 := _rp_send(cmds, need)
	if res2.size() < 4 + need:
		return b.polys
	return _read_polys(b, res2, 4)


## 把 op 44 的结果段解析成多边形（off 是 payload 起点）。
func _read_polys(b: PBody, res: PackedByteArray, start: int) -> Array:
	var off := start
	var np: int = res.decode_s32(off)
	off += 4
	for i in np:
		var cnt: int = res.decode_s32(off)
		off += 4
		if cnt < 3:
			off += cnt * 8
			continue
		var poly := PackedVector2Array()
		poly.resize(cnt)
		for k in cnt:
			poly[k] = Vector2(res.decode_float(off), res.decode_float(off + 4))
			off += 8
		b.polys.append(poly)
	return b.polys


func _rp_send(cmds: PackedByteArray, out_cap: int) -> PackedByteArray:
	var inp := PackedByteArray()
	_rp_i32(inp, out_cap)
	_rp_i32(inp, cmds.size())
	inp.append_array(cmds)
	var tmpl := PackedByteArray()
	tmpl.resize(4 + out_cap)
	var res: PackedByteArray = _rp.cmd(inp, tmpl)
	if rp_debug:
		print("    [rp] out_cap=%d cmds=%d res.size=%d written=%d" % [
			out_cap, cmds.size(), res.size(), res.decode_s32(0) if res.size() >= 4 else -1])
	return res

## 把还没有 Rapier 身份的刚体建出来，并把分配到的 id 记回 PBody。
func _rp_create_missing() -> void:
	var cmds := PackedByteArray()
	var n := 0
	for b: PBody in bodies:
		if b.rapier_id != 0:
			continue
		_rp_u8(cmds, 3)
		_rp_i32(cmds, 1 if b.is_static else 0)
		_rp_f64(cmds, b.position.x)
		_rp_f64(cmds, b.position.y)
		_rp_f64(cmds, b.rotation)
		n += 1
	if n == 0:
		return
	var res := _rp_send(cmds, n * 4)
	var off := 4
	# ⚠️ 刚体属性必须**第二趟**设：id 是 Rapier 分配的，第一趟发命令时还不知道。
	#    阻尼少了它，Rapier 用默认 0（引擎是 0.35/0.6）—— 力矩积分会整条错掉。
	var props := PackedByteArray()
	var m := 0
	for b: PBody in bodies:
		if b.rapier_id != 0:
			continue
		b.rapier_id = res.decode_s32(off)
		_rp_by_id[b.rapier_id] = b
		off += 4
		_rp_u8(props, 16)
		_rp_u32(props, b.rapier_id)
		_rp_f64(props, rp_linear_damping)
		_rp_f64(props, rp_angular_damping)
		_rp_u8(props, 17)
		_rp_u32(props, b.rapier_id)
		_rp_f64(props, b.gravity_scale)
		b._rp_gravity_scale = b.gravity_scale
		# ⚠️ 必须**显式推一次位姿与速度**。第一版只把镜像设成当前值，于是
		#    "建体之前就设好的" angular_velocity / position 被当成"已推过"，
		#    永远送不到 Rapier —— 表现为 test_physics 的 "body did rotate" 恒为 0。
		_rp_u8(props, 6)
		_rp_u32(props, b.rapier_id)
		_rp_f64(props, b.position.x)
		_rp_f64(props, b.position.y)
		_rp_f64(props, b.rotation)
		_rp_u8(props, 7)
		_rp_u32(props, b.rapier_id)
		_rp_f64(props, b.linear_velocity.x)
		_rp_f64(props, b.linear_velocity.y)
		_rp_f64(props, b.angular_velocity)
		m += 1
		# ⚠️ 必须和 _substep_rapier 里那段**同一套判据**，否则新建的刚体先被当成 bullet，
		#    下一子步又被改回来 —— 而镜像 b._rp_ccd 记的是「建的时候推了什么」，
		#    两边不一致会让「变了才推」的判断错位。
		_rp_u8(props, 19)
		_rp_u32(props, b.rapier_id)
		var init_ccd: int = 1 if (ccd_enabled and (not ccd_per_body or b.ccd)) else 0
		_rp_i32(props, init_ccd)
		_rp_f64(props, rp_soft_ccd_prediction)
		b._rp_ccd = init_ccd
		# 新刚体一律先推一次矩形与全部状态
		b._rp_rects_rev = -1
		# 层/掩码也先打回"未推送"：新刚体在 Rapier 侧拿的是默认分组（全 1），
		# 而我们的默认是 layer=1 / mask=全 1 —— 两者对"谁能碰谁"等价，
		# 但显式推一次才能保证用户设过的值真的过去了。
		b._rp_layer = -1
		b._rp_mask = -1
		b._rp_x = b.position.x
		b._rp_y = b.position.y
		b._rp_rot = b.rotation
		b._rp_static = b.is_static
		b._rp_vx = b.linear_velocity.x
		b._rp_vy = b.linear_velocity.y
		b._rp_w = b.angular_velocity
	if m > 0:
		_rp_send(props, 4)


## Rapier 版子步：推 -> step -> 读回。
##
## 休眠完全交给 Rapier（它的岛管理器），所以这里**不**调 _update_sleep / _wake_pass。
## 接触事件走单独的通道（见 _collect_contacts），这里不碰。
## 确保 Rapier 扩展已实例化（懒加载）。
##
## ⚠️ 任何**可能在第一次 step 之前**发命令的路径都必须先调它。
##    抓取就踩过这个坑：探针在 step 之前 grab()，报错是
##    "Nonexistent function 'cmd' in base 'Nil'" —— 完全指不到"还没实例化"这个真因。
func _rp_ensure() -> bool:
	if _rp != null:
		return true
	_rp = ClassDB.instantiate("RapierPhys")
	# ⚠️⚠️ 绕开 Godot 的一个已知问题（issue #111075，标签 bug：
	#    "Issues related to initializing new instance in GDExtension/Godot modules"）。
	#    维护者原话：RefCounted 在实例化时应当只带 1 份引用并把它交给调用方，
	#    "This fix is highly complex and will likely take a while"。
	#    实测（tests/diag_unreference.gd）：RapierPhys 创建后 get_reference_count() == 2
	#    （普通 RefCounted 是 1），那份多出来的引用没人还 -> 退出时报 1 个实例泄漏。
	#    unreference() 是引擎暴露的方法：计数 2 时调一次回到 1，**不会**误释放。
	#    ⚠️ 必须判 > 1 再调 —— 计数 1 时调会真的把对象释放掉。
	if _rp.get_reference_count() > 1:
		_rp.unreference()
	if _rp == null:
		# ⚠️ 这里必须**吵闹地**失败。扩展加载失败时 ClassDB.instantiate 返回 null，
		#    而如果放任下去，报错会是 "Nonexistent function 'cmd' in base 'Nil'" ——
		#    那句话完全指不到"扩展没加载"这个真因（实测排查了很久）。
		push_error("RapierPhys 扩展不可用：gdext/fastphys.gdextension 没加载成功。" +
			"物理无法运行。先确认 fastphys.dll 与 rapier_bridge.dll **两个都**存在且都是最新的" +
			"（只重建一个会导致 load_rapier 失败），再跑 python tools/build_addon.py --verify。")
		assert(false, "RapierPhys 扩展不可用")
		return false
	return true


func _substep_rapier(dt: float) -> void:
	if not _rp_ensure():
		return
	_rp_create_missing()
	_rp_create_joints()
	# ---- 抓取约束：必须在**推送之前**解 ----
	#
	# 这样它改出来的速度能在**同一子步**里被 Rapier 的接触求解看到（否则会慢一帧）。
	# 引擎那条路径是在求解迭代里解 10 次（约束更硬）；这里是每子步一次 —— 手感略软，
	# 但限力 max_accel * mass * dt 仍然精确成立，这是"重物要滞后"的来源。
	# ---- 抓取：必须在**推送之前**解 ----
	#
	# 这样它改出来的速度能在**同一子步**里被 Rapier 的接触求解看到（否则会慢一帧）。
	# 力控：限力 max_accel * mass * dt 精确成立，这是"重物要滞后"的来源。
	_rp_grabbed.clear()
	for b: PBody in bodies:
		b.grab_force = Vector2.ZERO
		b.grab_torque = 0.0
	for g in grabs:
		# 每子步重取焊接组件：关节可能在上一子步断了（断裂阈值）或新建了。
		g.bodies = weld_group(g.body) if not joints.is_empty() else [g.body]
		g.apply(dt, gravity)
		# ⚠️ 记的是**整个组件**：组件里除被抓那个以外的刚体也在被驱动，
		#    漏掉它们的话 enforce_body_budget 可能把正在拖的刚体当成"闲置碎块"淘汰掉。
		for p in g.bodies:
			_rp_grabbed[p] = true
	var t0 := Time.get_ticks_usec()
	var cmds := PackedByteArray()
	# 长度单位 / 最大线速度：只在第一次（或改了之后）推一次
	if rp_length_unit != _rp_length_unit_pushed:
		_rp_u8(cmds, 20)
		_rp_f64(cmds, rp_length_unit)
		_rp_length_unit_pushed = rp_length_unit
	if rp_max_linear_velocity != _rp_max_linvel_pushed:
		_rp_u8(cmds, 21)
		_rp_f64(cmds, rp_max_linear_velocity)
		_rp_max_linvel_pushed = rp_max_linear_velocity
	if rp_ccd_substeps != _rp_ccd_substeps_pushed:
		_rp_u8(cmds, 23)
		_rp_u32(cmds, rp_ccd_substeps)
		_rp_ccd_substeps_pushed = rp_ccd_substeps
	if not _rp_pixel_params_pushed:
		_rp_u8(cmds, 22)
		_rp_f64(cmds, rp_prediction_distance)
		_rp_f64(cmds, rp_max_corrective_velocity)
		_rp_f64(cmds, rp_allowed_linear_error)
		_rp_pixel_params_pushed = true
	# 重力变了才推
	if gravity != _rp_gravity_pushed:
		_rp_u8(cmds, 1)
		_rp_f64(cmds, gravity.x)
		_rp_f64(cmds, gravity.y)
		_rp_gravity_pushed = gravity
	# 关节求解参数（R3）：**只有显式设过才推** —— 没设过的场景逐位不变。
	if rp_joint_solver_iterations > 0 or rp_warmstart_joints >= 0 or rp_warmstart_coefficient >= 0.0:
		_rp_u8(cmds, 41)
		_rp_i32(cmds, rp_joint_solver_iterations)
		_rp_i32(cmds, rp_warmstart_joints)
		_rp_f64(cmds, rp_warmstart_coefficient)
		_rp_joint_solver_pushed = true
	# 关节的限位/马达/软度：变了才推
	_rp_push_joints(cmds)
	var n_state := 0
	var n_sleep := 0
	for b: PBody in bodies:
		if b.rapier_id <= 0:
			continue
		if b.additional_solver_iterations != b._rp_solver_iterations:
			_rp_u8(cmds, 42)
			_rp_u32(cmds, b.rapier_id)
			_rp_u32(cmds, maxi(0, b.additional_solver_iterations))
			b._rp_solver_iterations = b.additional_solver_iterations
		# 求解前的速度 —— 接触事件的 approach 要用它（见 PBody.pre_vx 的说明）
		b.pre_vx = b.linear_velocity.x
		b.pre_vy = b.linear_velocity.y
		b.pre_w = b.angular_velocity
		# ⚠️ Rapier 侧的"静态" = is_static **或 frozen**：冻结就是把刚体暂时按静态推过去
		#    （不积分、不参与静态-静态对，但碰撞体还在）。见 PBody.frozen 的说明。
		var native_static: bool = b.is_static or b.frozen
		if native_static != b._rp_static:
			_rp_u8(cmds, 15)
			_rp_u32(cmds, b.rapier_id)
			_rp_i32(cmds, 1 if native_static else 0)
			b._rp_static = native_static
			# ⚠️⚠️ 刚体类型一变，Rapier 会**重算质量属性**（静态 = 无限质量）：解冻时必须把
			#    密度/摩擦/恢复重推一遍，否则它们停在静态那一套上。
			#    症状与破坏路径那个坑一模一样：**解冻后的石头变轻变滑**，而且不报任何错。
			b._rp_density = -1.0
			b._rp_friction = -1.0
			b._rp_restitution = -1.0
		# ⚠️ 解冻后要**显式叫醒** Rapier 那边（op 10）：它当了若干步的静态刚体，
		#    岛管理器不会自己把它放回模拟里 —— 只把类型改回动态不够。
		if b._rp_need_wake:
			_rp_u8(cmds, 10)
			_rp_u32(cmds, b.rapier_id)
			b._rp_need_wake = false
		# 逐体 CCD（op 19）。
		# ⚠️⚠️ 老行为是 `1 if ccd_enabled else 0` —— **全世界每个刚体都变成 Rapier 的 bullet**，
		#    而 bullet 会连动态/运动学目标一起扫（见 ccd_per_body 的说明）。
		#    ccd_per_body 打开后：ccd_enabled 只当总闸，具体谁开由下面两条决定。
		# ⚠️ 镜像改成**逐体**的 b._rp_ccd，世界级的 _rp_ccd_pushed 已删（它逼着"改一个刚体
		#    就要重推全世界"）。
		# ⚠️ 自动打标**必须**排除灰尘：PBody.needs_ccd 的判据对小碎片是反向的（越小越容易
		#    满足），拿它无脑开 CCD 等于把每个碎片都升成 bullet —— 正是要避免的那件事。
		#    （拆成两条 if 而不是一个长布尔式，是为了让两条判据各自能单独读。）
		var auto_ccd: bool = ccd_auto and b.needs_ccd(dt)
		if auto_ccd and ccd_min_driver_thickness > 0.0 and b.thinnest_extent() < ccd_min_driver_thickness:
			auto_ccd = false
		var want_ccd: int = 1 if (ccd_enabled and (not ccd_per_body or b.ccd or auto_ccd)) else 0
		if b._rp_ccd != want_ccd:
			_rp_u8(cmds, 19)
			_rp_u32(cmds, b.rapier_id)
			_rp_i32(cmds, want_ccd)
			_rp_f64(cmds, rp_soft_ccd_prediction)
			b._rp_ccd = want_ccd
		if b._rp_gravity_scale != b.gravity_scale:
			_rp_u8(cmds, 17)
			_rp_u32(cmds, b.rapier_id)
			_rp_f64(cmds, b.gravity_scale)
			b._rp_gravity_scale = b.gravity_scale
		if b._rp_rects_rev != b.rects_rev:
			# ⚠️ 两条路**互斥**（都会先清空旧碰撞体），二选一由 poly_colliders / poly_max_rects 决定：
			#   · op 43：矩形 -> **凸多边形**（原生侧拟合，Noita 式）
			#   · op 5 ：矩形 -> Rapier cuboid（精确，逐像素不差）
			var as_polys: bool = poly_colliders and b.rects.size() <= poly_max_rects
			if as_polys:
				_rp_u8(cmds, 43)
				_rp_u32(cmds, b.rapier_id)
				_rp_i32(cmds, b.rects.size())
			else:
				_rp_u8(cmds, 5)
				_rp_u32(cmds, b.rapier_id)
				_rp_i32(cmds, b.rects.size())
			# ⚠️ 整段**先 resize 一次**，再逐字段 encode_float —— 不要每个字段都走 _rp_f32。
			#    _rp_f32 每次都 `resize(size+4)` + `encode_float`：1200 个矩形 = 4800 次
			#    resize（每次都动整个缓冲区）+ 4800 次编码。实测（1200 / 4000 个矩形）：
			#    0.215 / 0.725 ms -> **0.107 / 0.365 ms（2x）**，而且**逐字节完全一致**
			#    （同样的 encode_float、同样的偏移、同样的值 —— 探针里比过 A=B:true）。
			#    位置/速度那些只有几个字段的推送不值得改，就这条循环是 N 个矩形。
			var n0 := cmds.size()
			cmds.resize(n0 + b.rects.size() * 16)
			var off := n0
			for r: Rect2 in b.rects:
				cmds.encode_float(off, r.position.x)
				cmds.encode_float(off + 4, r.position.y)
				cmds.encode_float(off + 8, r.size.x)
				cmds.encode_float(off + 12, r.size.y)
				off += 16
			_rp_f64(cmds, global_friction)
			if as_polys:
				_rp_f64(cmds, b.mass)
				_rp_f32(cmds, poly_dev_tol)
			b._rp_rects_rev = b.rects_rev
			b.polys_rev = -1          # 形状变了：读回的碰撞体形状作废
			# ⚠️ 重建碰撞体 = Rapier 侧的分组回到**默认全 1**（新碰撞体不会继承旧分组）。
			#    把镜像打回"未推送"，让下面那段重新推一次 —— 否则"擦掉一块地形"
			#    就会让那个刚体的层/掩码静默失效（子弹又开始打中它）。
			b._rp_layer = -1
			b._rp_mask = -1
			if as_polys:
				# ⚠️⚠️ 多边形这条路**不推密度**：op 43 已经按 mass/多边形面积 反算好了。
				#    多边形面积 >= 像素面积（幻影），推"材质密度"会让 Rapier 的质量比
				#    b.mass 大出幻影那一份（薄形状能差 2 倍）。把镜像写成"与 b.density
				#    一致"，下面那段 op 34 就不会再去覆盖它。
				b._rp_density = b.density
			else:
				# ⚠️ 矩形那条路：新碰撞体的密度回到 Rapier 默认的 1.0，必须重推。
				b._rp_density = -1.0
			# ⚠️ 同理：新碰撞体的摩擦/恢复系数也回到 Rapier 默认（0.5 / 0.0），必须重推。
			b._rp_friction = -1.0
			b._rp_restitution = -1.0
		if b._rp_layer != b.collision_layer or b._rp_mask != b.collision_mask:
			_rp_u8(cmds, 32)
			_rp_u32(cmds, b.rapier_id)
			_rp_u32(cmds, b.collision_layer)
			_rp_u32(cmds, b.collision_mask)
			b._rp_layer = b.collision_layer
			b._rp_mask = b.collision_mask
		# 材质密度 -> Rapier 质量。不推的话两边质量差一个密度倍率，
		# 抓取这类"按 mass 算力"的东西会过冲成振荡（见 rb_body_set_density 的墓碑注释）。
		if b._rp_density != b.density:
			_rp_u8(cmds, 34)
			_rp_u32(cmds, b.rapier_id)
			_rp_f64(cmds, b.density)
			b._rp_density = b.density
		# 摩擦 / 恢复系数 -> Rapier 碰撞体。
		# ⚠️ 和密度不同：它们**不参与质量属性**，所以不需要 recompute（别照抄上面那段）。
		if b._rp_friction != b.friction:
			_rp_u8(cmds, 38)
			_rp_u32(cmds, b.rapier_id)
			_rp_f64(cmds, b.friction)
			b._rp_friction = b.friction
		if b._rp_restitution != b.restitution:
			_rp_u8(cmds, 39)
			_rp_u32(cmds, b.rapier_id)
			_rp_f64(cmds, b.restitution)
			b._rp_restitution = b.restitution
		if b.position.x != b._rp_x or b.position.y != b._rp_y or b.rotation != b._rp_rot:
			_rp_u8(cmds, 6)
			_rp_u32(cmds, b.rapier_id)
			_rp_f64(cmds, b.position.x)
			_rp_f64(cmds, b.position.y)
			_rp_f64(cmds, b.rotation)
			b._rp_x = b.position.x
			b._rp_y = b.position.y
			b._rp_rot = b.rotation
		if b.linear_velocity.x != b._rp_vx or b.linear_velocity.y != b._rp_vy \
				or b.angular_velocity != b._rp_w:
			_rp_u8(cmds, 7)
			_rp_u32(cmds, b.rapier_id)
			_rp_f64(cmds, b.linear_velocity.x)
			_rp_f64(cmds, b.linear_velocity.y)
			_rp_f64(cmds, b.angular_velocity)
			b._rp_vx = b.linear_velocity.x
			b._rp_vy = b.linear_velocity.y
			b._rp_w = b.angular_velocity
		# 外力/力矩：变了才推，而且是 **reset + add**（等价于 set）。
		# Rapier 的 add_force 跨步累积，直接每步 add 会让力矩按 1+2+…+N 涨 ——
		# 实测 60 步差 33 倍（validation_dynamics 的"持续力矩"就是这么挂的）。
		# 外力 = 引擎的**持久累加器** + 抓取的**每子步力**。
		# 被抓住的刚体每子步强制推一次（不只是变化时）：Rapier 的
		# add_force(f, wake_up=true) 顺带把它唤醒 —— 这正是"被抓着不入睡"
		# 需要的，不用另写一套保醒逻辑。
		var fx := b.accum_force.x + b.grab_force.x + b.control_force.x
		var fy := b.accum_force.y + b.grab_force.y + b.control_force.y
		var tq := b.accum_torque + b.grab_torque + b.control_torque
		if _rp_grabbed.has(b) or fx != b._rp_fx or fy != b._rp_fy or tq != b._rp_tq:
			_rp_u8(cmds, 18)
			_rp_u32(cmds, b.rapier_id)
			if fx != 0.0 or fy != 0.0 or tq != 0.0:
				_rp_u8(cmds, 14)
				_rp_u32(cmds, b.rapier_id)
				_rp_f64(cmds, fx)
				_rp_f64(cmds, fy)
				_rp_f64(cmds, tq)
			b._rp_fx = fx
			b._rp_fy = fy
			b._rp_tq = tq
	# ---- 走一步 ----
	_rp_u8(cmds, 2)
	_rp_f64(cmds, dt)
	# ---- 读回：先状态，后睡眠（顺序决定了结果段的布局）----
	for b2: PBody in bodies:
		if b2.rapier_id <= 0 or b2.is_static:
			continue
		_rp_u8(cmds, 8)
		_rp_u32(cmds, b2.rapier_id)
		n_state += 1
	for b3: PBody in bodies:
		if b3.rapier_id <= 0 or b3.is_static:
			continue
		_rp_u8(cmds, 9)
		_rp_u32(cmds, b3.rapier_id)
		n_sleep += 1
	# ---- 断裂判定要读的关节冲量 ----
	# 只对**设了阈值**的关节读：每个关节一条命令 + 16 字节结果。
	# 绝大多数关节不需要断裂，别为它们每子步付代价。
	var breakables: Array = []
	for j in joints:
		if j.rapier_id > 0 and is_finite(j.break_impulse):
			_rp_u8(cmds, 30)
			_rp_u32(cmds, j.rapier_id)
			breakables.append(j)
	var res := _rp_send(cmds, n_state * 48 + n_sleep * 4 + breakables.size() * 16)
	var off := 4
	for b4: PBody in bodies:
		if b4.rapier_id <= 0 or b4.is_static:
			continue
		if b4.frozen:
			# ⚠️⚠️ 冻着的刚体：Rapier 那边它是**静态**，读回来的是**零速度** —— 直接写进去就把
			#    "留着解冻用的速度"抹掉了。症状：解冻后物体停在原地不动，速度凭空消失，
			#    而且不报任何错（我第一版就是这么写的，闸门里"解冻后速度原样交回"当场抓到
			#    283.02 -> 0.00）。位置/朝向照收（它本来就不动），**速度跳过**。
			#    ⚠️ off 必须照常前进：结果段是**按请求顺序紧凑排列**的，跳过一个就整体错位
			#    （那会把后面所有刚体的位置都读错，比速度丢失难查得多）。
			b4.position = Vector2(res.decode_double(off), res.decode_double(off + 8))
			b4.rotation = res.decode_double(off + 16)
			b4._rp_x = b4.position.x
			b4._rp_y = b4.position.y
			b4._rp_rot = b4.rotation
			off += 48
			continue
		b4.position = Vector2(res.decode_double(off), res.decode_double(off + 8))
		b4.rotation = res.decode_double(off + 16)
		b4.linear_velocity = Vector2(res.decode_double(off + 24), res.decode_double(off + 32))
		b4.angular_velocity = res.decode_double(off + 40)
		var raw_w := b4.angular_velocity
		# 角速度上限：Rapier **没有**这个旋钮（只有线速度的），所以在这里钳。
		# ⚠️ 镜像 _rp_w 必须留**钳制前**的值（下面那行），理由与 terminal_speed 逐字相同：
		#    留成钳制后的值会让下一子步的"变了才推"认为无需推送，于是 Rapier 继续按
		#    未钳制的角速度积分 —— 钳制等于没做。
		if max_angular_velocity > 0.0 and absf(raw_w) > max_angular_velocity:
			b4.angular_velocity = clampf(raw_w, -max_angular_velocity, max_angular_velocity)
		# ⚠️ raw_vx/raw_vy 必须在**任何**钳制之前抓：镜像的语义是"Rapier 现在是多少"。
		#    （原来只有 raw_vy 是这么抓的；加了表面速度钳之后 x 分量也会被改，所以它也要。）
		var raw_vx := b4.linear_velocity.x
		var raw_vy := b4.linear_velocity.y
		# 终端速度：Rapier 没有这个概念，所以在这里钳制。
		#
		# ⚠️ 关键是**镜像要留在 Rapier 的实际值（钳制前）**，而不是钳制后的值 ——
		#    镜像的语义就是"Rapier 现在是多少"。留成钳制后的值会让下一子步的
		#    "变了才推"判断认为无需推送，于是 Rapier 继续按未钳制的速度积分，
		#    钳制等于没做。留成钳制前的值，下一子步自然会把钳制值推过去。
		#    （代价是一个子步的滞后，对"终端速度"这种上限语义无所谓。）
		#
		# 为什么必须落实：terminal_speed 是 pixel_physics / pixel_world /
		# validation_fall_feel 都在用的公开旋钮，静默失效比没有它更糟。
		if terminal_speed > 0.0 and raw_vy > terminal_speed:
			b4.linear_velocity.y = terminal_speed
		# 【新】表面速度上限（max_surface_speed，默认 0 = 关）。
		# ⚠️ 与上面两道**并存**，取更紧的那个 —— 见 max_surface_speed 的说明。
		# ⚠️ 钳完**不能**把镜像写成钳制后的值（上面 terminal_speed 那段墓碑逐字同理）。
		if max_surface_speed > 0.0:
			var r_surf := b4.bounding_radius()
			if r_surf > 1e-6 and absf(b4.angular_velocity) * r_surf > max_surface_speed:
				var w_cap := max_surface_speed / r_surf
				b4.angular_velocity = clampf(b4.angular_velocity, -w_cap, w_cap)
			var v_len := b4.linear_velocity.length()
			if v_len > max_surface_speed:
				b4.linear_velocity = b4.linear_velocity * (max_surface_speed / v_len)
		b4._rp_x = b4.position.x
		b4._rp_y = b4.position.y
		b4._rp_rot = b4.rotation
		b4._rp_vx = raw_vx
		b4._rp_vy = raw_vy
		b4._rp_w = raw_w
		off += 48
	for b5: PBody in bodies:
		if b5.rapier_id <= 0 or b5.is_static:
			continue
		var sleeping := res.decode_s32(off) == 0
		off += 4
		# ⚠️ 冻着的刚体固定记成"不参与积分"：Rapier 对 Fixed 刚体报的睡眠位不是这个意思
		#    （它可能报"没在睡"），照抄会把 freeze() 设的 awake=false 又翻回来。
		b5.awake = false if b5.frozen else sleeping
	# ---- 关节冲量 -> 断裂 ----
	if not breakables.is_empty():
		for j in breakables:
			j.last_linear_impulse = res.decode_double(off)
			j.last_angular_impulse = res.decode_double(off + 8)
			off += 16
			# ⚠️ 判据取**线性**冲量，不取角冲量。
			#    实测：一个挂着 256 质量方块的铰链，约束载荷几乎全在"锁住锚点"的
			#    那两根线性自由度上（实测 400~640），而自由转动的 AngX 那一行是 **0** ——
			#    第一版按角冲量判断裂，于是"永远不断"（阈值 1.0 都不动）。
			#    角冲量只有在马达/限位顶着它时才非零，所以它只作诊断量。
			j.last_impulse = j.last_linear_impulse
		_break_joints_over_threshold(breakables)
	# sleeping_enabled = false 时必须**每子步把物体叫醒**：
	# Rapier 的岛管理器会自己判睡，不叫醒就等于这个开关被静默忽略 ——
	# dump_state 的非休眠场景全是靠它测"纯求解器行为"的。
	if not sleeping_enabled:
		var wake := PackedByteArray()
		var wn := 0
		for b7: PBody in bodies:
			if b7.is_static or b7.rapier_id <= 0:
				continue
			_rp_u8(wake, 10)
			_rp_u32(wake, b7.rapier_id)
			wn += 1
		if wn > 0:
			_rp_send(wake, 4)
	for b6: PBody in bodies:
		if b6.is_static:
			continue
		b6.refresh_com()
		b6.update_aabb()
	# （世界级 _rp_ccd_pushed 已删：CCD 开关是逐体推的，见 _substep_rapier。）
	_rp_cmd_us = Time.get_ticks_usec() - t0
	_collect_contacts_rapier()


## 求解前的速度在接触点处的线速度（含转动贡献）。
func _vel_at_pre(b: PBody, p: Vector2) -> Vector2:
	var r := p - b.com_world()
	return Vector2(b.pre_vx, b.pre_vy) + Vector2(-b.pre_w * r.y, b.pre_w * r.x)


## Rapier 版的接触采集。
##
## 与手写路径的区别：冲量**直接用 Rapier 的**（pair.total_impulse()），
## 不再靠"求解前后的速度差 × 有效质量"去估 —— 那是拿不到真值时的替代品。
## 但 approach 仍然必须用**求解前**的速度算（求解后接触点相对速度已归零）。
## 读取第 idx 个接触对的**全部**接触点及各自的冲量。
##
## ⚠️⚠️ 为什么需要它（旧接口的缺陷）：旧的接触导出只取**第一个流形的第一个点**作位置，
##    却用整对的**总冲量**作冲量 —— 一个点背着整个面的冲量。宽面撞击（面-面接触通常
##    2 个点）如果照着这个点打洞，就会集中成一次尖刺攻击。
##
##    实测（tests/diag_contact_points4.gd：32 宽的方块平放落在静态地面上）：
##      点数 = 2，位置 (50,100) 与 (82,100) —— 正是接触段的**两端**
##      各点冲量 1280.0001 + 1280.0001 = 2560.0002 = 整对总冲量（比值 **1.000**）
##    => 多点导出**天然满足**"一个面的多个入口共同分配这次碰撞的预算"。
##
## ⚠️ 调用方要注意的两条：
##   1. dist < 0 才是**真穿透**；推测接触（dist > 0）虽然也有冲量，但那是在**阻止接近**，
##      不是发生了撞击 —— 伤害判据不能只看冲量，否则擦身而过也会打洞。
##   2. 每个点带 feature id（op 35 没导出，warm start 用的那个）—— 多点伤害需要
##      "跨帧稳定身份"来避免同一特征被重复领取预算，将来要用就一起导出。
##
## ⚠️⚠️ 协议照 _rp_send 抄，别手搓：inp = i32 out_cap + i32 cmds.size() + 命令流；
##    res 的头 4 字节是**实际写入字节数**（不是数据！），数据从**偏移 4** 开始。
##    这两条我都踩过：漏头 -> "未知操作码 247（命令流错位）"；把头当数据读 -> "数量 = 0"。
func contact_points(idx: int) -> Array:
	return _contact_fetch(idx).get("points", [])


## 取第 idx 对接触：cap 是 **double 个数**（= 4 + 点数*9），协议头的 out_cap 是**字节数**。
## 抽出来是因为 `_contact_fetch` 现在会**发两次不同 cap 的请求**（猜值 + 精确值）。
func _fetch_pair(idx: int, cap: int) -> PackedByteArray:
	var cmds := PackedByteArray()
	_rp_u8(cmds, 35)
	_rp_u32(cmds, idx)
	_rp_i32(cmds, cap)
	return _rp_send(cmds, 4 + cap * 8)


## 一次调用取回第 idx 对的**全部**数据（点 + 整对总冲量）。两个公开接口都走它。
##
## ⚠️⚠️ 协议坑（我连踩两次，别再踩）：
##   1. `inp` 必须带 **8 字节头**：`i32 out_cap + i32 cmds.size()`，然后才是命令流
##      —— 漏了会报 "未知操作码 247（命令流错位）"；
##   2. 返回值的**头 4 字节是"实际写入字节数"**（不是数据！），数据从**偏移 4** 开始；
##   3. op 35 的 `cap` 参数单位是 **double 个数**（= 4 + 9n），协议头的 `out_cap` 是
##      **字节数**（= 4 + cap*8）。差 4 字节就会被"写入字节数不足"挡掉、返回空数组。
##   4. **cap 不够时它只写 i32 点数**（绝不写半截数据）—— 所以"猜一个 cap"是安全的：
##      猜对了省一次调用，猜小了照样拿得到点数、按它重发一次精确的。
##   生产者是 `_rp_send`（645 行）—— 动协议前先读它。
func _contact_fetch(idx: int) -> Dictionary:
	# ⚠️⚠️ 这里曾经**固定两次** _rp_send（先问点数、再取数据），每次都有固定的协议开销
	#    （实测 ~3.3 us/次）。而点数在相邻子步之间几乎不变，所以拿上一次的当**猜值**：
	#    猜对 -> **一次**调用；猜小了 -> 退回原来的两步（不多付）。猜错**不会**少读数据
	#    （见上面第 4 条）。实测**一次 _rp_send ≈ 2.8 us**（tests/bench_contact_light.gd 的
	#    1b 段：猜值命中 6.6~7.5 us/对，逼成两步 9.5~10.3 us/对），所以省下的是
	#    "每对每子步 2.8 us" —— 子步多的场景乘子步数（29 子步 x 25 对/子步 = 725 次取回/步
	#    -> ~2 ms/步），而本探针那种 2.5 子步的场景只占 ~7%（淹没在场景 1 的散布里）。
	var guess := 2
	if idx < _contact_point_hint.size() and _contact_point_hint[idx] > 0:
		guess = _contact_point_hint[idx]
	var cap := 4 + guess * 9
	var res := _fetch_pair(idx, cap)
	var np: int = res.decode_s32(4)
	if res.decode_s32(0) < 4 + (4 + np * 9) * 8:
		# cap 不够（这时 op 35 只写了 i32 点数），或者这个下标压根没有接触对
		if np <= 0:
			return {"ok": false}
		cap = 4 + np * 9
		res = _fetch_pair(idx, cap)
		np = res.decode_s32(4)
		if res.decode_s32(0) < 4 + (4 + np * 9) * 8:
			return {"ok": false}
	if idx >= _contact_point_hint.size():
		_contact_point_hint.resize(idx + 1)
	_contact_point_hint[idx] = np
	var out: Array = []
	for i in np:
		# 跳过 res 头(4) + payload 头(i32 n + id_a,id_b,n_points,total 共 4 个 f64 = 36 字节)
		# 每点 9 个 f64 = 72 字节（48 -> 64 加 fid1/fid2，64 -> 72 加切向冲量）
		var o := 40 + i * 72
		out.append({
			"normal": Vector2(res.decode_double(o), res.decode_double(o + 8)),
			"position": Vector2(res.decode_double(o + 16), res.decode_double(o + 24)),
			"dist": res.decode_double(o + 32),
			# ⚠️ impulse 是**法向**分量（Rapier 文档：along the contact normal）。
			#    接触点的冲量其实是"法向 + 切向"两个分量之和，只有摩擦为零时才沿法向。
			"impulse": res.decode_double(o + 40),
			# **切向（摩擦）**分量（2D 的切空间是 1 维，所以是个标量）。
			# 世界向量 = perp(normal) * 它，即 (-n.y, n.x) * tangent_impulse。
			# 符号遵循 Rapier 的约定；库仑约束：|切向| <= mu * |法向|。
			"tangent_impulse": res.decode_double(o + 48),
			# 接触特征 id：(fid1, fid2) 是**面/顶点级**的特征，warm start 靠它。
			# ⚠️⚠️ 但它**不含"第几个矩形"** —— 实测（tests/diag_fid_rect.gd）同一个方块砸在
			#    同一个两矩形刚体的左半与右半，fid **完全相同**。
			#    所以跨帧去重**不能只用它**：方块从矩形 A 滑到矩形 B 时 fid 可能不变，
			#    只用它会把两处当成同一个接触。**必须和位置（或矩形索引）组合**。
			"fid1": int(res.decode_double(o + 56)),
			"fid2": int(res.decode_double(o + 64)),
		})
	# ⚠️ total_impulse 在 payload 的最后一个 f64：res 头(4) + i32 n(4) + id_a,id_b,n_points(24)
	return {
		"ok": true,
		"points": out,
		"total_impulse": res.decode_double(32),
		"id_a": int(res.decode_double(8)),
		"id_b": int(res.decode_double(16)),
	}


## 第 idx 个接触对的**配对级**信息：全部接触点 + 整对总冲量 + 两个刚体 id。
##
## ⚠️⚠️ 这里**故意不给面积**（用户的决定）。原因记在这里，免得以后有人再加回来：
##   · "带宽面积"（宽度 x 平均深度）在**角接触上是结构性错的** —— 窄相只给 1 个点，
##     宽度就是 0，面积算成 0，而真实重叠是一个非零的小三角形。**静默的错值最坏**。
##   · 真正想要的"相互进入的面积" = 两个 OBB 相交多边形的面积。要它必须先知道
##     **是哪两个矩形在相交** —— 而接触导出里不带矩形身份：实测
##     （tests/diag_fid_rect.gd）同一个方块砸在同一个两矩形刚体的左半与右半，
##     feature id **完全相同** -> fid 只是面/顶点级特征，不含子形状索引。
##   · 要做精确面积得先补 local_p1/local_p2（接触点在各自碰撞体局部坐标）、
##     再在 rect 列表里反查矩形、然后做多边形裁剪 —— 那是另一件事，当前不需要。
##   · **各点冲量已经够用**：份额 = |impulse_i| / total_impulse，实测份额之和 = 1。
func contact_info(idx: int) -> Dictionary:
	var r := _contact_fetch(idx)
	return {
		"points": r.get("points", []),
		"total_impulse": float(r.get("total_impulse", 0.0)),
		"id_a": int(r.get("id_a", 0)),
		"id_b": int(r.get("id_b", 0)),
	}


## ⚠️ 已删除：contact_geometry（宽度/深度/面积）—— 见 contact_info 的墓碑说明。
##    一句话：带宽面积在角接触上是**结构性错的**（1 个点 -> 宽度 0 -> 面积 0），
##    而精确的相互进入面积需要"是哪两个矩形"，当前导出不带这个身份。


## 本步的接触对数量（只数有流形点的）。
func contact_pair_count() -> int:
	var cmds := PackedByteArray()
	_rp_u8(cmds, 11)
	var res := _rp_send(cmds, 4)
	if res.decode_s32(0) < 4:
		return 0
	return res.decode_s32(4)


func _collect_contacts_rapier() -> void:
	if _rp == null:
		return
	# 接触数**无条件**取 —— 它是只读统计（看板在读），与是否订阅接触事件无关。
	var cnt_cmds := PackedByteArray()
	_rp_u8(cnt_cmds, 11)
	var cnt_res := _rp_send(cnt_cmds, 4)
	var n: int = cnt_res.decode_s32(4)
	last_contacts = n
	if not contact_events_enabled:
		return
	var seen := {}
	if n > 0:
		# ⚠️⚠️ 这里以前用 **op 12**：它只给"第一个流形的第一个点"作位置，却给整对的总冲量
		#    —— 整个面的冲量被附在一个代表点上。现在改用 **op 35**（全部点 + 各自冲量 +
		#    整对总冲量），于是 Contact 带上完整的接触面。
		# ⚠️ op 12 已删除（它在本项目里静默返回全 0，留着只会误导）。
		for i in n:
			var g := contact_info(i)
			var pts: Array = g["points"]
			if pts.is_empty():
				continue
			var a: PBody = _rp_by_id.get(int(g["id_a"]))
			var b: PBody = _rp_by_id.get(int(g["id_b"]))
			if a == null or b == null:
				continue
			var p0: Dictionary = pts[0]
			_contact_add_rapier(a, b, p0["position"], p0["normal"],
				float(g["total_impulse"]), pts)
			var ka := a.id
			var kb := b.id
			seen[(ka << 32) | (kb & 0xFFFFFFFF) if ka < kb else (kb << 32) | (ka & 0xFFFFFFFF)] = true
	_contact_prev = seen


func _contact_add_rapier(a: PBody, b: PBody, point: Vector2, normal: Vector2, impulse: float,
		pts: Array = []) -> void:
	if contacts.size() >= max_contacts:
		return
	var c := Contact.new()
	c.a = a
	c.b = b
	c.point = point
	c.normal = normal
	var rel := _vel_at_pre(b, point) - _vel_at_pre(a, point)
	c.approach = -rel.dot(normal)
	# _fill_contact_stress 会按"接近速度全部被吃掉"先填一个近似冲量，
	# 下面立刻用 Rapier 的真值覆盖它。contact_width / shear_ratio 仍然要它算。
	_fill_contact_stress(c, a, b, rel, 0.0)
	c.impulse = impulse
	# ⚠️ 增量数据（来自 op 35，见 _collect_contacts_rapier）：
	#    ⚠️ **不要**拿它们去改 contact_width / stress —— 那会改动物理可见的量，
	#    8 条逐位基准立刻就不再成立。这里只是把数据摆出来给游戏层用。
	c.points = pts
	c.total_impulse = impulse
	var ka := a.id
	var kb := b.id
	var key := (ka << 32) | (kb & 0xFFFFFFFF) if ka < kb else (kb << 32) | (ka & 0xFFFFFFFF)
	c.is_new = not _contact_prev.has(key)
	contacts.append(c)


## 抓取时的子步上限：预算(us) / (矩形数 x 每矩形每子步的**实测**代价)。
##
## ⚠️ 抽成函数是**为了让公式只有一个真源**：以前 tests/validation_grab_budget.gd
##    自己抄了一遍 `budget / total_rects`，于是引擎改了标定（1 -> 4.4 us/矩形）
##    而测试还在按旧公式算上限 —— 闸门会静默失效（它断言的是"子步 <= 上限"，
##    上限算大了就永远通过）。现在两边都调这个函数。
##
## ⚠️ 只在抓取时用得上（见 ccd_grab_substep_cost_budget_us）。
func grab_substep_cap(total_rects: int) -> int:
	return _cost_cap(total_rects, float(ccd_grab_substep_cost_budget_us))


## 「矩形数 + 时间预算 -> 子步上限」的**唯一**公式（grab 与全局两道闸门共用）。
##
## ⚠️ 抽成一个函数是为了**公式只有一个真源**：以前 tests/validation_grab_budget.gd
##    自己抄了一遍 `budget / total_rects`，于是引擎改了标定（1 -> 4.4 us/矩形）
##    而测试还在按旧公式算上限 —— 闸门会静默失效（它断言的是"子步 <= 上限"，
##    上限算大了就永远通过）。
## ⚠️ 预算 <= 0 返回一个大到不可能被选中的值（而不是 1）—— 语义是"不限"，不是"压到 1"。
func _cost_cap(total_rects: int, budget_us: float) -> int:
	if total_rects <= 0 or budget_us <= 0.0:
		return 1 << 30
	return maxi(1, int(budget_us / (float(total_rects) * CCD_RECT_COST_US)))


## 单个刚体的"运动"：线速度 + 角速度 x 外接半径（表面最快点）。
func _motion_of(b: PBody) -> float:
	return b.linear_velocity.length() + absf(b.angular_velocity) * b.bounding_radius()


## 全世界最快的运动 —— **逐刚体**（老行为，默认走这条）。
func _fastest_motion_plain() -> float:
	var fastest := 0.0
	# ⚠️ 只在 ccd_ignore_mass > 0 时构造这个集合 —— 默认关，老路径一次字典都不建
	#    （8 条逐位基准跑的就是老路径）。
	var exempt: Dictionary = _exempt_bodies() if ccd_ignore_mass > 0.0 else {}
	# ⚠️ 尺寸豁免（ccd_min_driver_thickness，默认关）：比它薄的刚体不参与统计。
	#    与质量豁免**独立**（两个都开就取并集）：质量受密度影响，换个材质就跨阈值，
	#    而"看不看得见"是尺寸说了算。
	var thin_gate: float = ccd_min_driver_thickness
	for b: PBody in bodies:
		# ⚠️ 冻结的刚体不参与：它不积分（速度是留着解冻用的），拿它算子步数纯属白算。
		if b.is_static or not b.awake or b.frozen:
			continue
		if not exempt.is_empty() and exempt.has(b):
			continue
		if thin_gate > 0.0 and b.thinnest_extent() < thin_gate:
			continue
		fastest = maxf(fastest, _motion_of(b))
	return fastest


## ccd_ignore_mass 生效时要跳过的"灰尘"集合。
## ⚠️ 抓着的 / 挂着关节的**不在里面**（它们要交互，穿墙会被看见）。
func _exempt_bodies() -> Dictionary:
	var out := {}
	for b: PBody in bodies:
		if b.is_static or b.frozen:
			continue
		if b.mass <= ccd_ignore_mass:
			out[b] = true
	for k in _interactive_bodies():
		out.erase(k)
	return out


## 抓着的 + 挂着关节的刚体（"要交互的"）—— 豁免与清理都必须放过它们。
func _interactive_bodies() -> Dictionary:
	var out := {}
	for g in grabs:
		if g.body != null:
			out[g.body] = true
	for j in joints:
		if not j.active:
			continue
		if j.body_a != null:
			out[j.body_a] = true
		if j.body_b != null:
			out[j.body_b] = true
	return out


## 全世界最快的运动 —— **关节感知**版本（见 ccd_joint_aware）：焊接组件当一个整体。
##
## ⚠️ 组内轻质件的瞬态速度被**质量加权**摊平 —— 这正是"轻手挂在重臂/地面上"的解药。
func _fastest_motion_grouped() -> float:
	var seen := {}
	var fastest := 0.0
	var exempt: Dictionary = _exempt_bodies() if ccd_ignore_mass > 0.0 else {}
	for b: PBody in bodies:
		if b.is_static or not b.awake or b.frozen or seen.has(b):
			continue
		var grp := weld_group(b)
		seen[b] = true
		for g in grp:
			seen[g] = true
		if grp.size() <= 1:
			# 单体：只有"焊死在静态世界"上才当 0（它整体动不了），否则照旧。
			# ⚠️ 豁免只对**单体**生效：组内的灰尘已经被 _group_motion 的质量加权摊平了
			#    （轻的拖不动重的），不需要也不应该把它从组里摘出去。
			#    尺寸豁免（ccd_min_driver_thickness）**同一条理由**，所以也只在单体上生效。
			if not exempt.is_empty() and exempt.has(b):
				continue
			if ccd_min_driver_thickness > 0.0 and b.thinnest_extent() < ccd_min_driver_thickness:
				continue
			fastest = maxf(fastest, 0.0 if _anchored_unbreakable(b) else _motion_of(b))
			continue
		fastest = maxf(fastest, _group_motion(grp))
	return fastest


## 这个刚体是否被**不可断的焊接**直接钉在静态世界上（世界锚或静态刚体）。
##
## ⚠️ 判据只认 **WELD**：铰链/滑轨允许运动，绳/弹簧更软 —— 它们连着的刚体该动还是动。
## ⚠️ 断得开的焊接**不算**：焊接可能在这一步里断掉，那时刚体是真在飞 ——
##    那种情况必须按它自己的速度算子步（宁可多算，不能少算）。
func _anchored_unbreakable(b: PBody) -> bool:
	for j in joints:
		if not j.active or j.kind != PJoint.WELD:
			continue
		if is_finite(j.break_impulse):
			continue
		var a_static: bool = j.body_a == null or j.body_a.is_static
		var b_static: bool = j.body_b == null or j.body_b.is_static
		if (j.body_a == b and b_static) or (j.body_b == b and a_static):
			return true
	return false


## 一个焊接组（动态成员）的整体运动估计：质量加权质心速度 + 角速度 x 组半径。
##
## ⚠️ 组被静态世界锚住 -> **0**（整体动不了）。
## ⚠️ 组里有**断得开**的焊接 -> 退回逐刚体的最大值（保守）：焊接可能在这一步断掉，
##    那时组内某个刚体是真在飞，摊平它就等于放松防穿。
func _group_motion(grp: Array) -> float:
	# ① 先看这个组的焊接都是什么性质：**断得开**的 -> 保守退回逐刚体最大；
	#    **锚在静态世界**上 -> 0（整体动不了）。
	var anchored := false
	var breakable := false
	for j in joints:
		if not j.active or j.kind != PJoint.WELD:
			continue
		var in_a: bool = grp.has(j.body_a)
		var in_b: bool = grp.has(j.body_b)
		if not in_a and not in_b:
			continue
		if is_finite(j.break_impulse):
			breakable = true
		var a_static: bool = j.body_a == null or j.body_a.is_static
		var b_static: bool = j.body_b == null or j.body_b.is_static
		if (in_a and b_static) or (in_b and a_static):
			anchored = true
	if breakable:
		var mx := 0.0
		for b: PBody in grp:
			if not b.is_static:
				mx = maxf(mx, _motion_of(b))
		return mx
	if anchored:
		return 0.0
	var m_sum := 0.0
	var v_sum := Vector2.ZERO
	var w_sum := 0.0
	var c := Vector2.ZERO
	for b: PBody in grp:
		# ⚠️ 冻着的成员速度是**留着解冻用的旧值**，算进整体运动就把子步数又顶上去了。
		if b.is_static or b.frozen:
			continue
		m_sum += b.mass
		v_sum += b.linear_velocity * b.mass
		w_sum += b.angular_velocity * b.mass
		c += b.com_world() * b.mass
	if m_sum <= 0.0:
		return 0.0
	c /= m_sum
	var r_max := 0.0
	for b: PBody in grp:
		if b.is_static:
			continue
		r_max = maxf(r_max, (b.com_world() - c).length() + b.bounding_radius())
	var v := v_sum / m_sum
	var w := w_sum / m_sum
	return v.length() + absf(w) * r_max


## 本步需要切成几个子步。判据是"最快的物体一步能走多远"：
## 只要每个子步的位移都小于最薄障碍物的厚度，就不可能穿过去。
##
## 这是引擎原本的机制，Rapier 迁移时被我删掉过（理由是"Rapier 自带 CCD"）——
## 结果 demo 穿模。Rapier 的 CCD 默认 max_ccd_substeps = 1，撑不住大步长
## （低帧率、帧卡顿、爆炸初速）。
func _compute_substeps(dt: float) -> int:
	# ⚠️⚠️ 所有出口都必须**经过迟滞那一段**。
	#    第一版这里保留了原来的 `return 1` 早退，结果拖动速度过零时（正弦拖动的
	#    3 个零点）子步数照样掉回 1 —— 实测"回落 3 次"，抖动依旧。
	# 【逐体模式】子步恒为 1：防穿交给逐体 CCD，不做全局子步。见 ccd_per_body_only。
	#
	# ⚠️ 这里是**早退**，而本函数顶上那条墓碑写着「所有出口都必须经过迟滞那一段」——
	#    那条针对的是「子步数会**波动**」引起的抖动（正弦拖动过零时掉回 1 -> 回落 3 次）。
	#    逐体模式下子步数是一个**常数**，不波动，也就没有抖动可言；
	#    但仍然要维护 _substeps_held 这条不变量（返回值 == _substeps_held），否则
	#    「自己驱动子步」的调用方读到的 last_substeps 会和真实步数分叉。
	if ccd_per_body_only:
		_substeps_held = maxi(1, ccd_fixed_substeps)
		if not _ccd_per_body_warned and ccd_enabled \
				and (rp_ccd_substeps <= 0 or rp_soft_ccd_prediction <= 0.0):
			_ccd_per_body_warned = true
			push_warning("[CCD] ccd_per_body_only 开着，但逐体 CCD 没武装好：" +
				" rp_ccd_substeps=%d（需要 >=1）、rp_soft_ccd_prediction=%.2f（需要 >0）。" % [
					rp_ccd_substeps, rp_soft_ccd_prediction] +
				" **这等于把防穿整个关掉**。")
		return _substeps_held
	var need := 1
	# ⚠️ total_rects 提到外面：迟滞那一段（返回值）也要用它做上限。
	var total_rects := 0
	if ccd_enabled and dt > 0.0:
		for b: PBody in bodies:
			total_rects += b.rects.size()
		# ⚠️ 取"最快运动"的两条路：默认逐刚体（老行为），可选的**关节感知**版本见
		#    ccd_joint_aware 的说明（焊接组件当整体估运动）。
		var fastest := _fastest_motion_grouped() if ccd_joint_aware else _fastest_motion_plain()
		if fastest > 0.0:
			var motion := fastest * dt
			if motion > ccd_max_motion:
				need = clampi(int(ceil(motion / ccd_max_motion)), 1, ccd_substep_budget)
		# 抓取时再按**世界大小**压一遍：每个子步都要步进整个世界（见
		# ccd_grab_substep_cost_budget_us 的说明）。⚠️ 只在抓取时生效 -> 基准逐位不变。
		if not grabs.is_empty() and total_rects > 0:
			need = mini(need, grab_substep_cap(total_rects))
		# 【新】**任何时候**都生效的代价预算（ccd_substep_cost_budget_us，默认 0 = 关）。
		#    与上面那道抓取闸门的分工见它的说明：抓取那道漏掉了"一个碎片飞过去"。
		if ccd_substep_cost_budget_us > 0.0 and total_rects > 0:
			need = mini(need, _cost_cap(total_rects, ccd_substep_cost_budget_us))
		# 【新】硬上限（ccd_max_substeps，默认 0 = 不限）。
		if ccd_max_substeps > 0:
			need = mini(need, ccd_max_substeps)
	# 迟滞：**涨立刻涨**（CCD 是安全项）；**抓着东西时不许落**。
	#
	# ⚠️⚠️ 为什么"不许落"：子步数是按**全世界最快的那个刚体**算的，它一变，**所有**刚体
	#    的积分步长就跟着变 —— 拖动时速度连续变化，子步数每帧都在跳，静止物体的
	#    亚像素平衡位置随之来回变，画面症状就是"抓起别的物体时，吊桥跟着抽搐"（甲方报的）。
	#
	# ⚠️⚠️ 那"永远不落"的代价怎么办？**给峰值设上限**，而不是让峰值掉下来 ——
	#    见 ccd_grab_substep_cost_budget_us：抓取时子步数先被世界大小压一遍，
	#    所以"钉在峰值"最多也就钉到那个上限（1000 矩形时 5~6 子步 ≈ 5 ms/帧），
	#    而不是 26 子步 23 ms/帧（用户报的"1000 矩形拖动掉到 8 帧"）。
	#
	# ⚠️ 试过并否掉的一条：让它在"停下 0.25 秒后"回落。症状也能压下去，但它拆掉了
	#    "拖动时子步数不回落"这条不变量 —— test_physics 的拖动用例（正弦拖动，
	#    慢速相位约 0.27 秒）当场抓到"回落 4 次"。那是修抽搐的东西，不该为了省帧时间
	#    把它拆掉。**设上限 ≠ 让峰值掉下来**，这条是根因层面的区别。
	#
	# ⚠️ 不抓东西时完全走原来的行为（need 是多少就是多少），所以基准逐位不变。
	if need >= _substeps_held or grabs.is_empty():
		_substeps_held = need
	# ⚠️⚠️ 【新】迟滞**也不许超过本步的上限** —— 否则 cap 只压 need、压不住已经涨上去的 held。
	#    实测（876 矩形场景，test/tools/bench_small_fragment_ccd.gd 的 E 段）：
	#    grab_substep_cap 算出 1，而 _substeps_held 沿用抓取前被顶上去的 **77**，
	#    一路返回 77 -> **768 ms/固定步**。cap 形同虚设。
	#    这就是"卡死"的直接来源，所以上限必须**同时**作用在返回值上。
	# ⚠️ 顺序无所谓（都是取 min），但放在迟滞**之后**是必须的 —— 放前面会被 need 重新顶上去。
	if ccd_max_substeps > 0:
		_substeps_held = mini(_substeps_held, ccd_max_substeps)
	if ccd_substep_cost_budget_us > 0.0 and total_rects > 0:
		_substeps_held = mini(_substeps_held, _cost_cap(total_rects, ccd_substep_cost_budget_us))
	if not grabs.is_empty() and total_rects > 0:
		_substeps_held = mini(_substeps_held, grab_substep_cap(total_rects))
	return _substeps_held


## 固定步的**前段**：清接触事件、刷新质心、灰尘清理、子步估计。返回该步要切几个子步。
##
## ⚠️⚠️ 为什么要有这个**公开钩子**（甲方实测踩到）：
##    "**自己驱动子步**"是合法用法 —— 要逐子步结算接触伤害就必须自己写那个循环
##    （甲方项目就是这么做的：只调 `_compute_substeps` + `_substep_rapier`）。
##    而灰尘清理原本只挂在 `step()` 里，于是那些项目里**清理一次都没跑过** ——
##    `debris_max_mass` 设多少都没用（他设到 1000 也没清掉一个碎片），
##    而且**不报任何错**。静默失效是最坏的失败方式，所以把前段抽成公开方法：
##    自己写循环的人调这一个，就不会再漏。
##
## 用法：
##     var n := world.pre_step(dt)
##     for i in n:
##         world._substep_rapier(dt / float(n))
##
## ⚠️ 顺序是契约：清理必须在子步估计**之前**（见 cull_fast_debris 的说明），
##    否则就是"先卡一帧、下一帧才清掉"。
func pre_step(dt: float) -> int:
	if contact_events_enabled:
		contacts.clear()          # 按**步**清空；子步会往同一个列表里追加
	for b in bodies:
		b.refresh_com()
	last_debris_removed = cull_fast_debris()
	var n := _compute_substeps(dt)
	last_substeps = n
	return n


func step(dt: float) -> void:
	# 物理交给 Rapier（宽相 / 窄相 / 求解 / 休眠都是它的），但**子步要自己切**。
	#
	# ⚠️ 这里曾经不切，理由是"Rapier 自带 CCD" —— 那是错的，代价是 demo 穿模。
	#    Rapier 的 CCD 默认 max_ccd_substeps = 1，撑不住大步长（低帧率、帧卡顿、
	#    爆炸初速）。而引擎原本的判据（最快物体每步位移 < 最薄障碍厚度）朴素但极稳。
	#
	# 切子步在物理上是**正确**的：每个子步 dt/N，力/重力/抓取都按 dt/N 积分，
	#    一帧的总冲量不变（早期担心的"力被重复施加"不成立 —— 那要每子步都用完整 dt）。
	var n := pre_step(dt)
	var sub := dt / float(n)
	for i in n:
		_substep_rapier(sub)

## ---------- 动量统计 ----------
##


## 固定步长推进：把"这一帧过了多久"换成整数个物理步。
##
## ⚠️ 这个方法一度被我删掉过（删 _compute_substeps / _substep 时误伤），
##    而**测试套件没覆盖到它** —— 是 demo 运行时才炸出来的
##    （game.gd: "Nonexistent function 'advance'"）。
##    教训：删"整块相邻函数"时，边界一定要按**函数名**核对，不能靠行号。
func advance(delta: float) -> int:
	_accum += delta
	var steps := 0
	while _accum >= fixed_dt and steps < max_substeps:
		step(fixed_dt)
		_accum -= fixed_dt
		steps += 1
	if steps == max_substeps:
		_accum = 0.0
	return steps
## 甲方要求"能读动量/角动量"。单体量在 PBody 上，这里给**总量** ——
## 总量是守恒检查的判据（碰撞前后应当相等，除非有重力/摩擦/阻尼在做功）。


## 全部动态体的总线动量 Σ m·v。
func total_momentum() -> Vector2:
	var s := Vector2.ZERO
	for b: PBody in bodies:
		if b.is_static:
			continue
		s += b.linear_momentum()
	return s


## 全部动态体关于世界某点的总角动量 Σ (I·ω + r × m·v)。
##
## ⚠️ 关于**原点**的角动量与关于**质心**的角动量是不同的量，而且只有关于
##    质心（或固定点）的角动量在无外力矩时才守恒。做守恒检查时请传质心。
func total_angular_momentum(about := Vector2.ZERO) -> float:
	var s := 0.0
	for b: PBody in bodies:
		if b.is_static:
			continue
		s += b.angular_momentum_about(about)
	return s


## 全部动态体的总动能。
func total_kinetic_energy() -> float:
	var s := 0.0
	for b: PBody in bodies:
		if b.is_static:
			continue
		s += b.kinetic_energy()
	return s


## 全部动态体的质心（按质量加权）。做守恒检查时传它当参考点。
func center_of_mass_world() -> Vector2:
	var m := 0.0
	var s := Vector2.ZERO
	for b: PBody in bodies:
		if b.is_static:
			continue
		m += b.mass
		s += b.com_world() * b.mass
	return s / m if m > 0.0 else Vector2.ZERO


## ---------- 接触事件 ----------
##
## 游戏层做"高速碰撞触发""挨打反应"需要知道**这一步发生了哪些接触、撞得多猛**。
## 引擎在这里把数据摆出来，但**不解释它** —— "多猛算高速""高速要怎样"是游戏规则。
##
## ⚠️ 三点约定，用之前必须知道：
##
## 1. **默认关闭**，而且开了**有代价** —— 实测（200 步、12 个刚体、7 对接触）：
##    关 79.3 ms / 开 1125.1 ms，即**每帧多 5.2 ms**，摊到每对接触约 **0.74 ms/帧**。
##    ⚠️ 开销大头**不是**对象分配，而是每对接触的**应力场**：contact_width
##    （沿切向逐像素走）和 shear_ratio 的两次 thickness_at。
##    => 三种用法，按需要选（代价从低到高）：
##       · 只要接触点/冲量 -> 走**查询路径**
##         （contact_pair_count / contact_points / contact_info），**不用开事件**；
##       · 要事件、不要应力 -> 开事件 + @@contact_stress_enabled = false@@（轻量模式）；
##       · 要应力（σ = 冲量/宽度）-> 两个都开。宽度是**惰性**的：读了才算。
##    ⚠️⚠️ 实测（tests/bench_contact_light.gd：120 个方块落在地面上，62 接触/步，
##    材质强度已配 —— 没配强度的话 thickness_at 那一段本来就不跑）：
##      关事件 1.49 ms/步 | 开+应力 12.95 | 轻量 2.86 | 轻量+读宽度 6.27
##      -> 每接触 185 us（旧行为）/ 22 us（轻量）/ 77 us（轻量但消费者读了宽度）。
##    也就是说：**旧行为的大头是应力场**（宽度扫描 ~77 us + 两次厚度扫描 ~108 us），
##    轻量模式把每接触从 185 us 压到 22 us（8.4x），而"要宽度、不要剪切比"的
##    消费者靠惰性拿到 77 us（2.4x）。
##
## 2. 事件在**求解之前**采集，所以 approach 是"撞击前的接近速度" —— 它是"撞得多猛"的
##    直接量，而且不受质量和恢复系数影响。
##    ⚠️ 冲量**现在也拿得到**：points 里每个点带**自己的** impulse，total_impulse 是整对
##    的预算（实测各点之和 = 它，比值 1.000）。
##    ⚠️ 旧注释写的是"冲量在原生求解器内部，GDScript 侧拿不到" —— 那是**旧架构**的限制
##    （当时项目跑自己那套求解器，冲量留在 C++ 里不回写）。现在求解器就是 Rapier 的，
##    由 op 35 把每个点的冲量导出来（见 PWorld.contact_points / contact_info）。
##
## 3. 有子步时，**同一个配对可能在一步里出现多次**（每个子步一次）。
##    引擎按步清空，不跨子步去重 —— 要"每步只触发一次"请游戏层自己按 is_new 过滤。
##    列表有上限（max_contacts），超了就不再记，避免子步多时爆内存。
var contact_events_enabled := false
## 接触事件的**应力场**（contact_width / shear_ratio）要不要在采集时填。
##
## ⚠️ 关掉 = **轻量模式**：事件照样给点/法向/接近速度/冲量（"撞了什么、撞得多猛、
##    撞在哪"全都还在），只是**不做**逐像素的宽度扫描、也不做两次厚度扫描
##    （见 _fill_contact_stress）—— 这两样是接触事件里最大的一项开销。
##
## ⚠️ 它不是"把 contact_width 变成 0"：那个属性本身是**惰性**的，关掉之后
##    再读它仍然会算一次（那是消费者自己要的，不是引擎无条件付的）。
##    真正被关掉的是 shear_ratio —— 它恒为 0。
##
## ⚠️ 代价：破坏判据里"抗压远强于抗剪"那一半会失效（strength_for 的插值退化成
##    纯抗压强度）。要那半个判据就别关。默认 true = 老行为。
var contact_stress_enabled := true
var max_contacts := 512
## 本步的接触事件（Contact 数组）。step() 开头清空，各子步往里追加。
var contacts: Array = []

var _contact_prev := {}

## 上一次取回时**每个接触对**的点数（op 35 的 cap 猜值，见 _contact_fetch）。
##
## ⚠️ 下标是"这一步的第几个接触对"，跨步会变（配对来去）—— 所以它**只是猜值**：
##    猜错无非是退回两步式，绝不影响读到的数据。
var _contact_point_hint := PackedInt32Array()


## 一次接触。字段都是**求解前**的状态。
class Contact:
	var a: PBody
	var b: PBody
	## 世界坐标接触点（取流形的第一个点；两点流形取中点意义不大，游戏一般只用它做特效位置）
	var point := Vector2.ZERO
	## 世界坐标法向，**由 a 指向 b**
	var normal := Vector2.ZERO
	## 沿法向的接近速度：**正 = 正在靠近**，单位 px/s。这就是"撞得多猛"。
	var approach := 0.0
	## 这一步该配对的**全部**接触点，每个点 {position, normal, dist, impulse}。
	##
	## ⚠️⚠️ 为什么需要它：面-面接触通常有 **2 个**接触点（60 Hz 是**更新时间**，
	##    不是接触数量限制）。只用 point 会在宽面撞击时把**整个面**的冲量集中到一处 ——
	##    照着那个点打洞就是"一次尖刺攻击"。多点伤害要把入口铺在这上面。
	## ⚠️ 每点带 fid1/fid2（面/顶点级特征 id），但它**不含矩形索引**（见 _contact_fetch 的说明）——
	##    跨帧去重要和位置组合，不能只靠它。
	var points: Array = []
	## 整对的总冲量 —— 这次碰撞的**预算**。多个入口要**共同分配**它
	## （每个入口按自己的 impulse 占比领，份额之和 = 1），而不是各自领走一整份。
	var total_impulse := 0.0
	# ⚠️ 这里曾经有 width / depth / area（接触带几何）。已删除 —— 见 contact_info 的墓碑：
	#    带宽面积在角接触上是结构性错的，精确面积又需要"是哪两个矩形"（当前导出不带）。
	## 这一步才接触上（上一步不在这对里）。做"首次撞击"触发用。
	var is_new := false

	## ---- 接触冲量的**近似值**（单位：质量·像素/秒）----
	##
	## ⚠️ 这是近似，不是求解器里的真值。原生求解器的冲量留在 C++ 里拿不到，
	##    所以这里按"有效质量 × 接近速度"估：
	##        m_eff = 1 / (1/m_a + 1/m_b)      （静态体视作无穷大质量）
	##        J ≈ m_eff · |approach|
	##    ⚠️ 这是**近似值，而且会在求解后被真值覆盖** —— 见 _fill_contact_impulses()。
	##    求解器算了精确的 normal_impulse，这里先按近似填上，只是为了让
	##    "求解器没跑到这一对"（比如它被 sleep 掉了、或没有对应流形）时仍有可用值。
	##    读取方不需要关心这个区别，读到的要么是真值要么是合理的近似。
	var impulse := 0.0

	## 接触的**切向宽度**（像素）：沿切向数「两个形状都实心」的像素数
	## （算法在 Query.contact_width，那里的注释记着为什么不能用 AABB 近似）。
	##
	## 用途：算应力 σ = impulse / contact_width。矛尖宽度小 → 应力大 → 能破盾。
	##
	## ⚠️⚠️ **惰性**：只有**读它**的消费者才付那次逐像素扫描（实测 60~110 us/接触，
	##    窗口随两者 AABB 的重叠跨度涨）。以前是采集时无条件算 —— 那是接触事件里
	##    最大的一项，而多数消费者（"撞得够狠吗""撞在哪"）根本不读它。
	##    第一次读之后结果缓存，重复读零成本（缓存对不对由
	##    tests/validation_contact_lazy.gd 用**几何预期**和**改像素**两条路钉住）。
	##    ⚠️ 连这一次都不想付 -> contact_stress_enabled = false（轻量模式）。
	var contact_width: float:
		get:
			if _width_cache < 0.0:
				_width_cache = Query.contact_width(a, b, point, normal, _separation)
			return _width_cache

	## 惰性宽度的缓存（-1 = 还没量过）。**内部字段**，别当公开字段用。
	var _width_cache := -1.0
	## 采集时记下的分离距离（只有投机接触非 0）。惰性测量要用它，所以存下来 ——
	## 它不是给消费者读的（要分离距离请读 points[i].dist）。
	var _separation := 0.0

	## **切向（摩擦）冲量**。求解之后的真值。
	##
	## 用途：算"磨"这种破坏 —— 盾被慢慢削薄不是被撞穿，是摩擦做功。
	## 与 impulse 一起构成这一对刚体本子步的总冲量。
	var tangent_impulse := 0.0

	## 内部：有效质量 1/(1/m_a + 1/m_b)（静态体视作无穷大质量）。
	## 冲量 = m_eff × 相对法向速度的**变化量**，所以求解前要把 m_eff 存下来。
	var _m_eff := 0.0

	## **剪切比**：0 = 纯压缩（法向穿过材料厚度方向），1 = 纯剪切。
	##
	## 由"接触法向 vs 该处材料的厚度方向"决定。同一种材料抗压远强于抗剪，
	## 所以这个值直接进破坏判据的强度插值。
	## 需要先调 set_material_strength() 才有意义；没设时保持 0。
	var shear_ratio := 0.0


## ⚠️ 已搬走：接触宽度 / 实心判定 / AABB 投影三个函数在 **Query**（query.gd）。
##    搬家的原因不是"分层好看"，而是 **Contact.contact_width 要惰性** ——
##    惰性 getter 在内类里跑，内类看不见外层的实例方法，只能调**静态**函数。
##    三个函数原本就是纯的（不读 PWorld 的任何字段），搬过去一行没改。
##    墓碑都跟着搬了（为什么不能用 AABB 近似、采样为什么要挪过分离距离）。


## 用**求解前后的相对速度变化量**算出真实冲量，回填到本子步的接触事件上。
##
## ## 为什么是这么算的
##
## 冲量的定义就是**动量变化**：J = m_eff · Δv。所以不需要从求解器内部把
## normal_impulse 掏出来 —— 求解前记下接近速度（采集时已经有了），
## 求解后再测一次相对法向速度，差值乘有效质量就是冲量。
##
## ## 为什么不用求解器的 normal_impulse
##
## 第一版是遍历流形取 Solver.Point.normal_impulse。那在 native 路径下完全空转：
## 宽相把 manifolds 置空，冲量留在 C++ 里且**不回写** —— 于是遍历的是一个空数组，
## Contact.impulse 永远是近似值、tangent_impulse 恒为 0，而且不报任何错。
## （那条路径连同 manifolds 字段一起删掉了；这段留着是因为教训仍然有效：
##   **「读一个没人填的容器」不会有任何报错**。）
##
## 现在这个算法**对两条路径都成立** —— 它只看速度，不关心冲量是在哪算的。
## 顺便还解决了近似值的最大毛病（偏心撞击高估，因为忽略转动项）：
## velocity_at() 取的是接触点处的速度，本来就含转动贡献。
##
## 旧文档（保留说明为何废弃）：
##
## ## 为什么要这一步
##
## 冲量是求解器的产物：它在迭代中累积每个接触点的 normal_impulse / tangent_impulse。
## 而接触事件是在**求解之前**采集的（那时才有"撞击前的接近速度"），
## 所以采集时冲量还不存在 —— 必须在求解之后补一次。
##
## ## 为什么不用近似了
##
## 之前 Contact.impulse 用的是 m_eff × approach 的**近似**，在偏心撞击下会高估
## （忽略了转动项）。而破坏判据最关心的恰恰是偏心撞击（矛尖戳盾面边缘）。
## 求解器本来就算了精确值，只是没往外递 —— 这里就是那个"递"。
##
## 代价：每个子步遍历一次流形的点，O(点数)。实测对 step 时间无可测影响。
## 开关：只为基准测试对比用（关掉就是加这个功能之前的行为）
var fill_contact_impulses_enabled := true


func _fill_contact_stress(c: Contact, a: PBody, b: PBody, rel: Vector2,
		separation: float = 0.0) -> void:
	var ma := 0.0 if a.is_static else a.mass
	var mb := 0.0 if b.is_static else b.mass
	var inv := (1.0 / ma if ma > 0.0 else 0.0) + (1.0 / mb if mb > 0.0 else 0.0)
	var m_eff := (1.0 / inv) if inv > 0.0 else 0.0
	c._m_eff = m_eff
	# 先按「接近速度全部被吃掉」填一个上界（就是以前的近似值），
	# 求解之后 _fill_contact_impulses 会用**实际动量变化**把它替换成真值。
	# 保留这一步是为了让「求解器没跑到这一对」（被 sleep 掉）时仍有可用值。
	c.impulse = m_eff * absf(c.approach)
	# ⚠️ 宽度**不在这里算**了 —— 它是惰性的（见 Contact.contact_width）。
	#    这里只把测量参数存下来：真去扫像素的是"第一个读它的人"。
	c._separation = separation
	if not contact_stress_enabled:
		return
	if material_compress.is_empty() and material_shear.is_empty():
		return
	# 剪切比：法向穿过多厚 = 压缩；法向几乎不穿过厚度 = 剪切。
	# 取两侧较薄的那个（谁先坏看谁）。
	# ⚠️⚠️ 方向必须是「从接触点**朝自己身体里**」。
	#    normal 是 A→B，所以对 A 而言要传 -normal。
	#    我第一版传反了，于是 thickness_at 从 point-normal*back 开始沿 normal 走 ——
	#    那是**离开** A 材料的方向，量到的段长恒等于 back(=4)，
	#    24 像素厚的墙和 80 像素厚的墙算出同一个 thin。
	#    症状是 shear_ratio 与材料厚度完全无关，"抗压远强于抗剪"从未生效，
	#    而且 set_material_strength 的第二个参数等于白设。
	var ta := Query.thickness_at(a, c.point, -c.normal)
	var tb := Query.thickness_at(b, c.point, c.normal)
	var thin := ta if (ta > 0.0 and (tb <= 0.0 or ta < tb)) else tb
	if thin <= 0.0:
		c.shear_ratio = 0.0
		return
	# 法向"穿过"的厚度越薄，越是正面顶上去（压缩）；
	# 用接触宽度 / 厚度 做剪切比的代理：宽而薄 = 弯曲/剪切。
	# ⚠️ 这里**显式读一次** c.contact_width：它会触发那次惰性扫描并缓存下来，
	#    所以"配了材质强度"的消费者仍然是老行为（宽度照算），只是算的位置挪到了这一行。
	var width: float = c.contact_width
	c.shear_ratio = clampf(width / (width + thin), 0.0, 1.0)


func cull_outside(bounds: Rect2) -> int:
	var removed := 0
	for i in range(bodies.size() - 1, -1, -1):
		var b: PBody = bodies[i]
		# ⚠️ 冻着的**不移除**：那是"暂停"，回来还要用（要移除就先解冻，或者别用它）。
		if b.is_static or b.frozen:
			continue
		if not bounds.intersects(b.aabb):
			# ⚠️⚠️ 必须走 remove_body()，**不能**只 bodies.remove_at(i)。
			#    曾经就是 remove_at：GDScript 这边刚体没了，而 Rapier 那边**一个都没删**
			#    —— remove_body 才是唯一会发 op 4（body_remove）的地方。
			#    症状（实测 tests/diag_cull_leak.gd）：连剔 5 轮 x 100 个之后，
			#    GDScript 侧只剩 1 个刚体，**Rapier 侧还有 501 个**；
			#    demo 里"切割地面 -> 碎片掉进虚空 -> 每 60 帧剔除一次"正是这条路，
			#    于是僵尸无界增长（每个 ~0.34 us/步，8000 个 = 2.7 ms/步）。
			#    顺带：remove_body 还会清掉挂在它上面的关节 —— remove_at 会让那些
			#    关节在 GDScript 侧悬空、在 Rapier 侧也泄漏。
			#    代价：每个刚体一次 _rp_send（实测 2.8 us），一次性剔几百个也只有 ~1 ms。
			remove_body(b)
			removed += 1
	return removed


## ---------- 冻结 / 恢复（**可逆**的"关掉物理"）----------
##
## ⚠️ 与 cull_outside() 的区别（这是两件事，别混）：
##   · cull_outside = **移除** —— 刚体从世界里消失，回来也回不来（远处的地形碎片用得上）；
##   · 冻结         = **暂停** —— 位置、速度、材质、关节全留着，解冻后接着跑。
##     "相机外扩两个区块、超出冻结、回来恢复"要的是后者。
##
## 实现：把刚体**按静态推给 Rapier**（op 15）。它不积分、不参与静态-静态对（整片冻住几乎
## 零成本），但碰撞体还在 —— 醒着的东西照样被它挡住。
## ⚠️ 速度**不清零**（存在 PBody 上），解冻时原样交回去。
## ⚠️ 解冻时必须重推密度/摩擦/恢复（Rapier 换刚体类型会重算质量属性）—— 见 step() 里那段。

## 冻结**单个**刚体。要连关节组一起冻用 freeze_component()，相机剔除用 cull_freeze()。
##
## ⚠️ 单冻一个是**有意的**能力（"把这块石头钉在空中"），但它会把关节另一头拽住 ——
##    半冻的关节组在游戏里看起来就是"机械臂被钉住了"，所以 cull_freeze 是按组件原子处理的。
## ⚠️ 返回 false = 没冻（本来就是静态，或者已经冻着了）。
func freeze(body: PBody) -> bool:
	if body == null or body.is_static or body.frozen:
		return false
	body.frozen = true
	body.awake = false          # 不参与积分/接触求解；Rapier 侧也按静态推（见 step）
	body.sleep_timer = 0.0
	return true


## 解冻：恢复成动态 + **唤醒**（它要重新积分、重新参与接触）。
##
## ⚠️⚠️ 这里有两件"看起来多余、少一件就静默失效"的事：
##   1. **强制重推速度**（镜像置 INF）：Rapier 把它当静态的这段时间里，它的内部速度
##      已经被重算掉了，而"变了才推"的判断因为镜像还停在冻结前的值而认为无需推送。
##      症状：**解冻后速度明明在（PBody 上），物体却一动不动**。
##      闸门 tests/validation_freeze.gd 的"解冻后接着跑"当场抓到（x 停在 48.62 不动）。
##   2. **显式叫醒**：它当了若干步的静态刚体，岛管理器不会自己把它放回模拟里 ——
##      只把类型改回动态是不够的（op 10）。
func unfreeze(body: PBody) -> void:
	if body == null or not body.frozen:
		return
	body.frozen = false
	body.awake = true
	body.sleep_timer = 0.0
	body._rp_vx = INF
	body._rp_vy = INF
	body._rp_w = INF
	body._rp_need_wake = true


func is_frozen(body) -> bool:
	return body != null and body.frozen


## 任意关节（WELD / HINGE / SLIDER / SPRING / ROPE）连通的**动态**刚体组件（含自己）。
##
## ⚠️ 与 weld_group() 的区别：那个只走 WELD（抓取的等效质量必须"真正刚性"）；
##    剔除要的是"动一个就动一串"—— 铰链/滑轨/绳都会把运动传出去，所以都要算。
func joint_component(body: PBody) -> Array:
	var out: Array = []
	if body == null or body.is_static:
		return out
	var seen := {body: true}
	var stack: Array = [body]
	while not stack.is_empty():
		var cur: PBody = stack.pop_back()
		out.append(cur)
		for j in joints:
			if not j.active:
				continue
			var other = null
			if j.body_a == cur:
				other = j.body_b
			elif j.body_b == cur:
				other = j.body_a
			else:
				continue
			if other == null or other.is_static or seen.has(other):
				continue
			seen[other] = true
			stack.append(other)
	return out


## 冻结**整个关节组件**（含自己）。返回本次冻住的刚体数。
func freeze_component(body: PBody) -> int:
	var n := 0
	for b: PBody in joint_component(body):
		if freeze(b):
			n += 1
	return n


## **相机剔除**（可逆）：范围外冻结、范围内恢复。
## 返回 {"frozen": 本次冻住数, "unfrozen": 本次恢复数, "kept": 保持计算的刚体数}。
##
## keep：必须保持计算的刚体（玩家、手上的东西）。**它们所在的整个关节组件**都不会被冻 ——
##       这就是"与玩家关节连接的物体保持计算"。
##
## ⚠️ 关节组件是**原子**的：一个组件要么整组醒着、要么整组冻着。半冻会让关节把醒着那头
##    钉住（玩家一走出范围，手上的机械臂就不动了 —— 而且不报任何错）。
## ⚠️ 被抓着的刚体永远不冻：抓取是每子步施加的力，冻住它等于"抓着一块石头"。
## ⚠️ 判据是世界 AABB 与 rect 相交（与 cull_outside 同口径；"外扩两个区块"由调用方
##    把 rect 算好再传进来 —— 引擎不认识区块）。
func cull_freeze(rect: Rect2, keep: Array = []) -> Dictionary:
	# ① "必须醒着"的集合 = keep 的整个关节组件 + 被抓住的东西的整个关节组件
	var must_awake := {}
	for k in keep:
		if k is PBody:
			for m: PBody in joint_component(k):
				must_awake[m] = true
	for g in grabs:
		if g.body != null:
			for m2: PBody in joint_component(g.body):
				must_awake[m2] = true
	# ② 按组件逐个决定（visited 保证每个组件只处理一次）
	var frozen_n := 0
	var unfrozen_n := 0
	var kept := 0
	var visited := {}
	for b: PBody in bodies:
		if b.is_static or visited.has(b):
			continue
		var comp := joint_component(b)
		var need_awake := false
		for m3: PBody in comp:
			visited[m3] = true
			if must_awake.has(m3) or rect.intersects(m3.aabb):
				need_awake = true
		if need_awake:
			kept += comp.size()
			for m4: PBody in comp:
				if m4.frozen:
					unfreeze(m4)
					unfrozen_n += 1
		else:
			for m5: PBody in comp:
				if freeze(m5):
					frozen_n += 1
	return {"frozen": frozen_n, "unfrozen": unfrozen_n, "kept": kept}


## ---------- 程序化破坏（世界坐标）----------
##
## fracture() 是**底层**接口：作用于一个 Body、坐标在**该 Body 的 Shape 局部像素空间**。
## 下面这一组才是给游戏逻辑用的 —— 给世界坐标，自动找出受影响的 Body 并换算过去，
## 并且**处理"破坏会改变 bodies 数组"这件事**（fracture 会增删刚体）。
##
## 全部返回新生成的碎片 Body 数组（与 fracture 一致）。
## material_delta：>0 把破坏边缘的像素换成该材质（烧焦/结冰/腐蚀），0 = 不改。
## burst_speed：碎片获得的初速度大小。

func damage_circle(world_center: Vector2, radius: float,
		material_delta: int = 0, burst_speed: float = 40.0) -> Array:
	var bounds := Rect2(world_center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)
	return _damage_world(bounds, material_delta, burst_speed,
		func(b: PBody) -> Variant: return Destruction.Damage.circle(b.to_local(world_center), radius))


func damage_rect(world_center: Vector2, half_size: Vector2,
		material_delta: int = 0, burst_speed: float = 40.0) -> Array:
	var bounds := Rect2(world_center - half_size, half_size * 2.0)
	return _damage_world(bounds, material_delta, burst_speed,
		func(b: PBody) -> Variant: return Destruction.Damage.rect(b.to_local(world_center), half_size))


## 沿一条世界坐标线段挖一条半径 radius 的沟（"激光切割"）。
func damage_segment(world_from: Vector2, world_to: Vector2, radius: float,
		material_delta: int = 0, burst_speed: float = 40.0) -> Array:
	var pad := Vector2(radius, radius)
	var lo := Vector2(minf(world_from.x, world_to.x), minf(world_from.y, world_to.y)) - pad
	var hi := Vector2(maxf(world_from.x, world_to.x), maxf(world_from.y, world_to.y)) + pad
	var bounds := Rect2(lo, hi - lo)
	return _damage_world(bounds, material_delta, burst_speed,
		func(b: PBody) -> Variant:
			return Destruction.Damage.segment(b.to_local(world_from), b.to_local(world_to), radius))


## 爆炸：半径内先按距离衰减施加**径向冲量**，再做一次圆形破坏。
##
## power 是**速度增量**语义（紧贴爆心的物体大约获得 power 的速度），
## 与物体质量无关 —— 内部按 impulse *= mass 抵消掉质量项。
func explode(world_center: Vector2, radius: float, power: float,
		material_delta: int = 0, burst_speed: float = 40.0) -> Array:
	var r2 := radius * radius
	for b: PBody in bodies:
		if b.is_static or not b.awake:
			continue
		var d := b.com_world() - world_center
		var dsq := d.length_squared()
		if dsq > r2:
			continue
		var dist := sqrt(dsq)
		var falloff := 1.0 - dist / radius
		var dir := Vector2.UP if dist < 1e-4 else d / dist
		b.apply_central_impulse(dir * (power * falloff * b.mass))
	return damage_circle(world_center, radius, material_delta, burst_speed)


## 世界坐标的"涂色"：把半径内的像素材质改成 material（**不破坏、不分裂**）。
## 返回改动的像素数。
##
## ⚠️ 只接受非 0 材质。擦除会把 Shape 挖成不连通（违反引擎不变量），
##    需要挖洞请用 damage_circle（它带连通性分裂）。
func paint_circle(world_center: Vector2, radius: float, material: int) -> int:
	if material <= 0:
		push_error("paint_circle 的 material 必须 > 0；挖洞请用 damage_circle")
		return 0
	var total := 0
	var bounds := Rect2(world_center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)
	var touched: Array = []
	for b: PBody in bodies:
		if b.rects.is_empty() or not bounds.intersects(b.aabb):
			continue
		var local_center := b.to_local(world_center)
		var n := 0
		for s in b.shapes:
			n += _paint_shape_circle(s, local_center, radius, material)
		if n > 0:
			total += n
			touched.append(b)
	# 材质变了 -> 密度可能变 -> 只对**真的被改到**的刚体重算质量/惯量
	for b2: PBody in touched:
		if not b2.is_static:
			refresh_mass(b2)
	return total


func _paint_shape_circle(shape, local_center: Vector2, radius: float, material: int) -> int:
	var n := 0
	var r2 := radius * radius
	var lo := Vector2i(int(floor(local_center.x - radius)), int(floor(local_center.y - radius)))
	var hi := Vector2i(int(ceil(local_center.x + radius)), int(ceil(local_center.y + radius)))
	for y in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			var dx := float(x) + 0.5 - local_center.x
			var dy := float(y) + 0.5 - local_center.y
			if dx * dx + dy * dy > r2:
				continue
			if shape.get_pixel(x, y) == 0:
				continue
			shape.set_pixel(x, y, material)
			n += 1
	return n


func _damage_world(bounds: Rect2, material_delta: int, burst_speed: float,
		make_damage: Callable) -> Array:
	var out: Array = []
	# ⚠️ fracture 会增删 bodies —— 必须先拷一份再遍历，否则会漏掉/重复处理
	for b: PBody in bodies.duplicate():
		if b.rects.is_empty() or not bounds.intersects(b.aabb):
			continue
		var d = make_damage.call(b)
		d.material_delta = material_delta
		# 注意：这里**不需要**手动标记内容变了 —— PBody.rebuild() 里统一做了
		# （破坏、擦除、绘制都汇到那一个 choke point）。之前我在这补过，
		# 那是症状处的补丁，漏掉 PixelEditor 那条路。
		for p in fracture(b, d, burst_speed):
			out.append(p)
	return out


## ---------- 破坏（底层）----------

## 在 body 局部像素空间施加破坏，并做连通性分裂。
## 返回新生成的碎片 Body（原 Body 保留最大的那一块）。
func fracture(body: PBody, damage, burst_speed: float = 40.0) -> Array:
	var removed := 0
	var parts: Array = []
	# 报告受影响的块范围 —— 见 PixelShape.mark_dirty_range 的说明。
	#
	# ⚠️⚠️ 标记必须打在 **rebuild 之后**（见本函数末尾），不能打在这里。
	#    rebuild 会把 body.shapes 换成 split 产生的**新对象**，
	#    打在旧对象上的脏标记随对象一起被丢掉 ——
	#    症状是渲染器永远拿不到块级脏信息，退到全量重建，
	#    分块贴图白做（实测 sync 仍是 ~35 ms，看不出任何收益）。
	#    这个坑我踩过一次，所以把范围算好留到后面用。
	var dmg_bounds: Rect2 = damage.bounds()
	var dmg_rect := Rect2i(
		floori(dmg_bounds.position.x), floori(dmg_bounds.position.y),
		ceili(dmg_bounds.size.x) + 1, ceili(dmg_bounds.size.y) + 1)
	for s in body.shapes:
		# ⚠️⚠️ 判据必须在 apply_damage **之前**取！
		#    挖完之后，洞的边缘像素天然邻接空像素 —— 那时再问"碰到边界了吗"
		#    永远返回 true，跳过永远不生效（我第一版就是这么写的，
		#    实测内部擦除仍是 107 ms，一点没省）。
		#    要问的是：**破坏之前**，伤害覆盖的范围内有没有已经是边界的像素。
		# ⚠️⚠️ 判据的检查范围要**保守地扩大**，不能用 dmg_rect 本身。
		#
		#    dmg_rect 是伤害的**包围盒**，而实际被删掉的像素未必严格落在里面
		#    （半径、材质、笔刷的边界处理都可能让它溢出一点）。
		#    一旦判据因为"看漏了"而返回 false，就会**跳过本该做的 split** ——
		#    形状数据断了，但 rects 没重算成两块，于是
		#    **画出来的形状和碰撞体不一致**（用户报的就是这个）。
		#
		#    宁可多判一点：多查 8 像素的边，代价是极少数情况下多做一次
		#    本来能省的 split，换来的是判据不会漏。
		# ⚠️ 余量从 8 缩到 2 —— 这一条本身就是**迭代数**问题：
		#    探测框是 (w+2m) x (h+2m)，每个像素要查 9 次 get_pixel（自身 + 八邻域）。
		#    m=8 时是 40x40 = 1600 像素 -> 14400 次 get_pixel -> **4.5 ms/笔**。
		#    m=2 时是 28x28 = 784 像素 -> 约 2.2 ms。
		#
		#    仍然可靠：伤害是**胶囊**，Damage.bounds() 已经把半径算进去了，
		#    实际被删的像素不会超出包围盒 1 个像素以上。2 像素余量足够覆盖，
		#    而"没碰到边界"这个判据只会因此变得更保守（宁可多做一次 split）。
		var probe := Rect2i(dmg_rect.position - Vector2i(2, 2), dmg_rect.size + Vector2i(4, 4))
		var was_boundary: bool = probe.size.x > 0 and Destruction.touches_boundary(s, probe)
		removed += Destruction.apply_damage(s, damage)
		# ⚠️ 便宜的必要条件：凸的伤害集**严格在形状内部**时不可能断开形状，
		#    而 split 要跑全量连通分量标记（1248 个 chunk，实测 **31 ms**）。
		#    对照：apply_damage 只要 0.35 ms —— split 是它的 88 倍，
		#    而绝大多数笔画都是内部挖洞，根本不需要查连通性。
		#
		#    判据见 Destruction.touches_boundary 的说明：
		#    是"**碰到边界**"，不是"包围盒离边界有余量"—— 后者不成立
		#    （细杆在中间被擦断时包围盒离外边界很远，但确实断了）。
		if was_boundary:
			# ⚠️ 先试**便宜且可证明**的局部判据（见 Destruction.local_connectivity）：
			#    代价随伤害大小走，而不是随物体尺寸走。
			#    贴着大物体边界挖个小洞以前要跑全量连通分量标注（768x100 实测 7.8 ms），
			#    而那一笔本身只要 ~2.8 ms —— 用户报的"边界挖小洞也卡"就是这个。
			var lc := Destruction.local_connectivity(s, dmg_rect, min_fragment_pixels)
			if lc == Destruction.LOCAL_CONNECTED:
				parts.append(s)
			elif lc == Destruction.LOCAL_DROPPED:
				pass
			else:
				for p in Destruction.split(s, min_fragment_pixels, true):
					parts.append(p)
		else:
			parts.append(s)   # 内部挖洞 -> 必然仍连通，原样留下
	if removed == 0:
		return []
	if parts.is_empty():
		remove_body(body)
		return []

	# 最大的那块留在原 Body
	#
	# ⚠️ 只有**多块**时才需要挑最大。内部挖洞走的是"不 split"那条路，
	#    parts 里只有一个元素 —— 而 pixel_count() 要遍历**全部 chunk**
	#    （768x100 是 1238 个，实测 **0.371 ms/笔**），
	#    每一笔擦除都在付，换来的却是"best 一定是 0"这个显然的事实。
	#    split 那条路（多块）照旧挑，行为不变。
	var best := 0
	if parts.size() > 1:
		var best_n := -1
		for i in parts.size():
			var cnt: int = parts[i].pixel_count()
			if cnt > best_n:
				best_n = cnt
				best = i

	var parent_vel := body.linear_velocity
	var parent_ang := body.angular_velocity
	# ⚠️⚠️ 这里曾经传的是 `Callable()`（没有密度回调）—— 后果是**母体**被打完洞之后
	#    质量变成"像素数"（密度 1.0）、摩擦/恢复系数被写成 0，而碎片反而是对的（走 add_body）。
	#    游戏层因此**必须**自己再调一次 refresh_mass()，把逐像素扫描 + 贪心分解 +
	#    碰撞体重推 + 整张贴图重建**再付一遍**（768x100 约 44 ms）。
	#    现在三个 Callable 都传（见 PBody.rebuild 的说明）—— 那次 refresh_mass 可以删了。
	#    闸门：tests/validation_mass_after_destruction.gd。
	body.rebuild([parts[best]], density_callable(), max_rects_per_shape, dmg_rect,
		friction_callable(), restitution_callable())
	# ⚠️ 现在才标 —— parts[best] 是 split 产出的**新** shape，是 body.shapes 里
	#    真正留下的那个。见本函数开头关于"标记打早了会被丢掉"的说明。
	#    split 保持局部坐标系，所以伤害的局部范围可以直接用。
	parts[best].mark_dirty_range(dmg_rect)
	body.awake = true
	body.sleep_timer = 0.0
	body.update_aabb()

	var spawned: Array = []
	for i in parts.size():
		if i == best:
			continue
		var frag := PBody.new()
		frag.position = body.position
		frag.rotation = body.rotation
		# 继承母体速度，并给一点向外飞散的冲量
		var dir: Vector2 = parts[i].local_aabb().get_center() - parts[best].local_aabb().get_center()
		if dir.length_squared() < 0.0001:
			dir = Vector2(0, -1)
		frag.linear_velocity = parent_vel + dir.normalized() * burst_speed
		frag.angular_velocity = parent_ang
		frag.awake = true
		# connected_known = true：parts 来自 split 的分组，天然单连通 ——
		# 传 false 会让每个碎片白跑一次全量连通性标注（~14 ms/个）。
		add_body(frag, [parts[i]], Callable(), true)
		spawned.append(frag)
	return spawned


## ---------- 抓取 ----------

func grab(b: PBody, world_point: Vector2, accel: float = 1500.0) -> Grab:
	## 抓取：每子步一个**受限的力**（力控，不是强制位移）。见 grab.gd 的说明。
	##
	## accel = 力上限对应的加速度（默认 1500 ≈ 1.7g）。重物滞后、抓偏会转，都是设计意图。
	release_grab()
	if b == null or b.is_static:
		return null
	var g := Grab.new()
	g.body = b
	g.local_anchor = b.to_local(world_point)
	g.target = world_point
	g.max_accel = accel
	grabs.append(g)
	b.awake = true
	b.sleep_timer = 0.0
	return g


func set_grab_target(world_point: Vector2) -> void:
	for g in grabs:
		g.target = world_point


func release_grab() -> void:
	grabs.clear()


func is_grabbing() -> bool:
	return not grabs.is_empty()


## 这个刚体所在的**焊接组件**（含它自己；只收动态刚体）。
##
## 用途：抓取。力控的等效质量必须按**整个组件**算（见 grab.gd 文件头的坑 2），
## 否则"按单体质量算的力"会把焊接处拽变形。
##
## ⚠️ 只走 **WELD**：焊接才是真正刚性的（"把两块拼成一块"）。铰链/滑轨允许相对运动，
##    绳/弹簧更是软的 —— 把它们也算成"一个刚体"，拖绳子的手感会变成"整条链一起飞"。
func weld_group(body: PBody) -> Array:
	var out: Array = []
	if body == null or body.is_static:
		return out
	var seen := {body: true}
	var stack: Array = [body]
	while not stack.is_empty():
		var cur: PBody = stack.pop_back()
		out.append(cur)
		for j in joints:
			if not j.active or j.kind != PJoint.WELD:
				continue
			var other = null
			if j.body_a == cur:
				other = j.body_b
			elif j.body_b == cur:
				other = j.body_a
			else:
				continue
			if other == null or other.is_static:
				continue
			if not seen.has(other):
				seen[other] = true
				stack.append(other)
	return out


## ---------- 关节 ----------## ---------- 关节 ----------## ---------- 关节 ----------
##
## 五种关节都返回一个 PJoint（见 src/physics/joint.gd）；**b 传 null 表示接静态世界**。
## 求解在 Rapier 里（ImpulseJoint），这一层只负责"把参数翻译成命令流"，
## 以及把断裂判定所需的冲量读回来。

## 铰链：两个刚体绕一个世界坐标点相对转动（门、轮子、摆）。
## world_anchor 省略时取两端质心的中点。
func add_hinge(a: PBody, b: PBody, world_anchor := Vector2.INF) -> PJoint:
	return _add_joint(PJoint.HINGE, a, b, world_anchor, world_anchor, Vector2.RIGHT, 0.0, 0.0, 0.0)


## 滑轨：沿 axis（**世界方向**）相对平移（活塞、抽屉）。两端朝向不同也能对上 ——
## 轴在 Rapier 侧各自转到自己的局部系（见 rb_joint_new 里那条说明）。
func add_slider(a: PBody, b: PBody, world_anchor := Vector2.INF, axis := Vector2.RIGHT) -> PJoint:
	return _add_joint(PJoint.SLIDER, a, b, world_anchor, world_anchor, axis, 0.0, 0.0, 0.0)


## 焊接：完全锁死。**创建时刻的相对位姿就是"零位"** —— 两个各自转过的刚体
## 焊在一起不会自己转正（Rapier 的关节帧按创建时的相对朝向设零）。
func add_weld(a: PBody, b: PBody, world_anchor := Vector2.INF) -> PJoint:
	return _add_joint(PJoint.WELD, a, b, world_anchor, world_anchor, Vector2.RIGHT, 0.0, 0.0, 0.0)


## 绳：两点距离**不超过** max_length（不可伸长，但可以松）。
func add_rope(a: PBody, b: PBody, world_anchor_a: Vector2, world_anchor_b: Vector2,
		max_length: float) -> PJoint:
	return _add_joint(PJoint.ROPE, a, b, world_anchor_a, world_anchor_b, Vector2.RIGHT,
		max_length, 0.0, 0.0)


## 弹簧：拉向 rest_length。
## 刚度/阻尼是 Rapier 的 ForceBased 语义：**力 = 刚度 × 误差 + 阻尼 × 速度误差**
## （注意是绝对力，和质量的相对关系与马达相反 —— 重物会明显更"软"）。
func add_spring(a: PBody, b: PBody, world_anchor_a: Vector2, world_anchor_b: Vector2,
		rest_length: float, stiffness := 100.0, damping := 10.0) -> PJoint:
	return _add_joint(PJoint.SPRING, a, b, world_anchor_a, world_anchor_b, Vector2.RIGHT,
		rest_length, stiffness, damping)


func _add_joint(kind: int, a: PBody, b: PBody, anchor_a: Vector2, anchor_b: Vector2,
		axis: Vector2, rest: float, stiff: float, damp: float) -> PJoint:
	if a == null and b == null:
		push_error("add_joint：两端不能都是 null（null = 静态世界，至少要有一端是刚体）")
		return null
	if a != null and b != null and a == b:
		# Rapier 侧直接拒绝同体自连（相对位姿恒为 0，求解会出 NaN），这里早点报错。
		push_error("add_joint：不能把刚体连到它自己")
		return null
	for body: PBody in [a, b]:
		if body != null and not bodies.has(body):
			push_error("add_joint：刚体还没加进这个世界（先 world.add_body(...)）")
			return null
	# 世界锚一律放在 **A 侧**：这样 movement()/speed() 的符号就是"刚体相对世界" ——
	# 刚体沿 +axis 走读数为正、往 +方向转角度为正，和直觉一致。
	#
	# ⚠️ 反过来（刚体在 A、世界在 B）的话，Rapier 的自由度是"B 相对 A"，
	#    于是"沿 +axis 走"读出来是**负数**，限位的 min/max 也跟着镜像。
	#    实测：滑块给 +X 冲量，movement 报 -19.8；而限位确实按这个负数生效
	#    （所以不是符号显示问题，是真的反了）。
	#    两个真刚体之间**不换**：movement = B 相对 A，谁当参考系由调用方决定。
	if b == null and a != null:
		var tmp_body: PBody = a
		a = b
		b = tmp_body
		var tmp_anchor: Vector2 = anchor_a
		anchor_a = anchor_b
		anchor_b = tmp_anchor
	if anchor_a == Vector2.INF:
		anchor_a = _joint_default_anchor(a, b)
	if anchor_b == Vector2.INF:
		anchor_b = anchor_a
	var j := PJoint.new()
	j.world = self
	j.kind = kind
	j.body_a = a
	j.body_b = b
	j.local_anchor_a = a.to_local(anchor_a) if a != null else anchor_a
	j.local_anchor_b = b.to_local(anchor_b) if b != null else anchor_b
	j.axis = axis.normalized() if axis.length() > 0.0 else Vector2.RIGHT
	j.rest_length = rest
	j.stiffness = stiff
	j.damping = damp
	j._rot_a0 = 0.0 if a == null else a.rotation
	j._rot_b0 = 0.0 if b == null else b.rotation
	joints.append(j)
	_rp_joints_pending.append(j)
	return j


func _joint_default_anchor(a: PBody, b: PBody) -> Vector2:
	if a != null and b != null:
		return (a.com_world() + b.com_world()) * 0.5
	if a != null:
		return a.com_world()
	return b.com_world()


## 主动断开一个关节（刚体照旧，只是不再连在一起）。
func remove_joint(j) -> void:
	if j == null:
		return
	_rp_joints_pending.erase(j)
	if not joints.has(j):
		return
	joints.erase(j)
	if _rp != null and j.rapier_id > 0:
		var cmds := PackedByteArray()
		_rp_u8(cmds, 25)
		_rp_u32(cmds, j.rapier_id)
		_rp_send(cmds, 4)
	j.rapier_id = 0
	j.active = false
	j.world = null


## 静默丢掉一个关节：Rapier 侧已经不在了（刚体被删时 Rapier 把挂它的关节一起删了），
## 只需要清 GDScript 侧的表 —— 这时候再发 joint_remove 是多余的。
func _joint_drop_silent(j) -> void:
	joints.erase(j)
	_rp_joints_pending.erase(j)
	j.rapier_id = 0
	j.active = false
	j.world = null


## ⚠️ 这里曾经有个 `weld_group()`（沿 WELD 关节 BFS 求焊接组件），
##    因为抓取是"力控制器"、必须自己把组件质量算出来才不会过冲。
##    抓取换成**鼠标关节**之后它就没有存在理由了：关节会把力通过焊接传下去，
##    求解器自己知道整个组件有多重。**别再加回来** ——
##    任何"脚本替求解器算等效质量"的做法都会和真实约束（软焊接）分叉。

## 连在这个刚体上的所有关节。
func joints_of(body: PBody) -> Array:
	var out: Array = []
	for j in joints:
		if j.body_a == body or j.body_b == body:
			out.append(j)
	return out


## 这个刚体是否**直接或间接**被关节连到静态世界（世界锚或静态刚体）。
##
## 这是"一堆碎块还锚在墙上，不必各自模拟"的判据（对应参考 API 的锚定检测）。
## 注意它只走关节图，**不含接触**：落在静态地面上的刚体不算"jointed to static"。
func is_jointed_to_static(body: PBody) -> bool:
	if body == null:
		return false
	var seen := {body: true}
	var stack: Array = [body]
	while not stack.is_empty():
		var cur: PBody = stack.pop_back()
		for j in joints:
			if not j.active:
				continue
			var other = null
			if j.body_a == cur:
				other = j.body_b
			elif j.body_b == cur:
				other = j.body_a
			else:
				continue
			if other == null or other.is_static:
				return true
			if not seen.has(other):
				seen[other] = true
				stack.append(other)
	return false


## 把还没有 Rapier 身份的关节建出来。
##
## ⚠️ 必须在 _rp_create_missing() **之后**调：关节两端要的是刚体的 rapier_id，
##    而那个 id 是 Rapier 分配的（第一趟发命令时还不知道）。两端只要有一个
##    还没拿到 id，这个关节就留在 _rp_joints_pending 里等下一子步。
func _rp_create_joints() -> void:
	if _rp_joints_pending.is_empty():
		return
	var cmds := PackedByteArray()
	var todo: Array = []
	for j in _rp_joints_pending:
		if j.body_a != null and j.body_a.rapier_id <= 0:
			continue
		if j.body_b != null and j.body_b.rapier_id <= 0:
			continue
		# ⚠️ 建关节**之前**必须把两端的位姿推过去。
		#    Rapier 侧的关节零位是拿"它自己当前的刚体旋转"算出来的（见 rb_joint_new），
		#    而刚体旋转是"变了才推"：调用方如果在 add_body 之后改了 rotation 再建关节，
		#    Rapier 那边还是旧旋转 -> 关节零位错位，表现为"建完自己转一下才停"。
		#    推一次很便宜（建关节是低频操作），换来"建关节时两端的位姿一定是准的"。
		for body: PBody in [j.body_a, j.body_b]:
			if body == null:
				continue
			_rp_u8(cmds, 6)
			_rp_u32(cmds, body.rapier_id)
			_rp_f64(cmds, body.position.x)
			_rp_f64(cmds, body.position.y)
			_rp_f64(cmds, body.rotation)
			body._rp_x = body.position.x
			body._rp_y = body.position.y
			body._rp_rot = body.rotation
		_rp_u8(cmds, 24)
		_rp_i32(cmds, j.kind)
		_rp_u32(cmds, 0 if j.body_a == null else j.body_a.rapier_id)
		_rp_u32(cmds, 0 if j.body_b == null else j.body_b.rapier_id)
		_rp_f64(cmds, j.local_anchor_a.x)
		_rp_f64(cmds, j.local_anchor_a.y)
		_rp_f64(cmds, j.local_anchor_b.x)
		_rp_f64(cmds, j.local_anchor_b.y)
		_rp_f64(cmds, j.axis.x)
		_rp_f64(cmds, j.axis.y)
		_rp_f64(cmds, j.rest_length)
		_rp_f64(cmds, j.stiffness)
		_rp_f64(cmds, j.damping)
		todo.append(j)
	if todo.is_empty():
		return
	var res := _rp_send(cmds, todo.size() * 4)
	var off := 4
	for j in todo:
		j.rapier_id = res.decode_s32(off)
		off += 4
		_rp_joints_pending.erase(j)
		if j.rapier_id <= 0:
			# Rapier 拒绝了参数（同体自连 / 绳长 <= 0 / 刚体不存在）。
			# ⚠️ 这里必须**吵闹**：留着它的话后面的"变了才推"会对着 id 0 发命令，
			#    表现为"关节静默不存在"，非常难查。
			push_error("关节创建失败（kind=%d）：Rapier 拒绝了参数。" % j.kind)
			_joint_drop_silent(j)


## Rapier 侧的关节数（诊断用：确认删刚体时关节没有泄漏）。
func rp_joint_count() -> int:
	if _rp == null:
		return 0
	var cmds := PackedByteArray()
	_rp_u8(cmds, 31)
	var res := _rp_send(cmds, 4)
	return res.decode_s32(4)


## 关节的限位/马达：变了才推。
##
## ⚠️ 增量推送是**必须**的：每个关节每子步都发一遍，一屏 100 个关节就是 100 条
##    命令/子步 —— 而绝大多数关节的参数一辈子不变。
func _rp_push_joints(cmds: PackedByteArray) -> void:
	for j in joints:
		if j.rapier_id <= 0:
			continue
		# 接触开关：默认关（见 PJoint.contacts_enabled）。Rapier 侧默认是开，
		# 所以第一子步一定会推一次。
		if j.contacts_enabled != j._rp_contacts:
			_rp_u8(cmds, 33)
			_rp_u32(cmds, j.rapier_id)
			_rp_i32(cmds, 1 if j.contacts_enabled else 0)
			j._rp_contacts = j.contacts_enabled
		if j.limits_enabled != j._rp_limits_on or j.min_limit != j._rp_min or j.max_limit != j._rp_max:
			_rp_u8(cmds, 26)
			_rp_u32(cmds, j.rapier_id)
			if j.limits_enabled:
				_rp_f64(cmds, j.min_limit)
				_rp_f64(cmds, j.max_limit)
			else:
				# min > max = "不限制"（Rust 侧按这个约定还原成 ±Real::MAX）
				_rp_f64(cmds, INF)
				_rp_f64(cmds, -INF)
			j._rp_limits_on = j.limits_enabled
			j._rp_min = j.min_limit
			j._rp_max = j.max_limit
		# 求解软度（R3）：0 = 用 Rapier 默认（joint_defaults）。
		# ⚠️ 镜像初值是 -1（"从没推过"），所以设过之后即使改回 0 也会推一次"回默认"。
		if j.solver_frequency != j._rp_soft_freq:
			_rp_u8(cmds, 40)
			_rp_u32(cmds, j.rapier_id)
			_rp_f64(cmds, j.solver_frequency)
			_rp_f64(cmds, j.solver_damping)
			j._rp_soft_freq = j.solver_frequency
		if j.motor_mode == j._rp_motor_mode and j.motor_target == j._rp_motor_target \
				and j.motor_max_force == j._rp_motor_force \
				and j.motor_stiffness == j._rp_motor_stiffness \
				and j.motor_damping == j._rp_motor_damping:
			continue
		match j.motor_mode:
			PJoint.MOTOR_VELOCITY:
				_rp_u8(cmds, 27)
				_rp_u32(cmds, j.rapier_id)
				_rp_f64(cmds, j.motor_target)
				_rp_f64(cmds, j.motor_damping)
				_rp_f64(cmds, j.motor_max_force)
			PJoint.MOTOR_POSITION:
				_rp_u8(cmds, 28)
				_rp_u32(cmds, j.rapier_id)
				_rp_f64(cmds, j.motor_target)
				_rp_f64(cmds, j.motor_stiffness)
				_rp_f64(cmds, j.motor_damping)
				_rp_f64(cmds, j.motor_max_force)
			_:
				_rp_u8(cmds, 29)
				_rp_u32(cmds, j.rapier_id)
		j._rp_motor_mode = j.motor_mode
		j._rp_motor_target = j.motor_target
		j._rp_motor_force = j.motor_max_force
		j._rp_motor_stiffness = j.motor_stiffness
		j._rp_motor_damping = j.motor_damping


## 断裂：约束冲量超过阈值就断开。
##
## Rapier 没有"关节断裂"这个概念，所以这是**我们的判据**：读回来的冲量
## （力 × 时间步）超过 break_impulse 就删掉关节，并把它记进 broken_joints。
##
## ⚠️ 冲量随 dt 变（子步越小，同样载荷下冲量越小），所以阈值是"每步冲量"而不是力：
##    要跨帧率稳定，用 break_impulse ≈ 目标力 × 你的固定 dt。
func _break_joints_over_threshold(cands: Array) -> void:
	var broken_now: Array = []
	for j in cands:
		if j.broken or not j.active or j.rapier_id <= 0:
			continue
		if j.last_impulse > j.break_impulse:
			broken_now.append(j)
	if broken_now.is_empty():
		return
	var cmds := PackedByteArray()
	for j in broken_now:
		_rp_u8(cmds, 25)
		_rp_u32(cmds, j.rapier_id)
	_rp_send(cmds, 4)
	for j in broken_now:
		j.broken = true
		j.active = false
		j.rapier_id = 0
		j.world = null
		joints.erase(j)
		broken_joints.append(j)


## 删掉"又轻又快"的灰尘（阈值见 debris_max_mass / debris_min_speed）。返回删掉的个数。
##
## ⚠️ 为什么由 step() **自动**调，而不是让游戏层每帧自己调：
##    子步估计就在 step 里，而"灰尘拿到高速度"（Δv = J/m —— 同样的冲量，轻 100 倍就快
##    100 倍）与"估计看到它"之间只隔一个子步。早一步删掉，那一帧的尖峰**根本不会发生**；
##    放到外面调就变成"先卡一帧、下一帧才清掉"（实测那一帧 346 ms）。
##
## ⚠️ 两个阈值都必须 > 0 才生效（默认 0 = 关 -> 8 条逐位基准不动）。
func cull_fast_debris() -> int:
	# ⚠️ 只有**质量**阈值是总开关；debris_min_speed <= 0 = **不限速度**（只按质量清）。
	#
	#    为什么这样定（甲方实测踩到）：他把 speed 设成 1 期望"清掉小碎片"，结果一个都没清 ——
	#    因为**静止的碎片 motion 恒为 0**（实测 speed = 1 / 0.5 / 0.1 / 0.01 / 0.001
	#    全都没清，见 tests/diag_debris_port.gd），**任何正阈值都拦得住躺在地上的碎块**。
	#    这个旋钮原本的语义是"清正在高速飞的灰尘"（挡子步尖峰），而"清躺着的碎块"
	#    是另一个需求 —— 用 0 表示"不看速度"就能表达它，且默认（质量也是 0）仍然全关。
	if debris_max_mass <= 0.0:
		return 0
	var keep := _interactive_bodies()
	var removed := 0
	for i in range(bodies.size() - 1, -1, -1):
		var b: PBody = bodies[i]
		if b.is_static or b.frozen or b.mass > debris_max_mass:
			continue
		# ⚠️ 判据用 **_motion_of**（线速度 + |角速度| x 外接半径），与子步估计**同一个度量**。
		#    只看线速度会漏掉质量放大的那个通道：Δω = J·r/I，而 **I ∝ m** ——
		#    同一个力矩，轻 100 倍的碎片角速度大 100 倍，而子步估计里有一项
		#    |ω| x 半径。既然闸门的目标是"别让它拖慢世界"，判据就得和那个度量对齐。
		if debris_min_speed > 0.0 and _motion_of(b) < debris_min_speed:
			continue
		if keep.has(b):
			continue
		remove_body(b)
		removed += 1
	return removed


## 碎块数量上限：超出时淘汰最小、且已休眠、且没被抓的碎片。
## 没有这道闸门，连续擦除地形几分钟就会积累上千个刚体。
func enforce_body_budget() -> int:
	var count := 0
	for b in bodies:
		if not b.is_static:
			count += 1
	if count <= max_dynamic_bodies:
		return 0
	var held := {}
	for g in grabs:
		if g.body != null:
			held[g.body.id] = true
	var candidates: Array = []
	for b2 in bodies:
		# ⚠️ 冻着的碎片**不淘汰**：它是被故意停在那儿的（相机外），不是没人要的野碎片。
		if b2.is_static or b2.awake or b2.frozen or held.has(b2.id):
			continue
		candidates.append(b2)
	candidates.sort_custom(func(x: PBody, y: PBody) -> bool:
		return x.mass < y.mass)
	var removed := 0
	for b3: PBody in candidates:
		if count - removed <= max_dynamic_bodies:
			break
		remove_body(b3)
		removed += 1
	return removed


## **摘除**：damage 命中的像素变成**碎片**（新刚体），**体素个数守恒**。
##
## ⚠️ 与 fracture 的分工（这是设计决定，不是实现细节）：
##   · fracture = "挖掉" —— 命中的像素**消失**，只有**断开**的块变成碎片；
##   · detach   = "摘下来" —— 命中的像素**自己变成碎片**，总数不变。
##   笔刷擦除用 fracture（擦掉就是擦掉）；撞击/切断用 detach（Teardown 那样，碎块留下来）。
##
## ⚠️ 顺序不能反：必须**先** extract（此时像素还在），**再** fracture（它会把像素删掉）。
##    反过来就什么都捡不到了。
func detach(body: PBody, damage) -> Array:
	# ① 先捡：把"将被命中"的像素收集出来
	var extracted: Array = []
	for s in body.shapes:
		var ex := Destruction.extract_damage(s, damage)
		if ex.pixel_count() > 0:
			extracted.append(ex)
	# ② 挖：**从同一个集合里删**，而不是再让 fracture 自己判一次。
	#
	# ⚠️⚠️ 这是守恒能成立的关键，也是我踩过的坑：
	#    fracture 内部会**重算一遍**伤害判据，而任何两次独立计算都会在边界上差一点
	#    （实测：extract 捡到 113 个像素，fracture 只删了 112 个 -> 总数 1601，多 1）。
	#    想靠"让两边的边界行为一致"来修是死路（我先试了按 chunk 对齐，反而捡到 464 个）。
	#    正解是**只算一次**：extract 出来的集合就是被摘下来的集合，
	#    碎片从它来、洞也从它来 -> 守恒是**恒等式**，不是需要验证的性质。
	# ② **先**判"这一笔贴不贴边界"，再删 —— 顺序是判据能不能成立的全部。
	#
	# ⚠️⚠️ 这个坑 fracture 那边早就记过（见它里面"判据必须在 apply_damage **之前**取"），
	#    而 detach 一直是**删完再判**：挖出来的洞，边缘像素天然邻接空像素 ->
	#    touches_boundary 恒为 true -> "内部摘除不用查连通性"这条早退**从来没生效过**。
	#    实测（tests/validation_local_repaint.gd / 探针）：内部摘 20x20，
	#    touches_boundary=true -> 走 ensure_connected -> split 把形状**换成新对象**
	#    （新对象的脏集合是"整块都是新的"）-> 渲染器整张贴图重画（768x100 约 52 ms）。
	#    改成删除之前判之后：内部摘除走 else 分支 -> 原对象 + 按 shape 的脏矩形 ->
	#    只重建 1~2/24 块、0.2~0.4 ms，而且省掉一趟全量连通分量标注。
	#
	# ⚠️ 探测框要覆盖**实际被摘下来的范围**，不能只用 dmg_rect：extract 是按 chunk
	#    对齐拷贝的，它的包围盒可能比伤害大一圈（最多 7 像素）。判漏的后果是
	#    "该 split 却没 split"（形状数据断了、rects 没重算 -> 画面与碰撞体不一致）。
	#    宁可多查，不能漏判。
	var dmg_bounds: Rect2 = damage.bounds()
	var dmg_rect := Rect2i(
		floori(dmg_bounds.position.x), floori(dmg_bounds.position.y),
		ceili(dmg_bounds.size.x) + 1, ceili(dmg_bounds.size.y) + 1)
	var probe := Rect2i(dmg_rect.position - Vector2i(2, 2), dmg_rect.size + Vector2i(4, 4))
	for ex0 in extracted:
		probe = probe.merge((ex0.local_aabb() as Rect2i).grow(2))
	var was_boundary := false
	for s in body.shapes:
		if Destruction.touches_boundary(s, probe):
			was_boundary = true
			break
	# ③ 挖：**从同一个集合里删**，而不是再让 fracture 自己判一次。
	#
	# ⚠️⚠️ 这是守恒能成立的关键，也是我踩过的坑：
	#    fracture 内部会**重算一遍**伤害判据，而任何两次独立计算都会在边界上差一点
	#    （实测：extract 捡到 113 个像素，fracture 只删了 112 个 -> 总数 1601，多 1）。
	#    想靠"让两边的边界行为一致"来修是死路（我先试了按 chunk 对齐，反而捡到 464 个）。
	#    正解是**只算一次**：extract 出来的集合就是被摘下来的集合，
	#    碎片从它来、洞也从它来 -> 守恒是**恒等式**，不是需要验证的性质。
	var out: Array = []
	for s in body.shapes:
		for ex in extracted:
			var bb: Rect2i = ex.local_aabb()
			for y in range(bb.position.y, bb.position.y + bb.size.y + 1):
				for x in range(bb.position.x, bb.position.x + bb.size.x + 1):
					if ex.get_pixel(x, y) != 0 and s.get_pixel(x, y) != 0:
						s.clear_pixel(x, y)
	# ⚠️ 这里**不要**自己调 body.rebuild()：
	#   · 它的参数从 PWorld 里来（density_callable() / friction_callable() /
	#     restitution_callable() / max_rects_per_shape）；
	#   · 而且 ensure_connected() 内部已经用正确的参数 rebuild 了；
	#   · 脏标记也是 PBody.rebuild() 里统一做的（见它的注释），不需要手动标。
	#   （我第一版写了 body.rebuild() -> "Too few arguments"，白跑一轮。）
	if was_boundary:
		# ⚠️ 先试**便宜且可证明**的局部判据（与 fracture 那条同源，见 Destruction.local_connectivity）：
		#    "贴着边界挖个小洞"以前一律跑全量连通分量标注（768x100 实测 13.5 ms），
		#    而那一笔本身只要几毫秒。判不出来才退回全量 —— **宁可慢，不能错**。
		#    ⚠️ 只在**单 shape** 上走这条：局部判据一次只回答一个 shape；多 shape 时
		#    各自坐标系不同，保守退回 ensure_connected（它逐个 shape 处理）。
		var lc := Destruction.LOCAL_UNKNOWN
		if body.shapes.size() == 1:
			lc = Destruction.local_connectivity(body.shapes[0], dmg_rect, min_fragment_pixels)
		if lc == Destruction.LOCAL_CONNECTED:
			# 证明还连通 -> 不分裂、原对象、按 shape 的脏矩形 -> 只重画脏块
			body.rebuild(body.shapes, density_callable(), max_rects_per_shape, dmg_rect,
				friction_callable(), restitution_callable())
		else:
			# 断开的连通分量各自成体（引擎本来就有的机制）
			# ⚠️ 把伤害范围传下去：不然渲染器判 untracked -> 整张贴图重画（768x100 约 44 ms）
			out.append_array(ensure_connected(body, min_fragment_pixels, dmg_rect))
	else:
		# 没碰边界 -> 一定没断 -> 只重建（形状数据 + 质量/碰撞体 + 脏标记）
		# ⚠️ 三个 Callable + dmg_rect 都要传：见 PBody.rebuild 的说明（不传 = 母体变轻变滑）
		body.rebuild(body.shapes, density_callable(), max_rects_per_shape, dmg_rect,
			friction_callable(), restitution_callable())
	# ⚠️⚠️ 这里曾经有一段"按结果对齐"的修正：遍历 extract 捡到的像素，
	#    凡**仍然留在原刚体里**的就从碎片里去掉。**已删除** —— 它是错的：
	#    fracture 会 rebuild/平移形状的局部坐标（split -> _assemble），
	#    于是"这个坐标上原刚体还有没有像素"在 fracture 之后**问的不是同一件事**，
	#    结果把碎片像素全清空了（症状：detach 的刚体数始终是 1，碎片生不出来，
	#    而且**没有任何报错** —— 因为空碎片被 pixel_count() <= 0 跳过了）。
	#    正确的修法在源头：extract_damage 的拷贝范围**按 chunk 对齐**，
	#    于是它捡到的和 apply_damage 删掉的**精确相等**，不需要事后对齐。
	# ③ 把捡到的像素切成碎片（连通分量各自成体）
	var lv := body.linear_velocity
	var av := body.angular_velocity
	var pos := body.position
	var rot := body.rotation
	for ex in extracted:
		for piece in Destruction.split(ex, min_fragment_pixels, true):
			if piece.pixel_count() <= 0:
				continue
			var nb := PBody.new()
			nb.position = pos
			nb.rotation = rot
			nb.linear_velocity = lv
			nb.angular_velocity = av
			add_body(nb, [piece], Callable(), true)
			out.append(nb)
	return out


## **批量像素破坏**（接口请求）：按显式删除掩码一次性破坏。
##
## ⚠️ 三个破坏原语的分工：
##   · fracture(body, damage)          —— 按几何伤害**挖掉**（笔刷擦除）
##   · detach(body, damage)            —— 按几何伤害**摘下来**（像素变碎片，体素守恒）
##   · fracture_pixels(body, removals) —— 按**显式像素掩码**破坏（游戏层自己算好了删除计划）
##
## ⚠️ 四条契约（接口请求里写死的，改动前先读）：
##   1. **一次应用所有掩码，再分裂一次** —— 不要每个 shape 各分一次（断杆会被分多次）；
##   2. 同像素不会重复删除（掩码是 Dictionary，天然去重；且只在 get_pixel != 0 时计数）；
##   3. 只动 body **自己**的 shape（removals 里不属于它的键直接忽略，不串删）；
##   4. **不能**用"凸伤害严格在内部就一定不断裂"的优化 —— 掩码是任意的，内部也可能断。
##
## ⚠️ 速度场继承（与 fracture 的"原样拷贝"不同，这是本接口的要求）：
##    存活原块和新碎片都按刚体运动学继承删除**前**的速度场：
##        v_new = v_old + omega x (com_new - com_old)
##    角速度直接继承。被删掉的像素和剔除的最小碎片**带着自己的动量离开模拟**，
##    不补偿给存活块（所以总动量会少一点 —— 这是有意的）。
##
## removals / static_anchors = {PixelShape: {Vector2i: true}}，坐标都是该 shape 的局部像素坐标。
## static_anchors 非空时，钉子决定分片是否静态；大小只决定哪个分片继承原 body。
## 返回 {removed: int, body_alive: bool, fragments: Array}。
func fracture_pixels(body: PBody, removals: Dictionary, burst_speed: float = 0.0,
		dynamic_fragments: bool = false, static_anchors: Dictionary = {}) -> Dictionary:
	# ① 删除**前**的速度场与质心（下面要用它给存活块和碎片定速度）
	var old_com := body.com_world()
	var v_old := body.linear_velocity
	var w_old := body.angular_velocity
	var original_static: bool = body.is_static
	var anchor_mode: bool = not static_anchors.is_empty()

	# ② 删除：只动 body 自己的 shape，只删掩码里列出的像素
	#
	# ⚠️ 顺手算**每个 shape 的删除包围盒**（+1 余量，与 fracture 的 dmg_rect 同口径）——
	#    它下面要交给 rebuild 当脏范围。不传的话 rebuild 走 touch()（"不知道改了哪里"），
	#    渲染器判 untracked -> 该刚体**所有**贴图块重画（768x100 实测 44 ms/笔），
	#    而删除掩码本来就带着范围信息（clear_pixel 也已经逐块记过脏）。
	var removed := 0
	var dirty := {}
	# ⚠️ 同时收集**被改到的块键** —— 交给 rebuild -> MassProps 只重算这些块。
	#    没有它的话，删 1 个像素也要把整个形状重扫一遍（实测 800x40 = 2.95 ms）。
	var changed_chunks := {}
	for s in body.shapes:
		var mask: Dictionary = removals.get(s, {})
		if mask.is_empty():
			continue
		var x0 := 1 << 30
		var y0 := 1 << 30
		var x1 := -(1 << 30)
		var y1 := -(1 << 30)
		for px in mask:
			var p: Vector2i = px
			if s.get_pixel(p.x, p.y) != 0:
				s.clear_pixel(p.x, p.y)
				removed += 1
			changed_chunks[PixelShape.make_key(p.x >> 3, p.y >> 3)] = true
			x0 = mini(x0, p.x)
			y0 = mini(y0, p.y)
			x1 = maxi(x1, p.x)
			y1 = maxi(y1, p.y)
		if x1 >= x0:
			dirty[s] = Rect2i(x0, y0, x1 - x0 + 2, y1 - y0 + 2)

	if removed == 0:
		return {"removed": 0, "body_alive": true, "fragments": [], "downgraded": []}

	# ③ 分裂：默认最大块留在原 body；有钉子时优先保留最大的含钉子块。
	var kept: Array = []
	var kept_anchored: bool = false
	var loose: Array = []
	for s in body.shapes:
		# ⚠️⚠️ 被删光的 shape **不能留下**：split() 对空 shape 会返回 1 个空块，
		#    于是 kept 非空 -> 原体永远不会消失。实测：全删 1600 像素后
		#    body_alive 仍然是 true（闸门 ② 抓到的）。
		if s.pixel_count() <= 0:
			continue
		# 未改的形状不扫描；已证明局部仍连通时保留原对象。
		if not dirty.has(s):
			kept.append(s)
			kept_anchored = kept_anchored or _has_static_anchor(s, static_anchors.get(s, {}))
			continue
		var connected: bool = Destruction.local_connectivity(s, dirty[s], min_fragment_pixels) == Destruction.LOCAL_CONNECTED
		var parts: Array = [s] if connected else Destruction.split(s, min_fragment_pixels, true)
		if parts.size() <= 1:
			kept.append(s)
			kept_anchored = kept_anchored or _has_static_anchor(s, static_anchors.get(s, {}))
			continue
		var anchors: Dictionary = static_anchors.get(s, {})
		var anchored: Array = []
		var best := -1
		var best_n := -1
		for i in parts.size():
			var cnt: int = parts[i].pixel_count()
			var has_anchor: bool = _has_static_anchor(parts[i], anchors)
			anchored.append(has_anchor)
			if best < 0 or (has_anchor and not anchored[best]) or (has_anchor == anchored[best] and cnt > best_n):
				best_n = cnt
				best = i
		kept.append(parts[best])
		kept_anchored = kept_anchored or anchored[best]
		for i2 in parts.size():
			if i2 != best:
				loose.append({"shape": parts[i2], "anchored": anchored[i2]})

	# ④ 全删光 -> 原体消失
	if kept.is_empty():
		remove_body(body)
		return {"removed": removed, "body_alive": false, "fragments": [], "downgraded": []}

	# ⑤ 原体重建 + 按**新质心**修正速度（质心动了，速度场要跟着走）
	#
	# ⚠️ dirty 是**按 shape** 的（键是删除时那些旧 shape 对象）：split 产出的新 shape
	#    查不到 -> 回落空 dirty_rect -> touch() -> 保守全量（新 shape 本来就整块是新的）。
	#    单 shape、内部挖洞这条常见路径（split 返回原对象）因此只重建脏块。
	# ⚠️ 三个 Callable 都要传：不传 -> 母体质量按"像素数"算错、摩擦/恢复被清成 0。
	if anchor_mode:
		body.is_static = kept_anchored
	# ⚠️⚠️ 断出碎片时**不能**传 changed_chunks：split(adopt=true) 会把 PixelChunk **对象**
	#    搬到新 shape 上 —— 块键还是那些键，但内容已经不是缓存里记的那份了 ✗
	#    （闸门"甜甜圈：质量属性仍然逐位正确"当场抓到）。这时退回全量重算。
	var hint: Variant = changed_chunks if loose.is_empty() else null
	body.rebuild(kept, density_callable(), max_rects_per_shape, Rect2i(),
		friction_callable(), restitution_callable(), dirty, hint)
	var r_keep := body.com_world() - old_com
	body.linear_velocity = v_old + w_old * Vector2(-r_keep.y, r_keep.x)
	body.angular_velocity = w_old
	body.awake = true
	body.sleep_timer = 0.0

	# ⑥ 碎片各自成体，同样继承速度场
	var spawned: Array = []
	# 【档 C-3】没进物理的那些（见 min_fragment_thickness）。
	var downgraded: Array = []
	for entry in loose:
		var piece = entry.shape
		var frag := PBody.new()
		frag.position = body.position
		frag.rotation = body.rotation
		frag.is_static = entry.anchored if anchor_mode else original_static and not dynamic_fragments
		frag.collision_layer = body.collision_layer
		frag.collision_mask = body.collision_mask
		frag.gravity_scale = body.gravity_scale
		frag.awake = body.awake
		add_body(frag, [piece], Callable(), true)
		# 【档 C-3】太薄的碎片**不进物理**：像素原样交回调用方（result.downgraded），
		#    由美术层降级处理。理由见 min_fragment_thickness 的说明。
		#
		#    ⚠️⚠️ 判据是 **visible_short_side()（外接盒短边）**，不是 thinnest_extent()。
		#    这里我犯过一次错，代价是玩家直接看见「碎片消失」，所以记下来：
		#      第一版用的是 piece.local_aabb()（外接盒）—— 对，但是理由写错了；
		#      然后我为了「梳子形碎片」把它改成 thinnest_extent()—— **那是错的**：
		#      贪心分解沿**斜边**必然切出 1 像素宽的矩形，于是一块**斜切的大方块**
		#      thinnest = 1 -> 整块被降级。实测：435 像素 / 外接盒 29x29 的碎片
		#      被判成灰尘。而斜切在真实破坏里是最常见的形状（爆炸、擦除、裂纹）。
		#    两个量的语义不同：**厚度决定能不能钻过去，外接盒决定看不看得见**。
		#    灰尘判据要的是后者。thinnest_extent() 留给 CCD（PBody.needs_ccd）。
		# 两个触发器取并集：太薄（会穿墙）**或**太小（不值得一个刚体）。
		# 判据与理由见 min_fragment_thickness / min_fragment_pixels_downgrade 的说明。
		var too_thin: bool = min_fragment_thickness > 0.0 \
			and frag.visible_short_side() < min_fragment_thickness
		var too_small: bool = min_fragment_pixels_downgrade > 0 \
			and piece.pixel_count() < min_fragment_pixels_downgrade
		if too_thin or too_small:
			var dx := frag.position
			var dr := frag.rotation
			remove_body(frag)
			downgraded.append({"shape": piece, "position": dx, "rotation": dr})
			continue
		var r := frag.com_world() - old_com
		frag.linear_velocity = v_old + w_old * Vector2(-r.y, r.x)
		frag.angular_velocity = w_old
		if burst_speed > 0.0 and r.length() > 1e-6:
			# 可选的爆炸速度：从**原质心**向外。默认 0 = 不加（契约要求默认不产生爆炸速度）
			frag.linear_velocity += r.normalized() * burst_speed
		spawned.append(frag)
	return {"removed": removed, "body_alive": true, "fragments": spawned, "downgraded": downgraded}


## 分裂已经算完连通分量；这里只做钉子坐标的块查询，不再跑 flood fill。
func _has_static_anchor(shape, anchors: Dictionary) -> bool:
	for point: Vector2i in anchors:
		if shape.get_pixel(point.x, point.y) != 0:
			return true
	return false
