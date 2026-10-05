# 全局 CCD 子步与关节施力的性能问题

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
