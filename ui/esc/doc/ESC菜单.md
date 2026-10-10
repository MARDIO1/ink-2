# ESC 菜单

游戏内 ESC 覆盖层，作为 `ui/game_ui.tscn` 的 `Esc` 节点实例（CanvasLayer，layer=20，压过 HUD 的 1）；
`game_ui.tscn` 由 `root/root.tscn` 挂在 `UI` 容器下。

- `process_mode = 3`（ALWAYS）：暂停后仍要收 ESC 与按钮输入。
- 打开即 `get_tree().paused = true`；「继续」「回主菜单」「退出」都先解除暂停再动作，
  否则回主菜单会把暂停态带进新场景。
- 面板与按钮全部走共享 Theme（`ui/theme/asset/ink_attack_theme.tres`，`CardPanel` / `OverlayPanel` /
  `PrimaryButton` / `DangerButton`），场景里不再写死颜色。
- 「回主菜单」是普通 Button（即次要样式）；「退出」用 `DangerButton`。退出图标是 `ui/esc/asset/exit.tres`（跟 HUD 右上角同一张图）。
