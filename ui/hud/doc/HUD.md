# HUD

游戏内 HUD，作为 `ui/game_ui.tscn` 的 `Hud` 节点实例（CanvasLayer，layer=1，根控件挂共享 Theme）。
`game_ui.tscn` 由 `root/root.tscn` 挂在 `UI` 容器下，所以 HUD 与关卡不在同一棵子树。
**瓶内液面 = 墨水量**（`Root/BottleFill`，`TextureProgressBar` + `fill_mode=3` 自下而上 +
`ui/hud/asset/bottle_fill.svg` 当瓶形遮罩），瓶身线稿 `Root/HealthArt`
（`ui/hud/asset/health_hud.tres`）盖在液面之上；顶部横条已取消，不再表示任何数值。
右上角 `Root/ExitButton`（`ui/esc/asset/exit.tres`）回主菜单。

## 横条数据源

`hud.gd` 的 `health_path`（默认 `^"../Player/InkHealth"`，找不到就按 `player` 组找）指向玩家墨水生命值节点
`actor/player/src/ink_health.gd`。`_ready()` 里连 `changed` 并读一次 `ratio()`，
以后每次 `add()` / `reduce()` 都把 `BottleFill.value` 设成 `ratio() * 100`。
接不到节点（单独预览 `hud.tscn`）时才退回 `bar_ratio` 占位。
墨水值本身的接口见 `actor/player/doc/生命值.md`。

左上角（瓶子图标正下方）的 `InkMeter`（`ui/hud/hud.tscn` 的 `Root/InkMeter`）读同一份
`InkHealth`，显示**当前剩余**墨水「墨水 N px」= `ink`。接不到墨水源时显示「墨水 -- px」。

⚠️ 这里只显示瓶子自己的余量，**不显示"已消耗"**：画布以后会有多张，各张画布自己记
「我身上有多少墨」，全局的"消耗量"在屏幕上没有意义（详见 `actor/canvas/doc/画布.md`
的「墨水账」）。


## 与调试 HUD 的关系
Tab 在两套之间切换：`hud.gd` 读 `debug` 动作，把 `debug_hud_path`（默认 `../debugHUD`，即
`map/main.tscn` 里那个改名后的旧调试 HUD）显隐取反，自己取反、`force_debug` 采样同步开关。
默认成品 HUD 开、debugHUD 关。调试 HUD 的脚本是 `debug/hud/src/debug_hud.gd`，它自己不再处理 Tab。

⚠️ Tab 走 `_input` 而不是 `_unhandled_input`：画布工具按钮一旦占住键盘焦点，Godot 的 GUI 会把 Tab
当内置 `ui_focus_next` 吃掉并标记已处理，`_unhandled_input` 永远收不到 —— 表现就是「Tab 调试 UI 没了」。
现在两头都堵住了：`hud.gd` 在 `_input` 里处理并 `set_input_as_handled()`；新工具面板的 8 个按钮
（`actor/canvas/canvas.tscn` 的 `WorkbenchUI/Buttons/Grid/*`）全部 `focus_mode = 0`。
Tab 不再参与焦点导航。

## 尺寸

瓶子按固定像素摆（`BottleFill` 24,16→156,172；`HealthArt` 24,16→596,172），来源是分支那套
`ui/hud/hud.tscn` 的绝对布局，不再用等比锚点；`texture_filter = 1`（最近邻）写在节点上
（项目没有开全局 nearest）。

## 热键

- `F1`（动作 `record_low_frames`，`project.godot:113-117`）：开始/停止低帧录制，处理在 `map/src/debug_hud.gd:113-115` → `_toggle_log()`（`:28-48`）。
  只写帧耗时超过 1000000/24 µs 的帧，每轮一个 `res://test/low_frames_<时间戳>_<usec>.jsonl`；
  录制期间同步开损伤/力采样，标签第二行追加「F1 录制中 | 已记录 N 个低帧」（`:156-157`）。
  另有自动保护：连续 2 帧 ≥ 500 ms 时把现场写到 `user://hang_<时间戳>.jsonl` 并 `quit(2)`（`:92-110`）。
  ⚠️ 力采样（`force_debug.gd:5` 的 `enabled`，默认 `true`）由 Tab 同步：`hud.gd` 的 `_ready` 把它关掉，只有切到调试 HUD 才开 —— 正式游玩不再为它付钱。调试 HUD 关着时按 F1，日志里的力字段是空的；开着的尖峰帧里它占约 1/4（实测 1863 帧 76.2 / 321.9 ms），读日志时把「物理」和「调试采样」分开算。
- `Tab`（动作 `debug`）：在成品 HUD 与调试 HUD 之间切换，见上节。
