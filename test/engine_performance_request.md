# 全局 CCD 子步与关节施力的性能问题

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
