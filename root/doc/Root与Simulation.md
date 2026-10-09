# Root 与 Simulation

`root/` 管应用级装配，不放具体关卡资产：

- `root.tscn` / `src/root.gd`：唯一入口，管理菜单、选关、`Level` 与 `UI` 容器。
- `simulation_runtime.tscn`：统一装配固定步进、碰撞伤害和颜色规则。
- `src/simulation_runtime.gd`：模拟协调层。
- `src/physics_step.gd`：物理步进、接触、分片提交与渲染同步。
- `src/impact_damage.gd`：碰撞伤害和裂纹规则。
- `src/debris_dust.gd`：小碎片的视觉灰尘。

`SimulationRuntime` 的资源归 `root/`，但节点仍由各关卡场景实例化为 `PixelWorld` 的直接子节点。这样它能直接访问同级的 `Player`、`Camera2D` 和调试 HUD，同时每次切换关卡都会创建一套干净的模拟状态。

`map/` 只保留关卡场景、地图资产，以及确实只属于地图资产的 `map_root.gd`。
