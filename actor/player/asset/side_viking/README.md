# Side Viking 2D IK Rig

可直接实例化的 Godot 4.7 侧面维京战士角色资源。

## 使用

将以下场景实例化到关卡中：

`res://actor/player/asset/side_viking/side_viking_character.tscn`

场景自身不依赖演示关卡或全局单例。默认启用四条二段式 IK 链：

- `NearUpperArm -> NearForearm -> NearHand`
- `FarUpperArm -> FarForearm -> FarHand`
- `NearThigh -> NearShin -> NearFoot`
- `FarThigh -> FarShin -> FarFoot`

运行时可拖动 `Targets` 下的彩色控制点。`NearKneePole` 控制近侧膝盖弯曲方向；`ShieldTarget` 独立控制盾牌，不与远侧手联动。

如果由游戏代码控制目标点，可将根节点的 `show_targets` 设为 `false` 隐藏控制点，将目标节点的 `global_position` 设置为期望位置。根节点的 `solve_ik` 可用于整体开启或关闭 IK。

场景内保留空的 `AnimationPlayer`，可直接为目标点、头部、披风、裙甲和盾牌骨骼添加动画轨道。
