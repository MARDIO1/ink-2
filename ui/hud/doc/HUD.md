# HUD

游戏内 HUD，作为 `map/main.tscn` 的 `Hud` 节点实例（CanvasLayer，layer=1）。
墨水瓶是血条位（图标仍是静态贴图）、横条是蓝条数值位。
右上角退出按钮回主菜单。

## 横条数据源

`hud.gd` 的 `health_path`（默认 `^"../Player/InkHealth"`）指向玩家墨水生命值节点
`actor/player/src/ink_health.gd`。`_ready()` 里连 `changed` 并读一次 `ratio()`，
以后每次 `add()` / `reduce()` 都把 `StatusBar.value` 设成 `ratio() * 100`。
接不到节点（单独预览 `hud.tscn`）时才退回 `bar_ratio` 占位。
墨水值本身的接口见 `actor/player/doc/生命值.md`。


## 与调试 HUD 的关系
Tab 在两套之间切换：`hud.gd` 读 `debug` 动作，把 `debug_hud_path`（默认 `../debugHUD`，即
`map/main.tscn` 里那个改名后的旧调试 HUD）显隐取反，自己取反、`force_debug` 采样同步开关。
默认成品 HUD 开、debugHUD 关。调试 HUD 的脚本是 `map/src/debug_hud.gd`，它自己不再处理 Tab。

⚠️ Tab 必须走 `_input`，不能走 `_unhandled_input`：画布工具按钮（`Canvas/Buttons/Brush` 等 6 个
`Button`，默认 `focus_mode=FOCUS_ALL`）点过之后会占住键盘焦点，此时 Godot 的 GUI 会把 Tab 当内置
`ui_focus_next` 吃掉并标记已处理，`_unhandled_input` 永远收不到 —— 表现就是「Tab 调试 UI 没了」。
`hud.gd` 现在在 `_input` 里处理并 `set_input_as_handled()`，焦点在谁身上都不影响。
（若以后想让 Tab 恢复焦点导航，替代做法是给那 6 个工具按钮设 `focus_mode = 0`。）

## 尺寸与横条位置

同主菜单的 s≈0.2344 等比缩放（退出按钮图标宽 170→40、边框 10→2、圆角 4→1、焦点外扩 10→2）。

横条锚点取 0.2245..0.7055 是**按 `HealthFrame` 的实际绘制框算的**，不是照抄参考的 0.185..0.741：
frame 源图 1710×260（比例 6.577），锚点框 0.16..0.77 × 0.04..0.17（逻辑 585.6×70.2），
`stretch_mode=5` 等比装填后绘制框只有 70.2×6.577≈461.8 宽、左右各内缩 (585.6-461.8)/2≈61.9，
即绘制框左边界 = 0.16×960+61.9 = 215.5 = 0.2245×960。本工程 16:9 与参考 16:10 不同，
不改的话黑填充会从 frame 左侧冒出来。

实测（真实 `map/main.tscn`，960×540 逻辑）：`StatusBar.get_global_rect()` = (215.52, 32.94, 461.76, 39.96)，
与上式逐位相同。

## 热键

- `F1`（动作 `record_low_frames`，`project.godot:83-86`）：开始/停止低帧录制，处理在 `map/src/debug_hud.gd:113-115` → `_toggle_log()`（`:28-48`）。
  只写帧耗时超过 1000000/24 µs 的帧，每轮一个 `res://test/low_frames_<时间戳>_<usec>.jsonl`；
  录制期间同步开损伤/力采样，标签第二行追加「F1 录制中 | 已记录 N 个低帧」（`:156-157`）。
  另有自动保护：连续 2 帧 ≥ 500 ms 时把现场写到 `user://hang_<时间戳>.jsonl` 并 `quit(2)`（`:92-110`）。
  ⚠️ 录制同时 `forces.set_profile_enabled(true)`，而力采样本身默认就是开的（`force_debug.gd:5` 默认 `enabled=true`，`main.tscn:81-82` 没覆盖，`hud.gd:16-18` 只关 `visible`）：尖峰帧里它占约 1/4（实测 1863 帧 76.2 / 321.9 ms）。读日志时把「物理」和「调试采样」分开算。
- `Tab`（动作 `debug`）：在成品 HUD 与调试 HUD 之间切换，见上节。
