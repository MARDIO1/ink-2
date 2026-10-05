## 2026-10-05：碰撞破坏游戏规则与引擎接口核对

- 新增 map/src/collision_damage.gd：世界统一计算法向冲量破坏，不给 PBody 挂脚本；相对材料强度、有限对数支撑、方向性整像素删除计划。采用方案 B，未满像素的预算舍弃，不读写 aux。
- player_physics.gd 新增 collision_damage 与 apply_collision_damage(amount)，暂不接生命/死亡。
- 按已授权范围将最新 target/release/rapier_bridge.dll 部署到 native；两份 SHA256 均为 D3AA38A69C532BFCDC5314722A140DCFAA9BE82875A7E64F4984C44A231BB050。
- test/test_collision_damage.gd：19 项通过、0 失败，包含真实 Rapier 落箱、静压不破坏、冲量分配、材料/厚度、遇空停止和玩家伤害。日志 test/collision_damage.log；退出仍有 1 个原生实例泄漏警告。
- 现有 test/test_hand_physics.gd：49 项通过、0 失败。日志 test/hand_after_dll.log；其退出仍报告 554 实例泄漏与 5 资源占用，未作为功能通过忽略。
- addon 源码未修改。当前缺固定步完成通知与精确批量像素 fracture/节点渲染包装，已写 test/engine_collision_request.md。
- 尚未挂入主场景，尚不能在游戏中实际碰撞破坏；等引擎完成 request 后连接每步计算与统一提交。未宣称碎裂守恒或视觉破坏闭环已通过。

## 2026-10-05：改用现有接口，完成主场景接入

- 更正上一条结论：现有 PWorld.fracture() 与 Destruction.Damage.rect() 足够实现方向切槽，不需要等待新接口；删除此前创建的 test/engine_collision_request.md。addon 源码未修改。
- map/src/collision_damage.gd 负责固定步进、双方伤害计算、像素删除并集及矩形合并提交、碎片速度场和材质恢复、节点索引与地面渲染刷新。主场景只增加一个 CollisionDamage 子节点，不给每个 PBody 挂脚本。
- Ground、Box 与固化墨水使用普通可破坏材料；玩家身体和手不删像素，玩家仅累计 collision_damage；生命/死亡与剪切处理暂不接入。
- 固化检查发现 add_body_node() 不会把节点加入场景树；canvas_solid.gd 补上 add_child() 和世界位置，修复场景外遗留节点。
- 破坏自测最终 34 项通过、0 失败，覆盖真实 Rapier 碰撞、精确删除、碎裂、密度、速度场、动能不增加、实际主场景损伤、固化注册和节点归属。日志 test/collision_damage.log。退出仍有 2 个 ObjectDB 残留警告；不宣称引擎生命周期问题已全部解决。
- 手部回归 49 项通过、0 失败；日志 test/hand_after_dll.log。该测试退出仍有 554 个实例和 5 个资源残留。完整默认主场景另外运行 180 帧，无运行期脚本错误；退出仍有资源残留，日志 test/main_collision.log。
- 已运行带画面的主场景检查并查看截图：碰撞后地面/物块像素变化可见，玩家和三角形手仍可见。临时截图查看后删除。没有进行人工操作的完整玩法验收。
- 保留用户原有 project.godot 与 test/test_hand_physics.gd 修改；未提交 Git。

## 2026-10-05：碰撞破坏复杂度和性能修正

- 重现批量破坏问题：800×40 地面上删除 128 个锯齿像素，旧实现 33 次 fracture，单次 128.843 ms。每段还额外 rebuild，且丢失局部脏范围，造成重复全量渲染。
- commit 改为先对选中像素并集调用 clear_pixel，再复用 Destruction.local_connectivity / split、PBody.rebuild 与 PWorld.add_body。每个受损物体每固定步统一分片一次，每个保留体只重建一次。复杂度去掉切槽段数与全体扫描的乘法项；旧 _rectangles 与逐段 fracture 循环删除。addon 源码未修改。
- 保连通时传实际脏范围；发生分片时才保守全量刷新。节点表只在有破坏时更新，用字典判存活；渲染统一到帧末。线性冲量插值的权重和直接求和，删除临时权重数组。
- 射线先检查表面材质和预算，支撑饱和且路径成本达到未减伤预算后停止。未使用任意深度截断；大预算继续向后扫描。1024 层射线的等价性和大预算继续扫描纳入测试。
- test/profile_collision_damage.gd 提供固定输入、关闭破坏、实时挥手对照；同一锯齿用例最终 5.791 ms、1 次提交，约 22 倍改善。固定输入 600 步 OpenGL 主场景 mean 0.944 ms、p95 1.809 ms、max 7.768 ms；关闭破坏 mean 0.539 ms。是 CPU 固定步计时，不等于完整 GPU 帧耗时。
- 实时持续挥手仍有性能问题：开启破坏 600 步 mean 14.192 ms、p95 16.229 ms、max 40.906 ms，后半段实测 46～56 FPS；关闭破坏 mean 4.138 ms、约 163～165 FPS。破坏累计 calculate 23.89 ms / commit 34.03 ms，持续低帧的主要成本已经不在结算脚本。
- 定位第二原因：碎片 27/81 像素掉出地面后仍下落，速度 650；PWorld._compute_substeps() 以全世界最快物体为准，手部 ccd_max_motion=0.5 将全世界提升到 22 子步。源码中的 ccd_max_substeps=16 没有在该函数里使用，实际限制是 ccd_substep_budget=600。未擅自删除场外碎片、限制速度或降低抓握物理精度；不宣称全程不卡已解决。
- 破坏回归 37 项通过、0 失败，退出仍有 2 ObjectDB 残留。详见 test/collision_damage.log、profile_before_stress.log、profile_final_visual.log、profile_live_sweep.log、profile_live_sweep_disabled.log。

## 2026-10-05：实时实例检查、下砸数值与子步时序

- 只读识别用户正在运行的实例：Godot 编辑器 PID 29152，游戏 PID 223528，游戏启动于 03:54:56，remote-debug 指向 127.0.0.1:6007。已通过 PrintWindow 查看真实游戏窗口；运行日志没有帧耗时/子步指标，未声称已读取该实例内部 PWorld 状态。未关闭或重启用户实例。
- 发现已有手本体 layer/mask 都为 0，因此以 Weld 抓住 32×32 物块下砸进行校准；手是否也要有直接碰撞已向用户异步询问，未擅自修改碰撞配置。
- 发现碰撞点与位姿时序失配：world.step() 汇集多个子步的接触，而旧结算用整步最后位姿采样材料，可能漏掉真正撞击。游戏 _step() 复用已有 _compute_substeps / _substep_rapier，每子步立即计算损伤，再在固定步末对删除并集一次提交；addon 未修改。
- 数值改为 damage_scale=0.012、min_approach=300 px/s。校准旧 0.1：普通落下峰值 160 像素/5 层，完整下砸 288 像素/9 层；新系数普通落下不破坏，完整下砸实际删除 32 像素/1 层，物体数保持 5，没有产生碎片。测试是实际 PD、Weld、Rapier 与真实提交，不是合成接触。
- 破坏回归最终 38/38，校准验收 4/4。退出仍有 2/3 ObjectDB 残留。校准脚本 test/calibrate_collision_damage.gd，日志 calibrate_damage.log。
- 新默认值下实时空手连续挥动 600 步 FPS 162～165，CPU mean 4.246 ms、p95 4.785 ms、max 8.895 ms，无破坏和碎片。真实抓块反复下砸仍会达到 29 子步，后段 FPS 57，mean 7.720 ms、p95 16.429 ms、max 22.511 ms。不能宣称卡顿根治。
- 进一步定位马达冲量与 CCD 时序：功率按手和物块组合质量计算，但执行冲量先打在轻手，CCD 在关节求解前读取瞬时速度。试验了守恒的组合冲量分配；动态焊接相对角误差升至 0.210074 度，未通过 0.1 度验收，故完整撤回手部试验，没有降低测试门槛。恢复原施力后 49/49，通过角误差 0.019773 度；日志 hand_original_compare.log。原 hand.gd 未留下本次修改。
- 准备 test/engine_performance_request.md，明确全局 CCD、原生关节精度、轻量接触事件和子步快照/回调的具体源文件与验收，不再请求已有的批量破坏能力。
- 实时截图查看后删除，只保留测试脚本与日志；用户原有 project.godot、test/test_hand_physics.gd 修改未覆盖，未提交 Git。
