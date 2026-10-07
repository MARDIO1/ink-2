# CCD 与小碎片 —— 调研 + 本项目实测诊断

> 一句话结论：本项目原来的"CCD"**不是逐体扫掠，而是"按全世界最快刚体的位移，把整个世界重跑 N 遍"**。
> 代价 = **子步数 × 全世界矩形数**，两个乘数都只跟**一个**最快的刚体有关，跟碎片数量无关。
> 实测（876 矩形，真实地图规模）：**一个 2x2 的碎片以 40000 px/s 飞过，一次固定步 = 593 ms。**
> 抓着东西时更糟：迟滞把子步钉在 77，世界 2318 矩形 -> **一次固定步 768 ms**。
>
> 这不是"CCD 太慢"，是**用错了 CCD 的形态**。业界五个引擎没有一个这么做（见 §1）。
>
> **已修复（§5）**：现在**不做全局子步**，防穿交给**逐体 CCD**。同样的用例（4 像素薄墙 +
> 12x12 块、20000 px/s）：原来要 167 个子步才挡住，现在 **1 个子步**就挡住，而且结果更干净
> （x=188.0 vs 188.1）。关键那一步是打开 `rp_soft_ccd_prediction` —— 它从来没被设过，
> 默认 0.0 等于逐体 CCD 半关。

---

## 0. 现状速览

| 项 | 值 | 出处 |
| --- | --- | --- |
| 游戏侧 CCD | **开着**，而且**不做全局子步**（`ccd_per_body_only`） | `map/src/collision_damage.gd` 的 `_start()` |
| 历史 | 曾因"拿穿模换帧时间"关掉（commit `0ae371c`）；根因修掉后恢复 | §5 |
| 子步上限（声明） | `ccd_max_substeps = 16` —— **死声明，无人读** | `addons/pixel_destruction/physics/pworld.gd:99` |
| 子步上限（实际） | `ccd_substep_budget = 600` | 同上 `:103`、`:1668` |
| 每子步位移上限 | `ccd_max_motion = 2.0` 世界单位 | 同上 `:98` |
| 轻碎片豁免 | `ccd_ignore_mass = 100.0`（场景） | `map/main.tscn:25` |
| 灰尘闸门 | `debris_max_mass = 20` / `debris_min_speed = 20` | `map/main.tscn:27-28` |
| 线速度上限 | `max_linear_velocity = 1000`（Rapier 侧） | `map/main.tscn:23` |
| 角速度上限 | `max_angular_velocity = 60` rad/s（引擎侧钳） | `map/main.tscn:24` |
| 最小碎片像素 | `min_fragment_pixels = 5` | `map/main.tscn:26` |

---

## 1. 调研：体素破坏游戏与物理引擎怎么处理小型碎片

> 完整的逐条取证（每条带 URL、区分"已核实/我的推断"）见
> [调研-体素破坏引擎的小碎片处理.md](调研-体素破坏引擎的小碎片处理.md)。
> 本节只留结论与关键引文。

### 1.1 共识一：CCD 是**逐体**的，判据是**尺寸**而不是速度

五个引擎用的是同一个形状的判据 —— `每步运动 > k x 物体自身最薄尺寸`，`k = 0.5`：

| 引擎 | 判据 | 出处 |
| --- | --- | --- |
| Rapier | `max_point_velocity * dt > FAST_BODY_SAFETY_FACTOR(0.5) * ccd_thickness` | `rigid_body_components.rs` 的 `is_moving_fast` |
| Box2D v3 | `maxMotion > safetyFactor * sim->minExtent`，`safetyFactor` 默认 0.5 | `src/solver.c` / `include/box2d/types.h` |
| Bullet | `setCcdMotionThreshold`（默认 0 = 关）+ `setCcdSweptSphereRadius` | `btCollisionObject.h` |
| Jolt | `EMotionQuality::Discrete`（默认）vs `LinearCast` | `Jolt/Physics/Body/MotionQuality.h` |
| PhysX | 三道 opt-in：场景 flag + pair flag + 刚体 flag | PhysX 5.4 Advanced Collision Detection |

**这个判据对碎片是反向的**：物体越小，变成"快体"所需的速度越低。
60 Hz 下阈值是 `v > 30 x 最薄尺寸` —— 1 体素的碎片只要 **3 m/s** 就永久满足"需要 CCD"。
PhysX 把这写成了一条明确的失败模式警告（原文）：

> "**However, this artefact can become noticeable if you simulate an object that is sufficiently small/thin
> relative to the simulation time-step that the object could tunnel if it was accelerated by gravity from rest
> for 1 frame, i.e. a paper-thin rigid body. Such an object would always be moving at above its CCD velocity
> threshold and could result in a large proportion of simulation time being dropped for that object and any
> objects in the same island as it (any objects whose bounds overlap the bounds of that object). This could
> cause a noticeable slow-down/stuttering effect caused by the objects in that island becoming noticeably
> out-of-sync with the rest of the simulation. It is therefore recommended that paper-thin/tiny objects
> should be avoided if possible.**"
> — PhysX 5.4, *Advanced Collision Detection -> Limitations*

**"and any objects in the same island as it"** —— 代价不止是那个小物体，是它所在的整个岛。碎片堆正好就是这个岛。

### 1.2 共识二：**没有一家**用"全局自适应子步"防穿

两个带"substep"字样的旋钮，都是**每体扫掠次数**，不是"把世界重跑几遍"：

- Rapier `max_ccd_substeps` **默认 1**，且它是**全局 CCD 总开关**（0 = 全世界关）。
  文档原文："Larger values let a body resolve several successive impacts within a single timestep,
  **at the cost of additional sweeps**."
- PhysX `ccdMaxPasses` **默认 1**。"Increasing this value permits the CCD to run multiple passes...
  **can increase the cost of the CCD**."

**TGS 子步是另一回事**（Box2D v3 的 "Soft Step"、Teardown 新引擎的 "substepping instead of solver
iteration"）—— 那是**收敛性/稳定性**技术，不是防穿，而且：

1. 步数是**固定的小常数**（Catto 的基准用 4），**不按最快物体自适应**；
2. **它不重算宽相与接触点** —— 这正是它便宜的原因。Catto 原文：

> "On the other hand what is interesting is the idea that we can do sub-stepping **without updating the
> broad-phase or recomputing the contact points**. It turns out with a little bit of vector algebra we can
> update contact points by storing them in local coordinates... **It would be very expensive to recompute the
> contact points every sub-step, so contact point updating has made sub-stepping a viable approach.**"
> — Erin Catto, *Solver2D*, 2024-02-05

**本项目走的是 Catto 明说"非常贵"的那一种**：`pworld.gd:1734` 的 `for i in n: _substep_rapier(dt/n)`
每子步都调一次 Rapier 的完整管线（宽相 / 窄相 / 求解 / 休眠）。
所以引擎注释里"也是 Dennis 新引擎的思路（sub-stepping instead of solver iterations）"这句**引用是错位的**：
Dennis 的是固定步数、不重算接触的求解器子步；这里是**自适应、无上限、每步重跑全管线**。

### 1.3 共识三：1~3 体素的碎片，业界**根本不按刚体认真模拟**

| 项目 | 做法 |
| --- | --- |
| **Teardown** | 有**最小碎片尺寸**，低于它直接删。第三方 mod *Small Debris Retainer* 的全部作用就是取消这个上限，其说明反向证实了这一点："Small debris exceeding the established minimum will no longer be removed... **This mod is very demanding on performance with a large number of destructions**... An insane amount of small debris can very quickly reach the engine cover and **cause unstable physics**." |
| **Noita** | 像素是 falling-sand 元胞（64x64 chunk + dirty rect），刚体是**凸体**（box / circle / capsule）。**从不把散像素升格成刚体** —— 于是"微小高速刚体"这个问题压根不存在 |
| **roxlap**（Rust 体素破坏引擎） | 碎片降级成**极简物理**："bodies fall **world-vertically** with a terminal-speed clamp; the yaw spin is **cosmetic only** — collision always tests the **unrotated** world AABB... binary-searching the contact"。落地即碎成粒子（纯美术）。[debris.rs](https://docs.rs/roxlap-render/latest/src/roxlap_render/debris.rs.html) |
| **octo-release**（你给的那个仓库） | 只有二进制、无源码，README 自称 2024-08 的过时版本。changelog 里唯一相关的一条：`0.3.0: Created a rigidbody physics system with **connected component detection**` |

> ⚠️ octo-release 里**没有物理源码可读**；不要在结论里替它编实现细节。

### 1.4 可操作清单（按性价比）

| # | 做法 | 依据 |
| --- | --- | --- |
| 1 | **低于尺寸阈值的碎片直接删 / 变粒子**，不进物理 | Teardown 的最小碎片尺寸 |
| 2 | **碎片只跟静态世界碰**，碎片之间不碰 | Rapier 自动层只扫 fixed；Box2D 非 bullet 只查 static tree |
| 3 | **逐体碰撞层/掩码** | Teardown `SetShapeCollisionFilter`；本项目已有 `collision_layer/mask` |
| 4 | **CCD 判据按尺寸**，绝不做"世界级开关" | Rapier / Box2D 的 `0.5 x 最薄尺寸` |
| 5 | **钳速度让每步位移有界** | Rapier：`normalized_max_linear_velocity` —— "**Bounding per-step travel keeps CCD and speculative contacts reliable**"；角速度 "clamped each substep to ~45°/step" |
| 6 | **推测接触代替扫掠**（大多数情况够用） | PhysX speculative CCD；本项目已有 `max_speculative_margin = 1.5` |
| 7 | **真要防穿就自己 shape cast**，别指望 body CCD | Box2D："I do not recommend using them for game projectiles... **Instead consider using a ray or shape cast**" |
| 8 | **合并/重建连通分量** | Teardown `MergeShape`；本项目已有 `ensure_connected` |
| 9 | **整岛休眠 + 远处停用** | Jolt / Bullet；本项目已有 `_update_sleep` 与 `cull_freeze` |
| 10 | **只对"快体"并行做扫掠** | Rapier 两遍并行扫掠 |
| 11 | **不要用全局子步防穿** | 五家全不做 |

---

## 2. 本项目实测诊断

### 2.1 代码路径

```
collision_damage._step(delta)                     map/src/collision_damage.gd:149
  ├─ cull_fast_debris()                           pworld.gd:2868   灰尘闸门（先清）
  ├─ _compute_substeps(delta)                     pworld.gd:1653   决定切几刀
  │    ├─ _fastest_motion_plain()                 pworld.gd:1502   全世界最快的那**一个**
  │    │    └─ _motion_of(b)                      pworld.gd:1497   |v| + |w| x 外接半径
  │    └─ need = ceil(fastest * dt / ccd_max_motion)  夹到 ccd_substep_budget = 600
  └─ for i in count: _substep_rapier(delta/count) pworld.gd:943    **每子步重跑 Rapier 全管线**
```

### 2.2 五个乘数 / 放大器

**① 子步数是全局的，由"一个最快刚体"决定。**
`_fastest_motion_plain` 取的是 `max`，不是"各自算各自的"。一个碎片最快 → 全世界陪跑。
引擎自己的注释已经记过这条（`pworld.gd:106-108`）：

> "子步数取的是**全世界最快**的那个刚体，所以**一个** 2x2 的碎片就能拖慢全世界 —— 240 个碎片的场景里，
> 一个 2x2 碎片以 40000 px/s 飞行：子步 3 -> **334**，那一帧 **3.2 ms -> 346 ms**。"

**② 每子步重跑整条管线，代价 ~ 全世界矩形数。**
这是 Catto 说"非常贵"的那一种（§1.2）。子步数涨 100 倍 = 帧时间涨 100 倍，**而不是**涨"那一个碎片的 100 倍"。

**③ 角速度通道比线速度通道松 18 倍以上。**
`max_angular_velocity` 是**绝对 rad/s** 的上限，但子步估的是**表面速度** `|w| x 外接半径`。
`rp_max_linear_velocity = 1000` 只值 `ceil(1000/120) = 9` 子步；
而 60 rad/s x 300 px 半径 = **17860 px/s** → **151 子步**。
Rapier 自己在 CCD 组件上把角速度钳成 "~45°/step **to keep CCD reliable**"，本项目钳的是 rad/s —— 尺度错了。

**④ 速度写入绕过钳制，而子步估计在钳制之前读。**
`fracture_pixels` 给碎片的速度场继承（`pworld.gd:3192`）：

```gdscript
frag.linear_velocity = v_old + w_old * Vector2(-r.y, r.x)   # 无任何钳制
```

- `rp_max_linear_velocity` 是 **Rapier 内部**的钳制，发生在 step **之中**；
- `max_angular_velocity` 的钳制在**读回**时（`pworld.gd:1200-1201`），即 step **之后**；
- 而 `_compute_substeps` 读的是 **GDScript 侧镜像**，在**推送之前**。

于是"这一帧"用的是**未钳制**的值。实测：一根 300x40 的板以 w=60 自转，中间切一刀，
切下来的碎片运动 **9168 px/s** → **77 子步**，而母体已经不存在了。

**⑤ 抓取迟滞"只涨不落"，而 `grab_substep_cap` 压不住它。**

```gdscript
if not grabs.is_empty() and total_rects > 0:
    need = mini(need, grab_substep_cap(total_rects))   # 只压 need
if need >= _substeps_held or grabs.is_empty():
    _substeps_held = need                              # 从不因为 cap 变小而下降
return _substeps_held
```

实测：抓着东西时 `grab_substep_cap` 算出 **1**，但 `_substeps_held` 沿用抓取前被顶上去的值、
一路返回 **77**；把世界撑到 2318 矩形、cap 仍是 1，held 依然是 **77**
→ **一次固定步 768 ms**。
配合 `max_substeps = 4` 的追帧，一帧可以叠到几秒 —— 这就是"卡死"。

### 2.3 实测数据

复现脚本：[test/tools/bench_small_fragment_ccd.gd](../../test/tools/bench_small_fragment_ccd.gd)
（`godot --headless --path . --script res://test/tools/bench_small_fragment_ccd.gd`）

**（a）子步数 = 线性律，只由碎片自己的速度决定**（157 矩形，`ccd_ignore_mass=0` 以量纯代价）

| 2x2 碎片速度 | 每步位移 | 子步 | 整步 |
| --- | --- | --- | --- |
| 600 px/s | 10.0 px | 5 | 1.7 ms |
| 2000 px/s | 33.3 px | 17 | 2.7 ms |
| 5000 px/s | 83.3 px | 42 | 6.3 ms |
| 12000 px/s | 200 px | 100 | 15.9 ms |
| 24000 px/s | 400 px | 200 | 32.0 ms |
| 40000 px/s | 667 px | **334** | **51.0 ms** |

公式 `ceil(v/60/2)` 逐行吻合。

**（b）真实地图规模下的绝对值**（876 矩形，加了 18 个静态梳子模拟真实地图）

| 场景 | 子步 | 整步 | 每矩形每子步 |
| --- | --- | --- | --- |
| 2x2 @ 5000 px/s | 42 | **72.1 ms** | 1.96 us |
| 2x2 @ 20000 px/s | 167 | **306.8 ms** | 2.09 us |
| 2x2 @ 40000 px/s | 334 | **592.6 ms** | 2.02 us |

**（c）每子步代价随矩形数线性涨**（子步数固定）

| 矩形数 | 子步 | 每子步 |
| --- | --- | --- |
| 877 | 42 | 1.743 ms |
| 1037 | 9 | 2.610 ms |
| 1197 | 9 | 2.735 ms |

**（d）角速度通道**（w = 场景上限 60 rad/s）

| 刚体 | 外接半径 | 表面速度 | 子步 | 整步 @876 矩形 | 整步 @157 矩形 |
| --- | --- | --- | --- | --- | --- |
| 120x30 | 61.8 | 3674 px/s | 31 | **94.6 ms** | 5.2 ms |
| 300x40 | 151.3 | 8989 px/s | 76 | **230.2 ms** | 13.1 ms |
| 600x40 | 300.7 | 17860 px/s | 151 | （未测） | 24.4 ms |

对照：线速度上限 1000 px/s 只值 **9 子步**。

**（e）场景真实配置下**（`ccd_ignore_mass = 100`，灰尘闸门开）

| 碎片 | 质量 | 被豁免 | 子步 |
| --- | --- | --- | --- |
| 2x2 | 4.0 | 是 | 3 |
| 8x8 | 64.0 | 是 | 3 |
| **12x12** | **144.0** | **否** | **167** |
| 16x16 | 256.0 | 否 | 167 |

**质量豁免是一条很粗的线**：10x10 以下安全，12x12 以上直接进 167 子步。
而碎片质量 = 像素数 x 密度，密度随材质变（石头 2.5 / 金属 7.8）—— 同一个"看起来一样大"的碎片，
换个材质就跨过阈值。

**（f）抓取迟滞锁死**

| 步骤 | need（被 cap 压过） | `_substeps_held` 返回 |
| --- | --- | --- |
| 抓住 Box（1358 矩形，cap=1） | 1 | 77（沿用抓取前的值） |
| 删掉碎片后再算 | 1 | 77 |
| 世界撑到 2318 矩形（cap=1） | 1 | **77** → **768 ms/固定步** |

### 2.4 死声明清单（都不报错，只是静默失效）

| 声明 | 位置 | 状态 |
| --- | --- | --- |
| `ccd_max_substeps := 16` | `pworld.gd:99` | **无人读**。真实上限是 `ccd_substep_budget = 600`（差 37 倍） |
| `ccd_clamp_motion := true` | `pworld.gd:226` | 无人读（引擎注释自己记过） |
| `_ccd_saturated := false` | `pworld.gd:274` | 无人读、无人写 |
| **`PBody.ccd := false`** | `pbody.gd:70` | **无人读** —— 注释写着"Teardown 的 QueryShot 模型"，而 `sweep.gd`（精确 OBB 扫掠）已实现且 `validation_sweep` 14/14 通过。**正确的修法已经写好了，只是没接线** |
| `ccd_auto := true` | `pworld.gd:247` | 有读，但触发判据与子步阈值**正好错开**（引擎注释自陈"几乎不触发"） |

---

## 3. 结论与修法

### 3.1 根因（一句话）

**CCD 的问题是"局部的"，而本项目的解法是"全局的"。**
一个碎片的防穿需求，被翻译成了"全世界重跑 N 遍"，且 N 无上限、判据与物体尺寸无关、速度写入还绕过钳制。

### 3.2 三档修法

#### 档 A —— 游戏侧，最小改动，可逆（不动引擎）

1. **给子步数加真正的"时间预算"上限**（`collision_damage._step()` 里一行 `mini`）。
   直接封顶帧时间。代价：超高速物体穿模 —— 而**这正是现在 CCD 关着的状态**，所以不新增损失。
2. **把 `max_angular_velocity` 改成表面速度语义**：每步在 `_compute_substeps` **之前**，
   对每个刚体 `|w| * bounding_radius() > V_surface` 就钳 `w`。
   引擎对"睡眠"用的就是表面速度（`sleep_surface`），对 CCD 却用了裸 rad/s —— 同一个尺度问题。
3. **收紧 `ccd_ignore_mass` / `debris_max_mass`**：现有值已经在做这件事，但线太粗（见 2.3e）。
   注意 `debris_*` 会**删掉**碎片（破坏体素守恒），`ccd_ignore_mass` 只是**豁免**它。

#### 档 B —— 引擎侧，对齐业界（推荐，但动 addon）

1. **CCD 判据改成逐体、按尺寸**：`motion_of(b) * dt > 0.5 * b.thinnest_extent()`。
   Rapier 自己就有 `ccd_thickness`，Box2D 用 `minExtent` —— 本项目已有 `rects`，最薄矩形就是它。
   引擎注释 `pworld.gd:245` 已经写了这条待办："等根因 B 解决后，这里应当改成'按**物体自身尺寸**判定是否需要 CCD'"。
2. **全局子步改成"固定小步数 + 逐体扫掠"**：
   - 全局子步固定成小常数（TGS 风格，2~4），**不再按最快物体自适应**；
   - 真正需要防穿的那几个体，走 `PBody.ccd` + `sweep.gd` 的**逐体扫掠**（接线即可，旗子和原语都在）。
3. **把速度钳制挪到估计之前**：`fracture_pixels` 写完速度后立刻按 `rp_max_linear_velocity` 与
   表面速度角速度上限钳一次；`_compute_substeps` 读到钳制后的值。
4. **修掉迟滞**：`_substeps_held = mini(_substeps_held, grab_substep_cap(total_rects))`，
   或让 `grab_substep_cap` 作用于返回值而不只是 `need`。
5. **清掉死声明**（`ccd_max_substeps` / `ccd_clamp_motion` / `_ccd_saturated`），或把它们接上线。

#### 档 C —— 策略侧，对齐体素破坏游戏（治本，但要改玩法观感）

1. **低于尺寸阈值的碎片不进物理**：现在 `min_fragment_pixels = 5`，可以按"连通块的最薄尺寸"而不是
   "像素个数"来判（一个 1x20 的细条只有 20 像素但很薄，仍然会穿）。
2. **碎片只跟静态世界碰**（`collision_layer/mask` 已有）：碎片-碎片对是配对爆炸的主要来源，
   而且没人看得出两粒灰互不互撞。
3. **碎片降级成粒子/美术**（roxlap 路线）：落地即碎成纯表现粒子，不进求解器。
4. **碎片用合并代替新增刚体**（Teardown `MergeShape` 路线）。

### 3.3 建议顺序

1. 先做 **档 A-1**（时间预算封顶）—— 一行，立刻止住"个位帧数/卡死"，且不改变现有穿模口径；
2. 再做 **档 A-2**（角速度表面速度化）—— 掐掉最大的一条子步来源；
3. 然后评估 **档 B**（逐体 CCD + 固定子步）—— 这是唯一能"既开 CCD 又不掉帧"的路；
4. **档 C** 是长期方向，也最接近 Teardown / Noita / roxlap 的实际做法。

---

## 4. 复现与验证

```bash
# 帧时间 = 子步数 x 每子步代价，逐项量
godot --headless --path . --script res://test/tools/bench_small_fragment_ccd.gd
```

输出会打印：基准矩形数、基线子步与耗时、2x2 碎片的速度扫描、自转刚体的 |w|x r 扫描、
以及抓取迟滞的锁定过程。

相关文件：

- 引擎 CCD 配置与全部说明：`addons/pixel_destruction/physics/pworld.gd:92-274`
- 子步计算：`addons/pixel_destruction/physics/pworld.gd:1497-1692`
- 逐体扫掠原语（已实现、未接线）：`addons/pixel_destruction/physics/sweep.gd`
- 游戏侧步进驱动：`map/src/collision_damage.gd:149-189`
- 场景旋钮：`map/main.tscn:23-28`
- 详细取证报告：[调研-体素破坏引擎的小碎片处理.md](调研-体素破坏引擎的小碎片处理.md)

---

## 5. 实施记录（2026-10）—— 以及两个踩过的坑

档 A / B / C 都已落地并上了闸门（`test/test_ccd_debris.gd`，34 项断言）。
**最终形态和上面 §3 的计划不一样**，因为实测把两个判断推翻了。记在这里，
不然下一个人会照着 §3 再走一遍。

### 5.1 最终形态：**不做全局子步**

§3 的档 B 写的是「固定小步数 + 逐体扫掠」—— 方向对，但**还不够**：
固定 4 个子步仍然是把一个**全局**机制留给一个**局部**问题。
实测（4 像素薄墙 + 12x12 块、20000 px/s）：

| 配置 | 结果 | 峰值子步 |
| --- | --- | --- |
| 全局子步 + 逐体 CCD 软预测 0.0（引擎老默认） | 停在 x=188.1 | **167** |
| 全局子步上限 4 + 软预测 0.0 | 停在 x=188.6 | 4 |
| **不做全局子步** + 软预测 1.5 | 停在 x=188.0 | **1** |
| 不做全局子步 + Rapier CCD 全关 | x=3247，**穿过去** | 1 |

**167 个子步能做到的事，1 个子步做得更好。** 于是：

- 引擎新增 `ccd_per_body_only`（默认 false）：打开后子步恒为 1，
  上面那一整套「怎么算子步数」的旋钮全部不参与；
- 游戏把它打开，并留了回退路径（关掉就回到全局子步）。

### 5.2 坑一：**`rp_soft_ccd_prediction` 从来没被设过**（「CCD 好像没启用」的真相）

Rapier 的逐体 CCD 有两个旋钮，重要程度差一个数量级：

| 旋钮 | 作用 | Rapier 默认 |
| --- | --- | --- |
| `enable_ccd`（bullet 旗） | 要不要连**动态/运动学**目标一起扫 | false |
| **`soft_ccd_prediction`** | 推测 CCD 的**提前量** | **0.0 —— 等于半关** |

对静态世界那一层（自动扫掠）**不看** bullet 旗，由 `rp_ccd_substeps >= 1` 控制 ——
但**两层都吃这个提前量**。提前量是 0 时，逐体扫掠只能「正好撞上」才发现，
对一步跨几百像素的物体等于不起作用。

引擎注释早就写了这件事（`gdext/rapier_bridge/src/lib.rs`）：

> soft_ccd_prediction 是**推测 CCD**……默认 **0.0 意味着快物体没有任何提前量，
> 这正是穿模的来源**。

而游戏从来没设过它 —— 所以「CCD 开着」和「CCD 在工作」是两件事。
顺带一个观察：引擎自己的 `max_speculative_margin = 1.5` 是同一个概念的 GDScript 侧版本，
两边取同一个数量级（1.5 px）就对了。

### 5.3 坑二：拿 `thinnest_extent()` 判「是不是灰尘」→ **碎片直接消失**

碎片降级（档 C-3）要回答的是「这碎片**看不看得见**」，而我第一版用的是
`thinnest_extent()`（贪心分解出的**矩形**里最薄的那条）。

后果很刺眼：**贪心分解沿斜边必然切出 1 像素宽的矩形**，于是一块斜切的大方块
`thinnest = 1` → 整块被判成灰尘。实测：

```
【斜切角】**降级** 像素=435  外接盒=29x29  短边=29   <-- 被当成灰尘
```

**435 像素、29x29 的块被当成灰尘** —— 玩家看到的就是「碎片直接消失」。
而斜切恰恰是真实破坏里最常见的形状（爆炸 / 擦除 / 裂纹都出斜边）。

两个量的语义完全不同，必须分开：

| 量 | 含义 | 用在哪 |
| --- | --- | --- |
| `PBody.thinnest_extent()`（矩形里最薄那条） | **能不能穿过去** | CCD 判据（Rapier 的 `ccd_thickness` 同义） |
| `PBody.visible_short_side()`（外接盒短边） | **看不看得见** | 灰尘判据（降级 / 隔离） |

闸门里钉了回归用例（§7）：斜切块必须 `downgraded == 0`，
而且要断言 `thinnest < 2 且 visible > 20` —— 两个量必须**分开判**。

### 5.4 坑三（小）：灰尘渲染器的「每帧重试」注释和代码说的不是一件事

`debris_dust.gd` 第一版的注释写着「拿不到渲染器就每帧再试一次」，
代码却是「拿不到就把这一批直接丢掉」。而 `renderer` 是 `add_child.call_deferred`
加进树的，`_start()` 时大概率为 null —— 于是**灰尘一个都看不见**，
叠在坑二上就是「碎片凭空消失」。现在真的重试，且重试期间**不烧寿命**。

### 5.5 落地清单

| 层 | 文件 | 做了什么 |
| --- | --- | --- |
| 引擎 | `src/physics/pbody.gd` | `thinnest_extent()` / `visible_short_side()` / `needs_ccd()` |
| 引擎 | `src/physics/pworld.gd` | `ccd_per_body_only`；`ccd_max_substeps` 接回（曾是死声明）；`ccd_substep_cost_budget_us` / `ccd_min_driver_thickness` / `ccd_per_body` / `max_surface_speed`；`min_fragment_thickness` + `result.downgraded`；迟滞上限修死锁 |
| 引擎 | `src/render/pixel_renderer.gd` | `place_blueprint()` / `tint_blueprint()`（只动 transform，不重建贴图） |
| 游戏 | `map/src/collision_damage.gd` | `_clamp_speeds()` / `_apply_substep_budget()` / `_isolate_debris()`；CCD 配置；灰尘接线 |
| 游戏 | `map/src/debris_dust.gd` | 新增：降级碎片的短命灰尘层 |
| 闸门 | `test/test_ccd_debris.gd` | 34 项断言（含两条回归钉） |
| 证据 | `test/tools/bench_small_fragment_ccd.gd` | 帧时间 = 子步数 x 每子步代价，逐项量 |
