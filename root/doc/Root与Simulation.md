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

## 切关加载：为什么是逐帧烘焙

`root.gd::request_level_change` 已经用 `ResourceLoader.load_threaded_request` 在后台读盘，
但真正的卡顿不在读盘，也不在实例化：

| 阶段 | 实测（第二页，69 个像素刚体） |
| --- | --- |
| 线程读盘 | 76–200 ms（首张冷缓存 1.6 s） |
| `PackedScene.instantiate()` | 12 ms |
| 关卡 `_ready` → `PixelWorld.rebuild()` 全量烘焙 | **3146 ms（整帧）** |
| 单个刚体烘焙 | 12–135 ms，全部相加约 3.7 s |

所以 `load_level()` 改成**逐帧烘焙**：实例化后先把直接子级的像素刚体摘出来，
先用空世界跑一次 `rebuild()`（0.1 ms，子节点的 `_ready` 早于关卡根，必须先把 `world` 建出来），
再把刚体逐个放回并 `bake_node()`，每 `bake_bodies_per_frame` 个让一帧，最后补 `_bake_joints()`。
关卡这时在切换遮罩后面，玩家看不到中间状态。

`PixelWorld.rebuild()` 只遍历**直接子级**，所以摘取范围必须和它一致。

`load_level()` 是异步接口，所有调用方都必须 `await`。F2 恢复使用
`Root.restore_editor_level()` 持有整条等待链，旧 `Creative` 只用 `call_deferred`
交接；不能让即将随旧关卡释放的节点等待加载结果。

分帧加载开始时设置 `PixelWorld.body_bake_pending`；全部刚体和普通关节烘焙完成后
清除标记并发出 `body_bake_completed`。齿轮轴、蓝线、动力箭头、弹簧和关卡机关在此
信号后恢复锚点，避免把暂时缺少的刚体误判成损坏数据而删除自己。
`level_changed` 在这道屏障之后发送，HUD 绑定的始终是已就绪的关卡。
摘下节点前保存并清除整个子树的 `owner`，挂回后恢复，以保留编辑器保存所需的归属。

⚠️ **只摘纯墨迹刚体**（不属于 `player` / `living` 组的那些）。玩家的根节点**本身就是一个
`PixelBody2D`**，把它一起摘掉会连带出两个问题：`debugHUD`、`SimulationRuntime` 等在 `_ready` 里
按 `../Player/...` 找节点，全部报 `Node not found`；玩家还会晚挂一帧，和 `pbody_visual`
已绑定的视觉错开，画面上表现为角色周围一圈棕色描边 + 文字重影（看起来像被画了两遍）。

效果：单帧最长从 **3254 ms 降到约 408 ms**，烘焙期间每帧 180–210 ms（约 5 FPS），
加载动画一直在推进；代价是总时长变长（同样的烘焙量分散到更多帧）。
`bake_bodies_per_frame` 是导出参数，想要更短的加载就调大、想要更顺的动画就调小。

## 切屏期间的鼠标

`InkCursor` 是软件指针，主线程被占住时它只能跟着卡。`game_cursor.gd` 在
`SceneTransition.busy` 期间调用 `_release_mouse()`，把指针交还给系统光标 ——
系统光标在操作系统层绘制，游戏掉帧时依然能动。过渡结束自动恢复软件指针。
