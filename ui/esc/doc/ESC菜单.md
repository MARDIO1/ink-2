# ESC 菜单

游戏内 ESC 覆盖层，作为 `ui/game_ui.tscn` 的 `Esc` 节点实例（CanvasLayer，layer=20，压过 HUD 的 1）；
`game_ui.tscn` 由 `root/root.tscn` 挂在 `UI` 容器下。

- `process_mode = 3`（ALWAYS）：暂停后仍要收 ESC 与按钮输入。
- 打开即 `get_tree().paused = true`；「继续」「回主菜单」「退出」都先解除暂停再动作，
  否则回主菜单会把暂停态带进新场景。
- 面板与按钮全部走共享 Theme（`ui/theme/asset/ink_attack_theme.tres`，`CardPanel` / `OverlayPanel` /
  `PrimaryButton` / `DangerButton`），场景里不再写死颜色。
- 「回主菜单」是普通 Button（即次要样式）；「退出」用 `DangerButton`。退出图标是 `ui/esc/asset/exit.tres`（跟 HUD 右上角同一张图）。

## 重新开始

- 游玩模式显示「重新开始」按钮，重新读取当前地图保存文件，丢弃运行时修改、机关状态和复活记录。
- 地图编辑模式按钮置灰，直接调用重启接口也不会卸载或保存编辑文档。
- 菜单只负责按钮和关闭暂停；`root/src/level_restart.gd` 负责判断当前模式与确定来源文件，Root 的现有关卡加载流程负责实际重载。
- 重启使用 `CACHE_MODE_IGNORE` 重读场景及内嵌资源，避免沿用此前加载的地图缓存；开始过渡前先关闭暂停菜单，加载完成后恢复游玩。
- 对话框在 `_input` 阶段消费 Esc，菜单在 `_unhandled_input` 阶段接收，因此一次按键不会同时跳过对话并暂停。

## 操作说明

帮助页由 `ui/esc/src/help_page.gd` 独立构建，按「游玩、绘制、蓝图、编辑」分页，各页可滚动查看。说明包含当前的抓握、绘制与固化、框选旋转、蓝图放置、地图物件与文本编辑、保存，以及暂停恢复操作；菜单脚本只负责打开、返回和暂停状态。
