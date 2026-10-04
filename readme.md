做好分工，本工程不修改引擎

引擎也ignore了，在外部仓库

文件管理使用分布式的，player的贴图就放当Player的tscn旁边

依旧是参考ink-fffight，前作

## 文件组织

- `actor/player/src`：角色、手控制和视觉同步脚本。
- `actor/player/asset`：Player、Hand 场景及各自材质，资源与使用它的场景放一起。
- `actor/canvas/src`、`actor/canvas/asset`：画布脚本和场景。
- `Ink/asset`：通用墨水材质。
- `map/asset`：关卡场景。
- `test`：验收和临时工具；截图检查后删除。

## 手的规则

PD 产生手与身体之间的成对力，限制最大力和主动做功功率。
抓握创建 Weld，松手删除 Weld；负载质量只参与控制计算，不重复添加物理质量。
Hinge 在身体质心允许转动，Slider 允许长度变化并锁定手的相对转角。
`Arm` 是这两个 Joint 之间的内部支座，质量为 4，无重力、无碰撞；不是额外的可操作肢体。
当前引擎没有单个 Joint 同时表达这两个自由度，所以需要这个支座。
`player_physics.gd` 只适配子刚体注册和初始坐标，Hand 仍是 Player 子节点。

画布在编辑器 2D 舞台可见，选中 Canvas 修改 `canvas_size`。
Area2D 的 Bounds 随尺寸更新，只显示范围，不参与像素刚体碰撞。

## 验收

使用 Godot 的 `--headless --path` 参数，分别运行：

```text
--script res://test/test_hand_physics.gd
--script res://test/test_canvas.gd
```

测试包括关节长度与角度、抓物抬起、抓地及物块支撑、反作用力、动量和主动功率预算。
动量测试关闭外部阻尼；有重力和接触的场景按执行器做功检查能量预算。
