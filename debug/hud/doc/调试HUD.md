# 调试 HUD

`debug/hud/debug_hud.tscn`（CanvasLayer + `Stats` Label + `ForceDebug`），脚本在 `src/`。

- **挂在哪**：由**关卡**实例（`map/main.tscn` 的 `debugHUD` 节点）。它要读 `../Player/...`、
  `../CollisionDamage`，也要在世界坐标里画力箭头，所以它是"关卡的调试覆盖层"，不是全局 UI ——
  不放 `ui/`（`ui/` 只放玩家看的成品 UI，见 `ui/game_ui.tscn`）。
- **开关**：成品 HUD 的 Tab（输入动作 `debug`）与它互相取反（`ui/hud/src/hud.gd:_switch_debug_hud`）。
  两个节点原本是兄弟，现在 HUD 在 `UI` 容器、调试 HUD 在关卡里，所以 HUD 用**组 `debug_hud`**
  兜底查找（场景根节点挂着这个组）。
- **面板内容**：FPS / 1% low（`low_window` 秒滚动窗）/ CPU ms / 子步数 / 手与脚的功率与力 / Q 状态。
- **力箭头**（`force_debug.gd`）：接触冲量按固定步累加，手 P、手 D、脚 AD、跳跃、重力、
  约束余项分别上色（顶部两行是图例）。`enabled` 由 Tab 同步；`force_scale` 只影响画面。
  `map/src/collision_damage.gd` 用 `get_node_or_null("../debugHUD/ForceDebug")` 拿它做 profiling。
- **F1 低帧录制**：`res://test/low_frames_<时间戳>_<usec>.jsonl`，只记帧耗 > 1/24 s 的帧，
  每行含 bodies / joints / 物理与力的 profile（录的时候同时打开 damage/forces 的 profile）。
  ⚠️ 它写在 `res://test/`（工程目录）里 —— 想更干净应改 `user://`，本轮未改（会牵动 `test/` 的约定）。
- **卡死看门狗**：连续 `hang_frames` 帧超过 `hang_frame_ms` 就存一份现场到 `user://hang_*.jsonl`
  并 `quit(2)`，避免物理追帧把实例拖到关不掉。
