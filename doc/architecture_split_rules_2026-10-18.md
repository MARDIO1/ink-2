# 架构拆分修改细则（2026-10-18）

本细则落实 `doc/architecture_split_review_2026-10-18.md`，用于后续逐项实施。本次只编写细则，尚未执行下面的代码迁移。

## 1. 修改范围与不可改变的行为

### 1.1 允许修改

- 编辑器功能归属、窗口构建、动作分发和状态展示。
- 蓝图外围脚本的位置与资源引用。
- 关卡目录查询、传送门调用关系、地图运行脚本的归属。
- 共享角色表现的输入参数、外部私有字段访问、重复 UI 命中逻辑。
- 对应文档、现有测试及项目校验脚本。

### 1.2 冻结范围

- `addons/**`、引擎快照、原生源码及 DLL 不修改、不重编译、不升级。
- `ink/**` 不修改；各色墨水配方、参数、消耗、供能、连接、破坏、回收和固化机制不修改。
- `actor/nail/**`、`actor/ink_item/**`、`canvas_solid.gd`、物理提交链及模拟规则本轮不迁移、不重写。
- 蓝图放置代码允许整体移动，但不能顺便重写其耗墨、预检、轴承/导线恢复和历史事务。
- 大盾的骨骼、脚部偏移、攻击、回弹和四子步稳定性修复保持原样。
- `.inkbp` 格式、关卡已有导出属性、节点组名、节点名和 UID 不随意更改。

### 1.3 拆分必须保持的不变量

1. 普通保存保留草稿和实体，不触发固化、墨化、清空历史或工具切换。
2. F2 试玩不把运行损伤和位姿写回编辑文档，返回时恢复原文档。
3. 一次用户操作仍只形成一个可撤销事务；画布自身历史由编辑器唯一时间线协调。
4. 切工具、失焦、退出编辑器和切关均正确结束或取消拖动，释放相机锁。
5. 加载依赖继续等待 `body_bake_completed`；`level_changed` 仍在关卡就绪后发送。
6. 不能通过吞异常、默认成功、跳过断言或削弱门槛让迁移“通过”。

## 2. 目标文件归属

| 现有文件/职责 | 最终位置 | 操作 |
| --- | --- | --- |
| `blueprint/src/blueprint_place.gd` | `actor/canvas/blueprint/src/blueprint_place.gd` | 连同 `.uid` 整体移动 |
| `blueprint_format.gd`、`blueprint_store.gd` | 仍在 `blueprint/src/` | 保持，不搬进 Actor/HUD |
| `blueprint_codec.gd`、`blueprint_placement.gd`、幽灵场景 | 仍在 `actor/canvas/blueprint/` | 保持，更新 Place 引用 |
| Creative 小怪变换、拖动行为 | 现有 `features/monster_tools.gd` | 补全现有工具 |
| Creative 对话、文字、图片的文档操作 | `features/dialogue_tools.gd`、`map_text_tools.gd`、`image_tools.gd` | 每个领域一个工具，不按每个函数建文件 |
| Creative 对话、文字窗口 | `ui/src/editor_dialogue_view.gd`、`editor_text_view.gd` | 每个窗口集中管理自己的控件 |
| Creative 复活区、画布尺寸窗口 | `ui/src/editor_layout_view.gd` | 合并为同一布局表单实现，避免两个小型 Manager |
| `debug/creative/src/map_dialogue_trigger.gd` | `map/src/map_dialogue_trigger.gd` | 连同 `.uid` 移动 |
| `debug/creative/src/map_imported_image.gd` | `map/src/map_imported_image.gd` | 连同 `.uid` 移动 |
| 选关页的目录、路线、场景判定 | `map/src/level_catalog.gd` | 提取已有纯查询 |
| 选关页的新建地图写盘 | `map/src/level_creation.gd` | 提取实际写盘操作 |
| 两套按事件坐标检测 UI 的算法 | `ui/input/src/ui_hit_test.gd` | 一个无状态脚本，不挂全局单例 |

`map/` 中这些脚本随关卡内容存在，不新增假的 Actor 入口。跟随画布的工具栏、色盘和幽灵继续留在画布模块；不能因包含 UI 控件就全部移往屏幕 HUD。

## 3. 分批执行细则

### 第 0 批：固定基线、纠正文档目标

**修改文件：** 两份模块架构文档、`doc/文件组织.md`、Creative 中已经失真的保存注释。

- 明确蓝图核心只有数据格式、校验和存储；画布放置属于画布适配。
- 删除“codec 仍依赖 HUD”“保存先 generate”等失效现状描述，历史事实留在历史记录中。
- 将本轮明确冻结的 Nail/InkItem 等旧债标记为延期，不用假场景填补规则。
- 记录现有工作区状态及基线结果，后续只比较本批涉及文件；不能用还原整个目录清理用户改动。

**完成条件：** 文档中的现状、目标结构和阶段表互相一致，代码行为不变。

### 第 1 批：修正蓝图依赖方向

**操作：** 移动 Place 脚本及 `.uid`，保持函数签名和函数体原样。

必须更新的生产调用方：

- `actor/canvas/blueprint/src/blueprint_placement.gd`。
- `ui/hud/blueprint/src/blueprint_system.gd`。

必须搜索并更新的测试调用方包括：`test_blueprints.gd`、`test_editor_player_absence.gd`、`test_gear_manual_centers.gd`、`test_manual_bearing_contract.gd`、`test/tools/baseline_editor.gd`；实施时以递归搜索实际结果为准。

**依赖规则：**

```text
HUD 蓝图界面 → 画布蓝图（采集、预览、放置） → 蓝图格式/存储
blueprint/src 不得依赖 actor/、ui/、debug/
画布蓝图不得依赖 HUD 蓝图界面
```

允许画布适配继续调用现有墨水能力，不能把现有机制代码复制一份到新目录。删除旧路径，不保留纯转发兼容脚本；历史用户蓝图文件不受脚本路径迁移影响。

**验收：** 新路径可加载；旧生产路径引用归零；既有蓝图事务、连接独立、撤销重做测试和编辑器基线通过。

### 第 2 批：把 Palette 改成只展示、只发动作的视图

**修改文件：** `debug/creative/ui/src/editor_palette.gd`、Creative 的动作绑定位置；必要时使用现有 Canvas 公开操作，不修改 Surface 算法。

逐项替换：

| 当前操作 | 调整方式 |
| --- | --- |
| `_map_canvas.set_brush_size(...)` | 发 `set_brush_size` 动作，由装配点调用已有 Canvas 方法 |
| 直接调用 `select_ink(...)` | 发 `select_ink` 动作，显示从选中变化事件回填 |
| 连接 `_on_nail_visibility_toggled` | 发 `set_nails_visible` 动作，调用既有显示操作 |
| 访问 `brush_panel/PenSlider` 同步另一控件 | 初始化传入最小/最大/步长/当前值；后续通过值变化更新显示 |
| 直接读取私有工具字段 | 传入视图所需的明确显示值，或使用已有查询 Callable |

保留现有 `action_requested(action, arguments)`，不另造事件总线。动作名描述用户意图，不再直接使用 `_open_*` 等私有函数名作为新增动作协议。更新显示使用不再次发出用户动作的方式，避免两个滑块互相触发。

**验收：** 视图不写 Canvas/Surface 状态、不调用其私有方法、不寻找画布内部控件。笔宽、颜色、钉子显示和快捷键行为一致，每次用户操作只处理一次。

### 第 3 批：先补完小怪工具，再提取其余文档工具

#### 3.1 小怪：补全现有 monster_tools

从 Creative 迁出 `_resize_selected_monster`、`_reset_selected_monster_scale` 中的变换计算与物理同步；迁出拖动目标位置计算及开始/完成/取消所需的会话更新。

建议最小接口：`resize(target, amount)`、`reset_scale(target)`、`begin_drag(session, target, position)`、`update_drag(session, position)`、`finish_drag(session)`、`cancel_drag(session)`。名称可沿项目现有命名调整；不要同时保留两套状态。

- 返回变换前/后的最小记录，由现有历史记录入口提交一次。
- session 保存当前目标、起始变换和进行中状态；工具不持有 Creative 或历史栈。
- 相机锁定/解锁由 Creative 的装配协调保留；工具不通过节点路径查找相机。
- 保持当前缩放下限、以脚底放置、编辑暂停和 `sync_physics_from_node(true)` 行为，不改小怪物理控制。

#### 3.2 对话、文字、图片：每个领域只提取真实文档行为

| 工具 | 迁出 Creative 的函数族 | 入参/返回原则 |
| --- | --- | --- |
| dialogue_tools | `place_dialogue_trigger`、拾取/按 ID 查找/移除、ID 分配 | 接收容器、位置、台词、ID；返回节点或操作结果 |
| map_text_tools | `place_map_text`、拾取/按 ID 查找/移除、ID 分配 | 接收容器、位置、文字和已有样式参数 |
| image_tools | `_restore_deleted_image`、图片枚举/拾取/删除 | 接收容器、原始图像字节、格式、位置与缩放 |

容器创建、场景 owner 设置与历史记录必须明确归属：本批先保留 Creative 现有容器装配，工具接收现成容器。恢复对象时保留 editor_id，继续由现有命令层 rebind 历史目标。不能只重新创建外观而丢失撤销对象身份。

#### 3.3 窗口：布局和表单验证回到 ui

- 对话窗口迁出 `_build_dialogue_input_window`、行输入控件创建与提交/取消控件处理。
- 文字窗口迁出 `_build_text_input_window` 及对应表单控件处理。
- 布局窗口集中复活区宽高/偏移、画布尺寸的表单构建。
- 窗口只发确认数据；放置/修改由对应工具执行，历史由现有命令入口记录。
- 关闭、取消和失焦不提交文档变更；普通文本编辑的校验不要做成新通用表单框架。

**本批验收：** 布局、小怪拖动/缩放、对话、图片、混合撤销重做通过；功能模块不反向寻找 Creative，未新增历史栈。Creative 是否变短只能作为辅助指标，不能代替职责验收。

### 第 4 批：运行脚本离开 debug

移动地图对话触发和图片显示脚本及 `.uid`，更新 Creative、对应测试及所有地图资源的脚本引用。

- 对话触发的玩家检测、已触发状态、台词顺序保持；编辑用预览仍由编辑器开关协调。
- 图片的 source_data、source_format、original_filename、GIF 帧与延迟保持，地图仍不依赖导入时外部原文件。
- 不修改保存节点名称、导出属性和组，不重新生成整张正式地图；资源只做必要引用更新。
- 导入窗口、选框、调节操作继续留在 debug；运行脚本不再加载编辑窗口。

**验收：** 关闭创造模式仍能触发对话、显示静态图和 GIF；地图重进、图片删除撤销与编辑拾取通过；旧运行脚本路径在正式资源引用中归零。

### 第 5 批：从选关 UI 提取关卡目录与创建逻辑

**level_catalog.gd：** 提取 `LEVEL_PATHS` 中的目录数据、`find_levels()`、`_scan_map_levels()`、`next_level()` 和 `_has_player()`；对外使用明确的 `has_player()` 或 `is_level()`，Portal 不调用私有函数。查询不得实例化地图、写盘或创建按钮。

**level_creation.gd：** 接管 `create_blank_map()`、`_strip_scene_uid()`、新文件名选择与模板写盘。只有用户执行新建动作才调用，浏览目录不写文件。

**更新调用方：** 选关界面、Portal、Creative 的传送目标列表及引用旧查询方法的测试。选关界面继续管按钮、加载反馈、滚动和失败提示，Root 继续管异步加载生命周期。

先做保持行为的提取；下面的既有行为问题必须另作一片修正，不混进路径搬迁：

1. `.tscn.remap` 归一为 `.tscn`，去重后交给 ResourceLoader 验证；保留源码场景与导出场景的查询分支。
2. 明确正式页路线为“扉页 → 第一页 → 第三页”；第三页不自动进入 Peak，Peak 只作独立入口。当前 `next_level()` 的固定索引边界需针对该规则检查并修正。
3. 自建地图独立整理并去重；关卡列表要求 Peak 最后时，必须在追加自建地图之后放 Peak，不能只依赖固定数组位置。

**验收：** Portal 无 UI 脚本依赖；路线终点正确；用户新地图不漏、不重复；临时 PCK 中只有 remap 的额外地图也能被发现；验证输出写临时位置，不改用户正式地图。

### 第 6 批：收尾调用契约和保存依赖

#### 6.1 私有编辑状态

- 光标不再读 `_monster_mode`、`_dragging_monster`、`_layout_drag_target`；提供一个只表达光标需求的公开查询，例如 `editor_object_tool_active()`。
- 历史按钮使用已有可撤销/可重做查询，不取内部栈；内部栈的真实写入仍由原历史实现管理。
- 新调用方不得读取 `_session` 或内部控件。先迁移生产调用，再按实际需求迁移测试。
- 只删已经无消费者的代理属性；不要把仍用于旧资源反序列化的字段一并清掉。

#### 6.2 保存

- `editor_save.gd::pack_playable()` 不再 `get_node_or_null("Creative")`。
- 由 Creative/Root 的装配调用处向现有 ctx 明确传入草稿承载节点和画布；保存模块不自行猜场景拓扑。
- 草稿仍使用原有 `capture_document()`；临时覆盖的值在 pack 后恢复，失败也不能留下编辑布局或空快照路径。
- 不新增存档格式，不删除旧 sidecar 读取支持，不改正常保存的可见效果和自动保存节流。

#### 6.3 UI 命中

- 提取一个无状态 `blocks_world_input(viewport, point)` 查询，处理当前事件位置、可见性、视口、交互控件与裁剪链。
- 控件是否能阻挡需有明确规则：可交互控件和明确标记的阻挡面板参与；全屏透明布局容器不自动阻挡。
- Creative 与蓝图调用共享几何判定；各自的模态/放置状态仍在调用方判断。
- `gui_get_hovered_control()` 适合的显示查询可保留，不能拿上一帧悬停结果替代同帧鼠标事件坐标。

**验收：** 状态查询能覆盖原光标行为；保存、F2、历史按钮通过；UI 的同帧点击、裁剪、透明布局和模态窗口不穿透、不误拦截。

### 第 7 批：共享表现与规范整理

**死亡表现：** Player/Monster 各自把实际部件转换为表现记录，传给 general；记录至少提供 source、role、mask_texture，以及现有裁剪/面部等效果需要的明确参数。复用现有 pieces 数据组织，不建新的表现管理器。

`character_death.gd` 不再从 `/Arm/`、BodyBone、ShieldArt、BombArt 等路径/名称推断角色结构。角色自己的路径判断留在自己的模块。先保持 Style 与时长不变，不在同一片顺便改动画或 shader 算法。

**规范：** 本轮修改的脚本按职责补齐 region，函数注释简短说明用途或必要不变量。没有实质职责可分时，不为了凑 region 或函数数量增加包装。

**校验：** 在 `tools/validate_project.ps1` 增加明确资源根和少量依赖规则，正式资源、测试、导入工具分组报告；排除 `.codex-build`、`.codex-tmp`、`.level_backups`、缓存、输出副本。检查蓝图核心反向依赖、旧迁移路径和缺失固定引用，不能对包含示例文本的注释直接报架构错误。

**验收：** 各角色死亡/复活表现保持；共享实现不识别具体骨骼树；校验可发现真实违规，不因临时副本产生大量噪声。

## 4. 验收安排

| 批次 | 优先复用的现有检查 | 必须观察的结果 |
| --- | --- | --- |
| 每批 | 相关脚本解析检查、`baseline_editor.gd` | 无解析/运行错误，保留原断言 |
| 蓝图 | `test_blueprints.gd`、`test_blueprint_ui.gd`、`test_editor_player_absence.gd` | 预检失败无残留，放置/撤销/重做一致，连接不共享 |
| Palette/窗口/命中 | `test_ui_interactions.gd`、`test_ui_ppt_editor_controls.gd`、`test_game_cursor.gd`、`test_game_cursor_placement.gd` | 动作一次、UI 不穿透、工具与提示一致 |
| 工具 | `test_monster_editor_drag.gd`、`test_monster_resize.gd`、`test_editor_layout_tools.gd`、`test_editor_record_redo.gd`、`test_creative_image_import.gd` | 变换、取消、ID 与混合历史一致 |
| 运行归属 | `test_dialogue_trigger_editor_state.gd`、`test_map_image_import.gd`、正式地图运行抽查 | 编辑界面关闭后功能仍有效 |
| 关卡目录 | `test_level_select.gd`、`test_level_select_click.gd`、`test_map_portal.gd`，补 remap 场景检查 | 路线、排序、导出发现一致 |
| 保存 | `test_editor_document.gd`、`test_editor_reload_lifecycle.gd` | 草稿与实体无损，普通保存保留历史，F2 不污染文档 |
| 表现 | `test_character_death.gd`、既有死亡预览 | 遮罩、层级、部件与原版一致 |

以上是待执行门禁，不表示这些脚本当前全部通过。旧齿轮/旧画布 API 的测试需先核对现有契约，不能为迁就旧测试恢复废弃机制；必要时只更新夹具与调用方式，保留有效行为断言。

复核阶段已有记录：编辑器基线 43/43、文档往返 32/32；基线退出有 16 个 ObjectDB 实例泄漏告警。后续比较告警是否增加，单独归因，不把它自动归咎于引擎，也不为追求零告警修改受保护代码。

## 5. 每批交付和完成判定

每批独立形成可审查的改动，附：修改文件、职责变化、调用方向、运行命令、通过/失败结果和已知限制。纯移动与行为修正分开，后续发现问题时只回退本批改动，不覆盖用户同期修改。

最终完成必须同时满足：

- [ ] 引擎、DLL、`ink/` 及冻结机制文件没有本轮改动。
- [ ] 蓝图核心无 Actor/UI/Debug 反向依赖，旧 Place 引用清理。
- [ ] Palette 不直接修改画布，Creative 不再构建各领域窗口或执行整套领域操作。
- [ ] 正式运行的对话触发和图片实现不放在 debug。
- [ ] Portal 不依赖选关 UI，关卡查询和用户新建写盘分离。
- [ ] 外部不再读取 Creative 私有会话字段，未留下无用途兼容转发。
- [ ] 保存不反向查找 Creative，草稿/实体/试玩行为未变。
- [ ] 通用表现不依赖具体骨骼命名，UI 命中重复逻辑已收敛。
- [ ] 相关文档、UID、引用、规范和验证结果与实现一致。

不以“文件减少了多少行”作为最终验收，不在本轮附带性能重写、墨水机制优化、引擎修复或大规模测试框架建设。
