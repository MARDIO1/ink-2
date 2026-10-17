# 当前工作区架构与代码审计

审计日期：2026-10-17。对象为当前工作区，包括未提交修改；不是仅检查 Git HEAD。本轮没有修改业务代码。复现脚本、PCK 和日志仅写入 `.codex-tmp/architecture*`。

后续修复记录：本报告第 1、2 项已在“无法进入地图编辑器”修复中处理：恢复事务移交常驻 Root，旧同步调用改为 await，物理依赖恢复等待刚体就绪屏障，并保留节点 owner。回归用例见 `test/test_editor_reload_lifecycle.gd`。下文保留原审计快照及其他尚未处理问题。

结论：确认 2 项 P1 衔接冲突、4 项 P2 行为或边界问题。当前最需要修复的是加载生命周期和调用契约，随后再拆分大脚本。不能将本次结果表述为“自检无问题”。

## 1. P1：load_level 改为异步，F2 恢复与旧调用方仍按同步接口使用

- `root/src/root.gd:146` 的 `load_level()` 在第 159 行等待逐帧烘焙，因此已成为协程。
- `debug/creative/src/creative.gd:3521` 仍执行 `var level: Node = tree_root.load_level(packed)`，然后立即访问 `level`。这是生产代码中的 F2 已保存地图恢复路径。
- `test/test_hud_level_rebind.gd:29`、蓝图、音频、UI 等测试，以及 `tools/rebake_chunked_terrain.gd:34` 仍有相同旧调用方式。另有不接收结果的调用也需要迁移。
- 实测运行旧 HUD 重绑测试，日志明确报 `Trying to call an async function without "await"`。该测试随后不能完成原有断言。

影响：F2 恢复可能在替换关卡后中断，替换编辑器不能按预期激活，转场收尾也可能无法执行；相关旧测试的通过结论已失效。

建议：明确分开“实例化并挂载”和“等待关卡就绪”两个接口，或将所有调用统一迁移为 `await`。切关和编辑器恢复应共用同一条加载事务，保证生命周期及失败处理一致。

复现日志：`.codex-tmp/architecture-async-callers.log`。

## 2. P1：逐帧烘焙与机关的一次性 deferred 初始化冲突

- `root/src/root.gd:169` 先摘下非玩家的直接子级刚体。
- `root/src/root.gd:193` 每次只挂回并烘焙一部分刚体，然后让出一帧。
- `actor/canvas/src/gear_bearing.gd:61` 的 deferred `restore()` 找不到轮体时，第 73 行直接 `queue_free()`。
- `map/src/ink_machine_checkpoint.gd:21` 的 deferred `_setup()` 找不到运动体或其 body 时直接返回，没有等待加载完成后重试。
- `ink/blue/src/motor.gd`、`ink/blue/src/wire_layer.gd` 和 `ink/yellow/src/stroke.gd` 也依赖 `_ready` 后的 deferred 恢复，需一并核对，不能只补一个节点。
- `root/src/root.gd:158` 在烘焙完成之前发出 `level_changed`，订阅者目前也无法区分“已经挂载”和“已经就绪”。

最小复现场景包含两个普通刚体、一个齿轮轴、一个机关。加载返回后，结果为：

```text
bodies=2 bearing_exists=false machine_bound=false machine_joint=false
```

影响：地图能打开、地形能出现，但轴承已消失或机关永远没有初始化；只验证“切到了正确场景”无法发现这个问题。

建议：增加明确的 `level_ready` 或分阶段恢复接口；所有刚体烘焙完成后，再恢复关节、导线、动力箭头、弹簧和机关。暂缺依赖时不得按“地图损坏”删除节点。通过“节点总量、关节数量、机关绑定结果”验收，而非仅看目标场景路径。

复现：`.codex-tmp/architecture_loading_probe.gd`；日志：`.codex-tmp/architecture-loading-probe.log`。探针同时记录到挂回节点的 owner 一致性警告，但加载后的 owner 正确，因此没有另行认定为场景保存丢失问题。

## 3. P2：正式目录与自动扫描同时控制关卡列表

- `ui/level_select/src/level_select.gd:142` 先添加固定的五张正式地图，再追加扫描到的其他地图。
- 这会把 Peak 固定在第五位，而不是整个列表最后；旧地图只要在磁盘重新出现，也会再次进入正式目录。
- 本次实际返回七张：扉页、第一页、第二页、第三页、peak、新地图1、第三关·墨泉边。
- 既有 `test/test_level_select.gd` 已失败。新建地图按钮也改变了按钮数量，旧 UI 断言需要区分“操作按钮”和“关卡按钮”。

影响：与之前要求的正式列表和 Peak 排序不一致；“删除过旧地图”不能保证旧地图不会重新出现在列表。

建议：建立独立的 `LevelCatalog`，区分正式路线和用户自建地图。正式路线、Peak 独立入口、自建地图排序、传送门选择菜单都读取这一份规则。保留新建地图功能时，应明确自建地图展示区域和 Peak 的最终位置，不能依靠两段 append 隐式决定。

证据：`.codex-tmp/architecture-level-list.log`。

## 4. P2：新增地图扫描漏掉导出后的 remap 场景

- `ui/level_select/src/level_select.gd:165` 只接收文件名以 `.tscn` 结束的条目，没有接收 `.tscn.remap`。
- `_has_player()` 虽然保留了“无源场景时用 ResourceLoader 检查”的分支，但额外地图在进入该函数前就会被扫描过滤掉。
- 固定五张地图按路径直接读取，因此不能用它们的成功证明自建地图导出也正确。

已通过临时 PCK 挂载一个只暴露 remap 的额外地图；它能加载、也有 Player，但不会列入目录：

```text
AUDIT_EXPORT exists=true has_player=true listed=false
```

建议：扫描时将 `.tscn.remap` 归一为原始 `.tscn` 路径并去重，或通过导出时生成的关卡清单发现地图。导出验收必须覆盖额外地图，不只覆盖固定地图。

复现：`.codex-tmp/architecture_export_probe.gd`；日志：`.codex-tmp/architecture-export-probe.log`。临时包只在该测试进程内挂载，没有在正式地图目录新增文件。

## 5. P2：UI 命中规则重复且已经分叉

- `ui/hud/blueprint/src/blueprint_system.gd:83` 全树扫描少数控件类型，没有检查父级裁剪区域。
- `debug/creative/src/creative.gd:375` 另外实现了一套命中检测，包含父级裁剪判定，但接受的控件范围更广。
- 画布输入与光标还依赖 `gui_get_hovered_control()`，又形成了第三种判据。

最小复现中，在一个开启裁剪的 Control 外放置 Button。按钮不在可见裁剪区域内，但蓝图检测仍然返回遮挡：

```text
AUDIT_UI clipped_out_button_blocks_blueprint=true
```

另一个普通 STOP Control 的探针返回 false。这不是建议把所有 STOP 布局节点都当成遮挡；那会重新引入整屏布局阻止绘画的旧问题。

影响：在包含滚动列表或裁剪面板的界面中，鼠标并未落在可见按钮上，仍可能取消蓝图放置；不同工具对同一点给出不同处理。

建议：抽取共享命中服务，统一可见性、裁剪链、Viewport、实际交互区域和布局透传规则；绘画、布局放置、蓝图放置和光标分别声明如何使用命中结果。

复现日志：`.codex-tmp/architecture-loading-probe.log`。

## 6. P2：零墨水容量与 HUD、耗尽事件的语义不一致

- 编辑器允许把任一颜色配额设为 0。
- `actor/player/src/ink_health.gd:52` 的 `reload_caps()` 直接夹取 `_ink` 并只发 `changed`，绕过统一写入口的 `depleted` 事件。
- 第 88 行 `ratio_of()` 在容量为 0 时返回 1，即 HUD 满格。
- `actor/player/src/fall_death.gd` 依赖 `depleted` 进入黑墨耗尽死亡，没有在每帧轮询黑墨余额。

实测把原本有墨的黑墨配额改为 0：

```text
AUDIT_QUOTA cap=0.0 ink=0.0 hud_ratio=1.0 depleted_events=0
```

影响：没有可用墨水但 UI 显示满格；通过配额重载归零与通过普通扣墨归零走不同的状态流。编辑态是否暂缓死亡可以单独定义，不能同时留下不一致的 HUD 和耗尽语义。

建议：明确“容量 0”表示禁用还是无限。若表示禁用，应显示空量或禁用态；若允许黑墨为 0，应统一处理退出编辑器后的生命状态。容量重载应复用数值变化事件规则，或明确提供独立的容量变化事件。

复现日志：`.codex-tmp/architecture-quota-probe.log`。此小型探针退出有引擎对象释放告警，不把它算作新增游戏泄漏结论。

## 冗余与可维护性

以下是重构建议，不等同于已复现的功能错误：

1. `debug/creative/src/creative.gd` 约 3641 行，同时管理 UI、输入、地图读写、物件放置、撤销、配额和编辑器切换。`canvas.gd` 约 1538 行，`canvas_surface.gd` 约 1813 行。这三份脚本是职责集中点，优先提取加载/保存、编辑历史和输入协调，再考虑细分工具，避免先改目录而不改职责。
2. 蓝图管理器每帧查找可用画布、工具栏每帧扫描画布组、历史按钮每帧刷新状态，存在重复发现和重复计算。可利用 `level_changed`、画布注册、选区变化及历史变化信号缓存结果；没有做性能基准，因此不声称它们当前一定造成可见卡顿。
3. `tools/validate_project.ps1` 只排除少数缓存目录，会继续扫描 `.codex-tmp`、`.level_backups`、构建副本和历史资源。用它检查整个工作目录容易混入旧路径、临时脚本和运行时生成路径，应按正式资源根与测试根分别校验。
4. `actor/monster/imported/bomb_side/validate_rig.gd:37` 仍加载不存在的 `res://main.tscn`。这是导入包的旧校验脚本，不是当前主游戏入口；应标为源包工具并修正使用说明，或迁移到测试工具目录。

## 未发现与检查边界

- 对 actor、ui、root、ink、debug、map、addons 下 244 份文本代码/资源做了直接 load/preload 和 ext_resource 字面量引用检查。
- 未发现整份 GDScript/Shader 内容完全相同的副本。
- 未发现字面量脚本依赖形成的强连通环；动态 load、鸭子类型调用与原生生命周期不在此静态结论之内。
- 固定字面量资源缺失命中一处，即上述导入包的旧校验入口。动态路径、运行时生成文件和文档示例不据此判断失效。
- 当前光标既有回归 47 项通过。此前的测试通过记录不能替代当前异步加载改动后的复测。
- 未运行会重建关卡、覆盖地图或导出发布包的工具；没有删除或调整用户当前工作区内容。

建议修复顺序：异步接口迁移 → 刚体/关节/机关就绪屏障 → 关卡目录规则及导出发现 → 统一 UI 命中 → 零配额语义 → 大脚本职责拆分与轮询优化。
