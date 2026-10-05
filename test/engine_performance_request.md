# 全局 CCD 子步与关节施力的性能问题

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
