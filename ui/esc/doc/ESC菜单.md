# ESC 菜单

游戏内 ESC 覆盖层，作为 `map/main.tscn` 的 `Esc` 节点实例（CanvasLayer，layer=2）。

- `process_mode = 3`（ALWAYS）：暂停后仍要收 ESC 与按钮输入。
- 打开即 `get_tree().paused = true`；「继续」「回主菜单」「退出」都先解除暂停再动作，
  否则回主菜单会把暂停态带进新场景。
- 按钮沿用主菜单那套黑描边纸片样式，但底色不透明：它是盖在游戏画面上的，
  参考里 0.9 半透明的按钮会把下面的场景透出来。

按钮没有图标资源，只有「继续」「退出」带图标（`asset/icon_play.svg`、`asset/icon_exit.svg`）；
「回主菜单」纯文字。
