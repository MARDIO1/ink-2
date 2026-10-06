# 引擎 Request：本地 v0.3.8 补丁审查与碰撞几何优化

## 当前有效 Request（2026-10-06）

**状态：供用户审核与转交的草稿，未对外发送。当前游戏使用修改过的引擎和接口。** 后面的日期记录是历史排查证据，其中“没有修改 addon”等表述仅在当时成立。当前修改清单、调用契约和兼容风险以 [engine_local_changes_v038.md](engine_local_changes_v038.md) 为准。

### 基线、复现与影响

- 源码：`T:/GODOT/bag/Godot_2DVoxel_Addons`，官方 v0.3.8 `91dc1ec1f6f78f41c96469cdf576707794f12236` 加未提交本地补丁。
- 安装：`T:/GODOT/ink-2/addons/pixel_destruction`；本地修改需成套生成脚本、编译及安装两 DLL。
- 样本：`T:/GODOT/ink-2/test/canvas_capture.tres`，3770 实体像素、275 精确矩形、单连通 body。
- 测试：`test/profile_collision_damage.gd`，顺序运行 `--slam`、`--cut --live`；可用 `--no-damage`、`--no-debug`、`--no-hand` 分别复核。要使用同一 Godot、同一构建、同一场景和相同帧数，避免并行进程争 CPU。
- 上次 180 帧测量：slam 均值 0.795439 ms/P95 1.197 ms；cut 均值 1.47835 ms/P95 2.231 ms。断裂本次样本 API 6.216 ms、同步 3.153 ms。都是 CPU 测量段，不等于渲染 FPS。
- 风险：断裂与初次创建尖峰未全部解决；冻结引擎验证退出仍有资源泄漏报错。以下请求不能由“平均帧足够快”替代正确性验证。

### R1：提供明确的持续执行器输出契约

**涉及** `src/physics/pbody.gd` 字段/`clear_forces()`，`src/physics/pworld.gd::_substep_rapier()`。

本地增加 `control_force`、`control_torque`，默认零，每控制帧覆盖、每子步积分；最终与外力通道相加。目的：避免轻质量手在关节求解前吃到整帧冲量，触发虚高速度与大量全局 CCD 子步。

请求评审并提供正式接口，明确：输出何时清零、休眠/唤醒行为、`clear_forces()` 优先级、多执行器合成和冻结恢复语义。当前本地字段会持续生效、多个写入者互相覆盖，游戏必须负责停用归零。

**验收**：恒力跨不同子步数累计冲量一致；停止后无残留输出；外力不被执行器覆盖；手/身体等大反向控制保持线动量；连续抓地不抖、约束长度与功率限幅有效。

### R2：局部追加求解迭代与 ABI 能力查询

**涉及** `PBody.additional_solver_iterations` → `_substep_rapier()` → `gdext/fastphys.cpp` → `gdext/rapier_bridge/src/lib.rs::rb_body_set_solver_iterations()`。

本地协议新增 `42 + u32 body_id + u32 iterations`，默认零，通过 Rapier `set_additional_solver_iterations` 设置。40/41 保留给官方 v0.3.8 关节软度/世界求解参数。作用范围是连接约束岛，并非单个关节；当前手请求追加 32 次。

请求确认正式 opcode/接口，提供 ABI 版本或能力查询，并让不匹配的包在初始化时给出明确错误。现在没有协商，旧 DLL 不识别新命令，新入口 DLL 也要求桥接库包含新增导出。

本次静态审查发现需要修正的具体遗漏：原生 body 创建时没有把 `_rp_solver_iterations` 重置为 -1；同一个 PBody 移除后再次加入，可能因为旧缓存而漏推设置。请在创建路径统一重置同步缓存并补这个回归。本轮未修改该代码，不能把该生命周期场景列为已通过。

**验收**：默认零时兼容原场景；修改值立即生效；刚体创建/删除/重建/冻结恢复后无旧 id 缓存；在 Weld 与 Hinge、接触连成大岛时检查精度与开销；减少全局子步后仍满足 Weld 角度误差。评审合理上界，避免无界迭代拖死世界。

### R3：接触枚举避免重复扫描

**涉及** Rust `World::index_contacts()`、`rb_contact_count()`、`rb_contact_get_points()`。

现有逐 i 查询从头枚举接触对，整批查询产生 O(N²) 遍历。本地每步建立一次活跃对句柄索引，之后按句柄查询；step、remove body、set rects 标记失效。接口与点布局不变，额外内存 O(N)。优化的是查询，不是宣称碰撞检测降为 O(N)。

请求审查缓存失效位置并合入或提供官方一次性批量接触读取接口；若给批量接口，保留每个点自己的法向/切向冲量，不能让伤害按接触点数量重复放大。

**验收**：和原实现逐点对照 body id、法向、位置、法向/切向冲量、FID、容量查询；覆盖多流形、零接触、删除和复用句柄、形状重建、冻结恢复。以 10/100/1000 接触对测完整批查询，分别记录分配和遍历耗时。

### R4：将局部连通证明与碎片属性接入精确像素破坏

**涉及** `src/physics/pworld.gd::fracture_pixels()`，`src/core/destruction.gd::local_connectivity()`（后者算法本地未改）。

本地跳过未受损 shape；只有局部判据证明 `LOCAL_CONNECTED` 才跳过 split，未知回退全量。请明确“破坏前 shape 连通”的契约，并复核 `min_fragment_pixels`、完全删除、多 shape 和稀疏远距离删除的语义。

本地签名增加第四参数 `dynamic_fragments=false`：true 时静态体产生动态新碎片、原残块保持静态；新碎片先继承 layer/mask/gravity_scale。请求正式支持该行为，或给等价批量入口，使游戏不必在碎片创建后重复刷新质量和原生碰撞体。

**验收**：默认调用与原接口结果一致；动静态父体、多材料、layer/mask、摩擦/恢复、重力缩放、碎片质量与速度场继承；割断 1 px 颈部必须真分裂；不满足局部证明必须回退。不要用固定“若干帧不分裂”来掩盖计算。

### R5：可靠原生包与分阶段性能计时

**涉及** `tools/build_native.py::main()`、包生成安装说明；计时涉及 `PBody.rebuild()`、`PWorld._substep_rapier()` 与 Rust step。

本地将 MinGW 入口库改为 `-static`，避免部署漏 `libwinpthread` 导致加载错误 126。请求官方验证 Windows 发布包只依赖实际随包或系统可用 DLL，并明确使用方不得携带生成目录根 `.gdignore`。

请求公开稳定计时：CCD 子步决策、命令准备、原生宽相/窄相/求解/CCD、接触序列化、连通分量、质量/矩形重建、原生 Collider 重建、纹理与节点同步。既报告累计也报告每次调用最大值，关闭时不引入明显计时负担。这样才可比较“Demo 多碎片”和“本游戏大不规则物体+Joint”，不能只按碎块数解释性能。

**验收**：干净机器加载成功；源码与安装 DLL 哈希一致；重复冷启动与暖运行分开统计，保留最高尖峰，不排除首帧后宣称问题消失。

### R6：先实验单 compound Collider，内部保留精确矩形

**当前问题**：`gdext/rapier_bridge/src/lib.rs::rb_body_set_rects():173` 每矩形插入一个独立 cuboid Collider，同 body 样本有 275 Collider。矩形子形状很多时，宽相代理与接触管理成本可能偏高；该推断尚未做对照实验。

请求增加实验选项：同一 body 的原矩形组织为一个 compound Collider，优先保持 opcode 5 现有矩形载荷和 GDScript 玩法接口。比较代理、候选对、子形状检查、接触流形和实际 CPU 时间；内部子形状仍需检测，不能只依据 Collider 总数下降就认为优化成立。

**验收**：精确实体范围相同；质量/质心/惯量、摩擦/恢复、mask、Joint、CCD、接触冲量与坐标、重建删除生命周期保持；不填平孔洞，不膨胀碰撞，不加限速；真实样本抓举与断裂均对照。若无收益，不扩大实施。

### R7：多边形后端作为后续实验，不直接照搬旧容差

旧 `T:/GODOT/ink-fffight/ink/solid/ink_solid.gd::polygon_create():278` 使用 BitMap 提轮廓、epsilon 2～8，并取最大轮廓；这解释了几何较少的可能来源，但不能保证所有旧引擎版本如此，也不能证明穿模单由该算法导致。

请求在 R6 之后评估精确像素边界的凸分解/compound 后端。涉及：新增边界/孔洞提取与特征保护，`PBody.rebuild()` 的几何输出，`PWorld` 顶点协议，`fastphys.cpp` 解包，Rust 多边形 Collider 建立与重建。像素数据仍负责破坏、材料与抓取查询；Joint、控制器不需要因此另写一套。

**验收**：斜杆、梳齿、U 形凹槽、内部孔洞、1 px 颈部、旋转高速碰撞、双方薄结构互撞；几何简化后重新栅格核验边界；显式核对原生质量/质心/惯量与像素结果一致。保留矩形后端用于同轨迹 A/B，报告子形状/顶点数、生成时间、常态步进与断裂 P95/最大时间。禁止单凸包填槽、无保护 epsilon 2～8、关闭 CCD 或全局限速换性能。

### R8：2026-10-06 当前游戏实测——区分传输、包围盒与原生物理

用户转述引擎认为瓶颈是 GDScript 与内核通信。本次以当前安装版本、手部两倍力/功率和真实 `canvas_capture.tres` 复测，不能套用旧手写物理后端的 503 体计时结果。

**结论范围：当前 3770 像素/275 Collider 的抓举和断裂样本中，最大的单项是 GDScript 的矩形包围盒更新，不是跨语言边界。Rapier 管线也有明显占比，不能说其成本可以忽略。**

#### 方法与复现

- 仅新增 `T:/GODOT/ink-2/test/build_transport_probe.py`、扩展现有 `test/profile_collision_damage.gd`。生成副本位于 `test/transport_probe/`，根 `.gdignore` 隔离编辑器扫描。生产脚本、源引擎与安装 DLL 未修改、未重启用户编辑器。
- 复制当前 C++ 入口，注册独立类 `RapierTransportProbe`；仍加载与生产 SHA256 相同的 Rust/Rapier DLL，不改物理算法。仅在测试副本增加 opcode 43 读取并清零计时，不能将其当成发布接口。
- C++ 用纳秒时钟计完整回调，以及 `rb_world_step`（包含宽相、窄相、约束求解、CCD等）、矩形 Collider 重建、接触查询和状态读取。
- GDScript 副本计命令准备、包头/模板分配、原生调用墙钟、状态解码、最后的包围盒刷新。最后一项包含 `refresh_com()` 和所有动态体 `update_aabb()`；其主循环遍历每个矩形。
- 每项 3 次独立进程、顺序运行，各 180 固定帧，保留 CCD 与正常伤害。原版与计时版每组最终位置、速度、体数相同；计时版 slam 均值相对原版 -0.5%，cut +2.9%，在计时负担与运行波动范围内。
- 命令：先在游戏根 `python -X utf8 test/build_transport_probe.py`；然后 Godot `--headless --path T:/GODOT/ink-2 --script res://test/profile_collision_damage.gd -- --slam --transport`，断裂将 `--slam` 换为 `--cut`。原版对照去掉 `--transport`。
- 本轮 `--cut` 是固定步手动推进，包含真实删除与节点/贴图同步，不使用 `--live` 的额外自动帧调度。是 CPU 测量段，不是实际渲染 FPS。

#### 每测量帧平均成本（三次均值）

| 阶段 | 抓举/下砸 ms | 割断 ms |
|---|---:|---:|
| 整个测量段 | 1.867 | 2.654 |
| GDScript 包围盒/质心刷新 | **0.742（39.8%）** | **0.854（32.2%）** |
| Rapier 原生物理管线 | 0.419（22.5%） | 0.526（19.8%） |
| GDScript 命令准备 | 0.0966 | 0.1331 |
| GDScript 返回状态解码 | 0.0223 | 0.0344 |
| GDScript 包头和输出模板准备 | 0.0141 | 0.0257 |
| 跨语言边界额外成本估算 | **0.0046（0.25%）** | **0.0088（0.33%）** |
| 原生 Collider 重建 | 0.0012 | 0.0021 |
| 原生接触查询 | 0.0013 | 0.0035 |
| 原生状态读取 | 0.0019 | 0.0029 |

边界成本估算 = GDScript 测得的 `.cmd()` 总时间减 C++ 完整回调时间。微秒/纳秒时钟、计时语句和诊断查询会影响小项精度，适合判断数量级，不作几微秒的精确 ABI 保证。表中不是完整穷尽分解，剩余包含伤害、游戏侧接触构造/解码、同步、执行器和其他世界调度，不应直接全部记为“通信”。

即使把命令准备、模板和状态解码都宽泛归入传输，其占比仍约 7%～8%。当前抓举每测量帧约 9.2 次原生调用，cut 约 17.8 次；180 帧分别遍历 92349/105593 个矩形做游戏侧包围盒刷新。诊断统计包含一次最终计时读取，调用数量有一个查询的固定偏差。

#### 断裂瞬间与消融

- 真实割断删除 37 像素、生成 3 新碎片；计时版三次 fracture API 均值 **15.143 ms**、同步 **7.180 ms**，该帧总体约 24.6～24.9 ms。
- 副本上单独 split/mass/greedy 分别约 8.557/1.881/10.873 ms，用于算法归因，**不能与实际 fracture API 相加**，因为是重复运行的诊断副本。
- 临时跳过每子步最后的包围盒更新：slam 均值 1.867→1.065 ms，约减少 43%。但最终轨迹改变、子步数由 331→319，因此是**不等价诊断，禁止作为生产优化**。`bounding_radius()` 读取世界 AABB，过期 AABB 会影响 CCD 决策。
- 新增第 4 次 slam 测试确认 CCD 决策约 2.206 ms/180 帧，非主项；前三次原型的该计时只包围 `PWorld.step()`，游戏实际上由 `CollisionDamage._step()` 调用，得到的 0 不代表没有开销，已修正为计整个 `_compute_substeps()` 函数。
- 测试日志无 SCRIPT ERROR/ERROR/未知 opcode；已有 Camera2D 插值 warning 保留。

#### 请求引擎优先评估

热点路径：`src/physics/pworld.gd::_substep_rapier()` 最后的 `b6.update_aabb()` → `src/physics/pbody.gd::update_aabb()` → `_rect_world_aabb()`；当前复杂度约为每子步 O(动态体碰撞矩形总数)，旋转三角函数与方法调用重复执行。

优先测 **精确 AABB 的原生计算与批量状态回读**，或保持结果一致的姿态缓存/三角函数缓存。不得直接省掉刷新、换成过大的旋转矩形近似或放松 CCD。若扩展状态返回布局，需完整同步 GDScript/C++/Rust 与 ABI 能力协商，并验证世界 AABB、CCD 子步、碰撞轨迹和 1px 防穿。

其他并行请求仍有效：断裂的矩形生成与纹理同步是突发大项；接触批量读取可减少 GDScript 调用，但当前数据不支持把 DLL 边界本身列为第一优先级。

原始证据：`test/transport_baseline_1..3.log`、`transport_profile_1..4.log`、`transport_cut_baseline_1..3.log`、`transport_cut_profile_1..3.log`、`transport_no_aabb_1..3.log`；聚合数据 `test/transport_summary.json`。当前生产 DLL 哈希与修改说明中记录仍一致。

### 合入顺序建议

先评审 R1～R5 的实际本地补丁与兼容契约，再测 R6；R7 单独立项。尚未取得上游 API 承诺，本地补丁不能冒充已发布功能。本 Request 只提出改造与验收，不代表已实施 R6/R7，也没有改写碰撞算法。

---

## 历史证据：全局 CCD 子步与关节施力的性能问题

## 2026-10-06：安装启动修复与新版窗口复测

- 启动故障不是物理算法：上次安装将生成包根目录的`.gdignore`误复制到游戏，使Godot重新扫描后忽略整个addon，extension_list为空，RapierPhys未注册，后续Nil调用连续报错。删除游戏插件根的该文件，headless editor import重建extension_list，确认res://addons/pixel_destruction/fastphys.gdextension。后续安装必须排除根`.gdignore`，测试先重新扫描再运行正常主场景，不能仅依赖原有缓存下的脚本测试。
- 主场景PixelWorld脚本原UID在扫描后失效；移除main.tscn该一项外部脚本UID，保留固定res路径。没有修改游戏物理控制或生成addon算法。
- 正常主场景无头180帧和带窗口180帧验证成功；最终startup036_final.log没有SCRIPT ERROR、ERROR或invalid UID。现有Camera2D插值回调warning保留。仍运行中的用户旧编辑器/游戏没有强制终止。
- v0.3.6窗口测试同批各180固定步：slam均值4.327ms/P95 6.689ms/最大56.283ms，15子步；slam --no-sync最大20.866ms，损伤时原生2.793ms、提交10.623ms、节点同步0.045ms，对照正常同步35.345ms。no-damage均值3.200ms/最大8.123ms；--cut --live均值3.757ms/P95 7.203ms/最大56.718ms、13子步。
- 真实不规则形状cut删37像素生成3碎片；公开fracture_pixels13.298ms、补充refresh_mass1.390ms、同步5.923ms；独立split7.088ms、greedy7.117ms、mass1.319ms。主机负载/频率相较前轮变化，不用跨批绝对耗时断言新版退化或收益。当前接触优化不能消除整图重绘尖峰；优先级仍是局部脏范围+去重复rebuild，其次Joint全局步进调度。
- 日志：test/startup036_final.log、fixed036_slam.log、fixed036_slam_no-sync.log、fixed036_no-damage.log、fixed036_cut_live.log。

## 2026-10-05：F5 真实样本测量结果与优化 Request

### 后续复核：引擎接口与开关

核对本地引擎HEAD 7714886及v0.3.5发布说明、performance手册、源码实际调用。pworld/pbody/renderer/GPU脚本除打包路径重写外与本地源一致；PixelWorld还去除了class_name，差异也是打包处理。本轮未fetch远端，不能声称没有更新的远端版本；未重编译或覆盖引擎。源仓库两个DLL已存在修改，本轮没有触碰。

| 项目 | 当前实际值/入口 | 是否生效与成本 |
|---|---|---|
| contact_events_enabled | false | 生效；游戏contact_pair_count/contact_info无需开启事件 |
| rp_debug | false | 生效；_rp_send的协议调试输出关闭 |
| sleeping_enabled | true | 生效；关闭后每子步叫醒刚体，维持开启 |
| renderer.shading | false | 生效；逐像素着色关闭 |
| GPU破坏 | gpu_destruction.ENABLED=false | 编译常量，不是运行时Inspector开关；fracture_pixels本身直接走CPU split，不调用GPU破坏入口。当前Compatibility也无RenderingDevice |
| ccd_enabled | true | 生效；自适应全局子步与原生CCD均使用此值 |
| ccd_max_motion | 0.5 | hand._ready覆盖引擎默认2.0，放大全局子步成本 |
| ccd_substep_budget | 600 | 生效的全局上限；不是ccd_max_substeps=16 |
| ccd_grab_substep_cost_budget_us | 6000 | 仅world.grabs非空生效；游戏Joint抓握不覆盖 |
| rp_ccd_substeps / rp_soft_ccd_prediction | 1 / 0 | 生效；原生CCD内部次数/软CCD距离，不能与世界last_substeps混为一谈 |
| ccd_max_substeps、ccd_auto、ccd_clamp_motion、ccd_max_rotation | 16、true、true、0.25 | 当前整个已安装addon中只声明未读取；旧残留字段，不能靠切换它们优化 |
| fill_contact_impulses_enabled / profile_enabled | true / false | 当前addon仅声明，无读取；fill开着不等于每帧额外计算冲量，profile也不是可用分阶段计时接口 |
| auto_render | true | 常规动态同步开关；sync_world_bodies内部强制全量同步不读取此值 |

新增消融仅在原有test脚本：--inactive-off同时关闭三个残留bool；--engine-motion恢复2px步长；另使用既有--events。顺序各180步，新进程。此次主机整组耗时高于前轮，因此只比较同一组：baseline均值10.091ms/P95 16.534ms/52子步；inactive-off均值10.322ms/52子步，未改善；engine-motion均值3.639ms/P95 6.282ms/13子步；events均值24.473ms/P95 39.413ms。事件开销是逐子步_contact_width/_fill_contact_stress路径，并非当前默认开启。2px步长约快2.8倍，但接触峰值3变6、伤害/轨迹会变；未验收1px防穿、动量、稳定性，所以没有改入hand生产代码。CPU抖动不应解释为残留开关效果。

接口核对：contact_info一次公开调用内部发两次op35（先问数量，再取数据）；不要再同时调用contact_points重复取同一对。physics_step_finished仅PixelWorld自带固定步推进发出；当前游戏为匹配子步接触位姿在CollisionDamage接管步进，因此该信号不在当前游戏路径发出，不能直接替换现有每子步查询。fracture_pixels是精确掩码接口，游戏已使用；fracture_pixels_and_sync只是公开封装，不消除全量贴图成本。damage_circle/fracture/detach不能在不改变伤害形状或像素守恒规则的前提下互换。detach/fracture默认burst_speed=40，fracture_pixels默认0，不能为提速默默换成带爆炸速度的入口。

文档存在漂移：performance手册说可调ccd_max_substeps，但源码没有读取；介绍GPU“已实现”不等于默认开启，更不等于掩码破坏接通GPU；旧C++求解/宽相503体基准不能套在本游戏Rapier+Joint+52子步上。Request应包含残留开关清理、文档更新，以及公开真实阶段计时，不推荐加更多游戏补丁。

本轮日志：test/perf_switch_baseline.log、perf_switch_inactive-off.log、perf_switch_engine-motion.log、perf_switch_events.log。

样本 `T:/GODOT/ink-2/test/canvas_capture.tres`，3770实体像素、1个连通物体、275个精确碰撞矩形。没有改游戏、addon或伤害参数；仅扩展现有测试脚本计时。各进程顺序运行，避免并发争抢CPU。无头180固定步用于CPU消融，另跑带窗口的 `--cut --live` 验证实际回调路径；以下不是GPU整帧耗时/FPS。

### 测量

| 消融 | 平均CPU帧 ms | P95 ms | 最大 ms | 最大子步 |
|---|---:|---:|---:|---:|
| 抬举原样，最后复测 | 7.029 | 11.960 | 39.900 | 52 |
| 关闭调试采集/UI | 6.822 | 11.549 | 40.083 | 52 |
| 关闭常规渲染同步 | 7.093 | 11.769 | 40.760 | 52 |
| 关闭伤害，保留接触 | 6.680 | 12.212 | 13.242 | 52 |
| 再关闭游戏接触查询 | 5.803 | 10.733 | 12.750 | 52 |
| 关闭自适应CCD，仅诊断 | 0.355 | 0.414 | 2.018 | 1 |
| 原样下砸，带同步计时 | 8.165 | 12.945 | 39.312 | 55 |
| 下砸，跳过所有内部renderer.sync | 8.024 | 13.063 | 19.051 | 55 |

关闭伤害/CCD改变后续物理轨迹，不能当作等价修复。`--no-render` 仅关闭常规动态同步，公开 `sync_world_bodies()` 内部依然强制渲染；最后增加 `--no-sync` 测试子类跳过全部sync，节点映射和关节清理仍正常执行，解决消融漏项。

- 持续抬举：原生推送/求解/读回1036.220ms，占180帧总1265.266ms约82%；游戏接触查询85.856ms。峰值接触对3，因此接触索引O(P²)是扩展风险，不是这份样本主因。
- CCD源头：第一帧手PD后、关节求解前，手速1556.281px/s，抓取物体速度0；决定子步的最快体确实是手。0.5px步长产生52次全局求解。`world.grabs=0`、Joint=3，旧Grab预算未覆盖Joint；所有275个矩形随全局子步重复参与物理。
- 实际自然损伤峰值在第31/32帧：最新抬举39.900ms，其中原生6.914ms、提交6.949ms、世界同步20.928ms；底板800×40，renderer.sync单项20.489ms，13/13贴图全量重绘。下砸no-sync复现同样损伤帧，最大从39.312降到19.051ms，子步/接触峰值相同。此自然碰撞只产生损伤，未生成新碎片。
- 真正断裂单独验证：第60帧对真实不规则形状中线删37像素，原体留下最大块，新增3个碎片。带窗口实测：split独立诊断3.733ms、MassProps独立诊断0.780ms、GreedyRects独立诊断4.322ms；公开fracture_pixels总7.961ms、游戏补充refresh_mass0.856ms、sync_world_bodies3.454ms。断裂后第一物理帧2.612ms/6子步，后续5.694、2.704、7.128ms。独立诊断使用拷贝，各阶段缓存条件不同，不能把它们机械相加等同接口总耗时；诊断准备/独立测量不计入物理帧。
- 本样本没有复现秒级卡死。烘焙约22~23ms，独立于抬举/断裂。日志无脚本错误，有Godot已有Camera2D插值回调警告。

### 优先级1：局部损伤不能使整块底板贴图失效

引擎源 `T:/GODOT/bag/Godot_2DVoxel_Addons/src/physics/pworld.gd::fracture_pixels()`、`src/physics/pbody.gd::rebuild()`、`src/render/pixel_renderer.gd::sync()`。当前fracture_pixels调用rebuild未传dirty_rect，rebuild调用shape.touch；游戏refresh_mass再次rebuild并touch。全量失效使局部损伤扩展为13/13贴图重绘。

Request：批量掩码接口计算并传递每shape的真实脏范围；没有分裂/边界变化时保留未改区域贴图及缓存，质量刷新不应宣告像素内容变化。分裂后新body可初始化贴图，保留体按实际边界变化决定全量重绘。先保证视觉/碰撞一致，再验收局部损伤只重绘受影响tile。延迟白色裂缝方案也必须局部更新，否则仍付出整图重绘成本。

### 优先级2：Joint连通组与CCD调度

引擎源 `src/physics/pworld.gd::_compute_substeps()` / `_substep_rapier()`，游戏 `actor/player/src/hand.gd` 的成对冲量。Request：支持Joint连通组的有效运动估计/局部子步，区分求解前轻手瞬态速度与约束组实际运动；保留1px防穿与功率/动量要求。预算或任意硬限子步只能作为消融，不能直接作为正式修复。请求进一步暴露原生窄相、求解、碰撞体上传各段计时，现在_rp_cmd_us仅可确定整个推送-求解-读回段。

### 优先级3：避免破坏后重复重建

引擎源 `src/physics/pworld.gd::fracture_pixels()` / `refresh_mass()`。游戏 `map/src/collision_damage.gd::commit()`。Request：fracture_pixels一次正确继承摩擦/恢复系数、layer/mask/gravity以及静态碎片规则，或者提供无需重新分解碰撞形状的材料/质量更新接口，然后删除游戏补充refresh_mass。无真实分裂的损伤允许复用引擎已有local_connectivity快速判据，避免每笔全量Destruction.split；真正断裂仍需全量连通分量处理。

复杂度：每子步原生求解随碰撞矩形/接触/关节增加，且被全局N子步乘大；split随占用chunk/连通分量处理规模增长，矩形分解同时付出脏块扫描、矩形归并成本，实际主路径_merge_pass是分组排序归并，不能误用保留的_merge_pass_ref双重循环认定现用O(R²)。_lanes为排序O(C log C)，_trace约O(D×S)，本样本游戏接触查询约0.48ms/帧，优先级低于全局子步与20ms整图重绘。

复现：Godot `--path T:/GODOT/ink-2 --script test/profile_collision_damage.gd -- --cut --live`；自然下砸 `--slam`；同步消融 `--slam --no-sync`。日志 `test/perf_capture_baseline.log`、`test/perf_slam.log`、`test/perf_slam_no-sync.log`、`test/perf_cut.log`、`test/perf_cut_live.log`。未修改或提交引擎仓库。

## 2026-10-05：真实不规则画布复现脚手架，等待样本

- 游戏 F5 保存未固化 Image 为 `res://test/canvas_capture.tres`，F9 加载；保存包含尺寸、颜色、透明度，不固化、不读回 GPU。
- `test/profile_collision_damage.gd` 现只接受保存文件。默认180固定步，同一初始摆放、实体抓点和PD抬举目标；无文件、无墨水或多连通分量会停止并要求输入，不生成替代案例。`--fixture=路径` 可明确指定文件。
- 当前运行路径 `_substep_rapier`；已读回的开关：contact_events=false、profile=false、rp_debug=false、shading=false、soft_ccd=0、sleep=true、ccd=true、rp_ccd_substeps=1，手将ccd_max_motion设为0.5。并非全部功能打开。小笔划仅用于保存/脚手架测试，不是用户卡顿样本。
- 源码候选1：`gdext/rapier_bridge/src/lib.rs::rb_contact_get_points()` 每个索引从头遍历接触对；游戏 `_contacts()` 对全部索引分别调用，接触对数量P较大时累计O(P²)，每子步重复。另有引擎/游戏各查询一次接触数量的重复O(P)遍历。需要批量导出或稳定索引，实际贡献待真实样本消融。
- 源码候选2：`src/physics/pworld.gd::_compute_substeps()` 抓取成本预算仅在 `world.grabs` 非空时生效。游戏使用Weld/Hinge而非旧Grab，`world.grabs`为空；该预算不能保护Joint抓取。未求解的轻手瞬时速度仍决定全世界子步数，复杂体所有矩形随每子步反复求解。不可直接关CCD作为正式修复。
- 消融顺序：原样baseline；`--no-debug`；`--no-render`；`--no-damage`（仍采集接触）；在no-damage基础加`--no-contacts`；`--one-step`（仅诊断，可能穿透）；`--no-hand`；`--rest`。`--events` 只作重型事件路径对照，默认不开。每项新进程、同一文件，输出烘焙/手控制/世界步/原生推送-求解-读回/接触查询/结算时间及矩形、接触对、子步峰值。
- `--live` 为实际帧回调路径；无头默认用于CPU段对比，关闭渲染要在live再复核GPU贡献。关闭伤害或CCD会改变后续轨迹，比较时必须同时看刚体数量与接触/子步变化，不能把速度提升直接视为等价修复。
- 旧profiler中的轴向投影、加重Arm及截图临时脚本已清理。此阶段不对真实卡顿给出修复或性能结论，等待用户F5文件。

## 2026-10-05 补充：横向借力被游戏约束锁住

- 新复现：`test/test_live_input.gd -- --grip`，右侧加 `--right`。玩家 COM=(0,131)，手 COM=(0,211)，指尖焊接地面 (0,231)，鼠标位于手左右60px；身体悬空，不存在脚部摩擦。
- 左目标：身体主动反作用约 +7.926M X，动量差扣除主动冲量和重力后的约束余项约 -7.709M X；一秒横向位移 -0.0355px。右目标：主动力 -7.916M X，余项 +7.985M X，位移 +0.0350px。日志 grip_left_vectors.log / grip_right_vectors.log。
- 游戏创建的 Weld 锁定手与地面角度，Slider 锁定手与 Arm 角度，因此 Arm 的世界方向也被锁定；Player/Arm Hinge 只允许身体自转，不能让这个杆围绕抓点摆动。横向没有期望的自由度，反力经关节链传回地面。这是游戏约束设计冲突，不能作为引擎缺陷提交。
- 仍需用户确定放开哪处转动：保留手/物体角度绑定、允许杆/手相对转动；或保持杆/手角度锁定、将抓取改成点铰链。未擅自改变先前规则。
- R3 的数值误差、超长及斜向振动问题保留；上述结果不证明引擎逐关节反力。请求引擎提供逐关节线性冲量矢量与角冲量查询，支持物理调试，而不仅返回用于断裂判断的模长。

## 2026-10-05 新 Request：重复渲染与斜向抓地约束

### R1：sync_world_bodies 必须沿用 has_own_sprite 策略

- 引擎源：`T:/GODOT/bag/Godot_2DVoxel_Addons/src/nodes/pixel_world.gd::sync_world_bodies()`。
- 当前函数无条件 renderer.sync 每个 PBody；而 rebuild / add_body_node 已有 has_own_sprite 过滤。
- 消费方 `T:/GODOT/ink-2/actor/player/asset/hand.tscn` 的 Hand 有独立三角形 Polygon2D 和透明 PhysicsSprite；正常不进内部渲染器。调用 sync_world_bodies 后却产生矩形手贴图；随后游戏跳过自有视觉的同步，导致这张矩形留在旧位置。
- 实测复现：`test/test_game_control.gd` 中检查 engine sync reproduces duplicate hand renderer，确实命中。
- 请求：统一过滤策略；已有自有视觉体的旧内部 holder 要回收；提供明确的仅物理不渲染配置（用于不可见 Arm），不要要求透明精灵占位。
- 临时消费方规则：CollisionDamage 的最终 renderer.prune 排除受保护的内部 Arm/Hand，正常同步也不再画它们。没有修改 addon。引擎修复后移除此排除。
- 验收：破坏前后只保留三角形手，内部 Arm 不可见；连续多个固定步的同步不得生成矩形残影。

### R2：破坏瞬间的插值历史需要核验，尚未确认是引擎 bug

- 引擎源：`src/render/pixel_renderer.gd::sync()` / `forget()`，以及 `src/nodes/pixel_world.gd::sync_world_bodies()`。
- 用户报告碰撞时闪一帧。消费者已修复 hand_visual.gd 先于世界求解读取旧手位姿的问题；单帧异常仍需独立录帧验证。
- 请求核验：新建 holder/碎片的初始变换和物理插值历史；形状边界/贴图 offset 改变时是否混用旧局部坐标；删除旧贴图与显示新贴图是否在同一帧正确交接。不能直接把这三项当作已确认根因。

### R3：斜向 Weld + Slider + Hinge 的持续施力振动

- 引擎源：`src/physics/pworld.gd::_compute_substeps()`、`_substep_rapier()`；`gdext/rapier_bridge/src/lib.rs::rb_world_step()` 及关节限制路径。消费者控制源 `actor/player/src/hand.gd::_calculate_motor()` / `_apply_internal_wrench()`。
- 精确重现：在 ink-2 运行 Godot `--script res://test/profile_collision_damage.gd -- --live --ground-grab`。玩家 COM=(0,215)，地面顶面 y=231；指尖焊接 (-80,231)，手中心沿连杆回退20；鼠标持续位于手中心左侧60。脚部无输入、不刹车，角动量配平关闭。
- 600 步实帧：FPS 163～166，mean 1.514ms、p95 2.647ms、max 3.774ms，CCD峰值53。确实向右借力94.152px，但最后60步去趋势振动26.934px，末速度475.97px/s，Hinge锚点误差0.248822px，Slider角差-1.594412度；Weld锚点误差仅0.000015px。日志 ground_grab_live.log / ground_original_arm.log。
- 因而刹车不是振动的唯一根因，也不能以焊接锚点很稳声称整条连杆稳定。既有49项手部测试仍通过，它们未覆盖此持续斜向极限工况。
- 多因素试验：仅把内部 Arm 质量4改成84，去趋势振动仍25.699px；末Hinge误差0.003666px、Slider角差0.506595度。试验只在 test 的 --heavy-arm 分支，没有修改游戏质量。
- 仅沿静态抓握连杆轴投影力的试验（test 的 --axial）：振动50.442px、臂长165.136px，且造成额外地形破坏；更差，未改入游戏。日志 ground_axial.log。
- 请求：用本重现共同排查限位求解、质量比、未求解轻手速度与世界子步，以及控制目标不可达时的受力反馈；暴露原生关节求解精度配置与约束误差诊断。此处尚未证明所有振动来自引擎，需避免把消费者的不可达目标或PD反馈问题误归给求解器。
- 验收：保留成对力、功率预算与角度绑定；臂长不超过160px；稳定段振动小于0.25px；禁止锁身体速度、关碰撞、瞬移或硬编码攀爬动作来掩盖问题。

## 2026-10-05 v0.3.5 复核（以下旧证据保留供对照）

- 已更新到 7714886；游戏改用 contact_info 查询，关闭完整接触事件。
- 同版本、同 600 步抓块下砸动作：事件路径 mean 7.801ms / p95 16.452ms，后段 56～64FPS；查询路径 mean 1.207ms / p95 1.927ms，后段 160～165FPS。两组终态像素、物体数和速度一致。
- 29 个全局子步仍然存在，但本案例的主要持续开销是每子步重复计算 contact_width/stress；原文关于 CCD 的推断不能独自解释卡顿。
- 新增 fracture_pixels 与 sync_world_bodies 已接入，批量破坏和节点同步接口不再需要请求。
- 剩余接口问题：fracture_pixels 对原体 rebuild 未传摩擦/恢复系数回调；新碎片未继承碰撞层、mask、gravity_scale，且静态地形碎片仍静态。游戏暂用公开 refresh_mass 和属性赋值保持旧规则。希望批量接口一次处理这些属性，避免重复质量/形状重建。
- physics_step_finished 是固定步结束信号，不是子步信号；contact_info 不带接触采集时位姿。游戏仍在各子步后立即查询，避免旧接触点与固定步末位姿错配。仍需要公开子步回调或局部接触点快照。
- 查询路径 max 35.800ms，尖峰未消除。仅本案例验证，不代表大量碎片场景已达标。

## 当前证据

- 现有破坏接口已能完成精确删除与分片，本请求不涉及新增批量破坏接口。
- `addons/pixel_destruction/physics/pworld.gd::_compute_substeps()` 根据所有动态体中最高的 `linear_velocity.length() + abs(angular_velocity) * bounding_radius()` 决定全世界子步数；声明的 `ccd_max_substeps` 未参与这里的限制，实际使用 `ccd_substep_budget=600`。
- 手部通过 Weld 抓物体，马达冲量先施加在质量 84 的手上；物块质量 1024，关节求解后才重分配冲量。CCD 检查发生在关节求解前，读到了轻手的瞬时速度。持续向已受地面支撑的物块施力也可能触发大量子步，尽管求解后的物体几乎没有移动。
- 新数值下的实帧抓块反复下砸：5 个物体、无新碎片，峰值 29 子步，后段 FPS 57；CPU 固定步 mean 7.720 ms、p95 16.429 ms、max 22.511 ms。日志 `test/profile_calibrated_slam_live.log`。
- 游戏侧预分配焊接组合冲量可以避免临时速度，但原来的严格回归出现 0.210074 度角误差（门槛 0.1 度）；原施力方式为 0.019773 度。该实验已经撤回。不能通过牺牲关节精度解决性能问题。
- 另外，`PWorld._collect_contacts_rapier()` 每子步调用 `_contact_add_rapier()`，后者会调用 `_fill_contact_stress()`；只要材料强度表非空，就会通过 `Query.thickness_at()` 重复扫描双方厚度，即使游戏只需要 points/impulse、并不消费 shear_ratio。

## 希望引擎处理

1. CCD 需求基于关节约束后的有效运动预测，而不是未求解轻手的临时速度；优先支持刚性关节组或岛级步进，避免远处下落碎片增加全世界子步数。
2. 暴露原生关节求解精度配置，使角度精度可以由求解器保证，而不是依赖大量全世界 GDScript 子步。不能以全局限速、关闭碰撞、删除场外物体替代。
3. 接触事件提供不计算 stress/shear_ratio 的轻量订阅模式，只导出已有接触点、冲量、接近速度。
4. 接触数据带采集时的双方变换或本地坐标，或提供公开的子步完成回调。目前游戏复用 `_compute_substeps()` 与 `_substep_rapier()`，每子步立即计算损伤，固定步末合并提交；这是现有函数的调用，没有修改 addon，但需要稳定的公开入口。

## 验收

- 原 `test/test_hand_physics.gd` 49 项全部通过，尤其 Weld 相对角误差小于 0.1 度、晚期抖动、抓地支撑、动量/功率/能量和长度。
- `test/calibrate_collision_damage.gd`：普通落下无破坏，抓 32×32 物块完整下砸只损伤接触面一层。
- `test/profile_collision_damage.gd -- --live --slam`：持续施力时不因轻手的未求解速度将全世界推到几十子步；实测帧耗时无长期退化。
- 高速物体和一像素结构仍不穿透，且不引入额外能量。

## 2026-10-06 本地已实现的优化与剩余问题

- 源码main/0785037上有未提交实现：PBody.control_force/control_torque按子步积分；PBody.additional_solver_iterations经op40进入Rapier约束岛；fracture_pixels增加可选dynamic_fragments，统一继承材质/过滤/重力并保留局部dirty；接触对懒索引移除逐对从头扫描的O(N²)遍历。
- 游戏删掉commit中的重复refresh_mass和属性修补；hand现有PD阻尼48、约束岛追加迭代32。手部50项通过，Weld角误差0.026048度，承重晚期位移范围0.037750px，没有放宽门槛。
- 用户磁盘画布3770像素/275矩形，三轮对照：slam mean 2.684->1.076ms，P95 3.972->1.173ms；cut-live mean 2.391->1.353ms，P95 4.370->1.967ms，最大帧35.450->15.084ms。两场景合计CPU平均提升2.09倍；断裂均值仅1.77倍，应继续优化复合碰撞体窄相/首次注册成本，不宣称所有场景翻倍。
- 首次运行一次第0帧202.174ms已计入统计，该帧无损伤/渲染同步且最后一次native计时1.130ms。需要进一步分段计时_flush_pending、首次资源注册和初始化，尚不能确定是OS调度还是引擎初始化。
- 实现需由引擎维护者审核并上游合并；当前安装是v0.3.6+本地优化，后续覆盖安装会覆盖本地实现。源文件和日志详见根AI工作日记；未提交、未发布、未发外部消息。

## 2026-10-06 v0.3.8集成复核

- 已同步91dc1ec并重新编译安装；冻结接入游戏统一_step，摄像机宽高各4倍范围，AABB完全离开才冻结，返回/缩放恢复，与玩家关节连接的整组豁免。源端freeze19项与游戏冻结7项通过。
- 官方op40现在是joint_set_softness；保留上轮本地局部约束岛迭代时改用op42，避免混装DLL误读协议。持续控制力、接触索引与碎片属性优化继续保留；不是未经修改的发布包。
- 旧“官方sync重复手视觉”问题在新引擎已修复，旧重现bug断言替换为验证不重复；手部50项仍通过。native静态链接修复libwinpthread依赖。
- 新画布复测slam均值0.795ms，cut-live均值1.478ms，切断API6.216ms，同步3.153ms；具体日志v038_*.log。Demo存在0.5秒刚体对损伤冷却、每渲染帧1对限流、场外移除与400动态体目标预算，且没有游戏PD连杆控制器；不能仅按碎片数对比，更不能把消融后的静置动作当作同输入性能证明。

### R9：2026-10-06 新画布底部托举与实际 1% low

#### 样本与测试边界

- 新保存的 test/canvas_capture.tres 为256×256，12485实体像素、12个连通分量。SHA256为2E1C7B5C35F5D0AE61286BA3FD5530044F62D812331EAD3A8835C20CD08E60DB。全部保留参与碰撞，没有改样本、生产脚本、引擎源码或安装DLL。
- 旧脚手架仅接受一个连通分量，提前退出；最大体摆位还可能让玩家出生在底板外。本轮修正摆位，区分最底部承托部分与最大物块底缘。
- 最底部承托体1904像素/115矩形，指尖抓点(175,222.5)；最大物块2383像素/162矩形，抓点(95,176.5)。指尖初始误差小于0.00003px，已实际查看抓点、站位。
- --rendered使用真实Hand/CollisionDamage物理回调与追帧，不按每个渲染帧手动推进一次。每轮独立进程、600渲染帧、限帧60、关闭VSync。实际全屏2560×1600，命令行960×540未覆盖项目mode=3。
- 1% low是最慢6个渲染间隔平均耗时的倒数，包含首个采样帧的初始化追帧；固化约150ms单列，不计入运行阶段。CPU_WORK倒数不是实际FPS。截图读回会制造尖峰，截图轮不纳入结论，临时PNG与中途错误摆位结果已清理。

#### 实际渲染结果

| 工况 | 平均FPS | 1% low FPS | 最差帧ms |
|---|---:|---:|---:|
| 最底部持续托举，原安装版本 | 59.65 | 28.06 | 76.65 |
| 最底部持续托举，计时副本 | 59.83 | 34.20 | 57.35 |
| 最底部远鼠标目标向上用力，计时副本 | 59.67 | 30.00 | 72.78 |
| 最底部反复托举/下砸，计时副本 | 57.26 | 21.96 | 57.66 |
| 最底部托举/下砸，Q开启 | 60.01 | 41.66 | 40.99 |
| 最大物块底缘反复托举/下砸，复测 | 46.47 | **7.45** | **149.79** |

常规最底部托举只使承托体质心最高上升6.68px，远目标也只上升6.51px，随后被接触卡住；没有举起整堆图形，不能宣称完整托举验收。远目标仍经过Hand的156px目标半径裁剪，不能声称一直输出最大力。该抓点没有复现持续卡爆；明显低帧在另一抓点复现，前次原版同类工况1% low6.58FPS、最大193.48ms。

运行时输入按渲染帧切换，低帧会改变动作历时、追帧与物理轨迹；这些实机轮次用于重现，不能作为严格同轨迹优化倍率。

#### 最严重尖峰归因

bottom_largest_recheck_frames.json第463帧：渲染149.794ms，控制器CPU137.516ms，6次物理回调合计42个世界子步。日志last_substeps=7仅为最后一次固定步，不能误写整帧7步。该帧没有伤害提交/节点同步。

| 阶段 | 该帧ms | 占控制器CPU |
|---|---:|---:|
| GDScript逐矩形AABB/质心刷新 | **50.567** | **36.8%** |
| 接触取回、解码及游戏接触构造 | **31.024** | **22.6%** |
| ForceDebug接触采样与箭头聚合 | **27.082** | **19.7%** |
| Rapier原生物理管线 | 13.862 | 10.1% |
| calculate扣除接触/调试后的其余计算 | 2.708 | 2.0% |
| 实际伤害提交 | 0 | 0 |

calculate共60.814ms，包含31.024ms接触与27.082ms调试，不能重复相加。Rapier管线包含碰撞、约束、CCD，不能将全部计时称为碰撞识别，尚未进一步拆分Rust管线。

600帧累计AABB2382.978ms、接触构造1325.267ms、调试采样1248.136ms、Rapier1001.325ms；调试绘制另有1027.974ms/600渲染帧，不在控制器CPU内。命令准备245.291ms、状态解码72.535ms、包头模板109.157ms；语言调用边界差值估算36.921ms。

接触传输的数据整理成本显著；DLL边界/字节带宽本身不是最大项。接触阶段仍含少量原生查询，不全归入字典分配。复杂度是全世界子步数S乘动态矩形总数R的AABB遍历，加S乘接触点数P的查询解码/调试遍历；渲染落后追多个固定步再次放大。此轮矩形访问1667667次、原生调用80463次，包含600次测试快照与一次最终查询。

#### 真实断裂与同轨迹消融

- --runtime-cut在采样前准备掩码，第60帧执行现有fracture_pixels与同步；删除6像素，生成1个新碎片。API4.635ms，API+同步9.148ms；该帧控制器加断裂13.912ms，实际渲染18.718ms，整轮1% low33.68FPS。此局部断裂不是百毫秒尖峰来源，不能代表大量碎片同时生成上限。
- 600固定步ForceDebug开/关：CPU均值5.924→5.139ms，降低13.2%。全部600帧物体位置字符串相同，终态位置/速度、1020子步、1个新碎片、858591矩形访问、31965原生调用一致。原生耗时有系统波动，不能以实机Low变化宣称优化数倍。日志bottom_matched_debug.log与bottom_matched_no_debug.log。

#### 优先优化位置，本轮尚未实施

1. 引擎physics/pbody.gd的update_aabb、_rect_world_aabb及physics/pworld.gd的_substep_rapier：减少每矩形GDScript调用、重复三角函数，或提供精确AABB原生批量回读。保留等价包围盒与bounding_radius/CCD，不能直接删刷新。
2. 游戏map/src/force_debug.gd的sample_contacts、_add、_draw：以每刚体分量累加减少每点临时数组/字典访问，降低文字重建频率。现有enabled开关关闭时确实退出采样；本轮仅消融，不改生产表现。
3. 引擎physics/pworld.gd的_contact_fetch与游戏map/src/collision_damage.gd的_contacts：批量取回接触，减少逐对包头/模板分配与逐点Dictionary构建。点数猜值已存在，不能再把所有开销解释成每对必查两次。
4. 处理上述开销后重新测追帧与Low，不先砍CCD、限制运动或跳过碰撞。

#### 复现与证据

在T:/GODOT/ink-2使用T:/GODOT/tool/Godot_v4.7.2-stable_win64_console.exe --path . --disable-vsync --max-fps 60 --script test/profile_collision_damage.gd --，随后选择参数：

- --bottom --rendered --frames=600 --dump-frames：最底部原版托举。
- 同上增加--transport：隔离计时副本；先执行python -X utf8 test/build_transport_probe.py。
- 增加--high-lift为更远向上目标，--slam为交替下砸，--rotate为Q开启。
- --bottom --largest --slam --rendered --frames=600 --transport --dump-frames：严重低帧工况。
- --bottom --rendered --runtime-cut --frames=600 --transport --dump-frames：单列局部割断。
- 同轨迹消融用--headless、去掉--rendered、使用--bottom --slam --frames=600 --transport，第二轮增加--no-debug。

原始日志/逐帧数据位于test/bottom_support_*.log、test/bottom_support_*_frames.json、test/bottom_largest_recheck*，汇总test/bottom_support_summary.json。测试副本新增opcode44只读累计计数，最终43仍读取并清零，不改正式协议。主要测试无SCRIPT ERROR/ERROR/未知opcode或泄漏，既有Camera2D插值warning仍在。未关闭用户编辑器PID25308。
