extends RefCounted
## 编辑器模式常量：**唯一真源**。
##
## `src/creative.gd`（逻辑）和 `ui/src/editor_palette.gd`（视图）都从这里取。
## 之前两边各存一份整数表，加模式时容易只改一边、静默漂移。
##
## 这些负数塞在同一个 `_monster_mode` 里，是历史包袱（4 个互不相关的功能族共用一个状态）。
## 迁移到 `editor_session.gd` 之前，至少保证只有这一份定义。

const MONSTER_MODE_NONE := -1
const MONSTER_MODE_DELETE := -2
const MONSTER_MODE_ADJUST := -3
const DIALOGUE_MODE_PLACE := -4
const DIALOGUE_MODE_DELETE := -5
const TEXT_MODE_PLACE := -6
const TEXT_MODE_DELETE := -7
const LAYOUT_MODE_MOVE_SPAWN := -8
const LAYOUT_MODE_PLACE_RESPAWN := -9
const LAYOUT_MODE_MOVE_RESPAWN := -10
const LAYOUT_MODE_PLACE_CANVAS := -11
const LAYOUT_MODE_MOVE_CANVAS := -12
const CONTROL_MODE := -13
const LAYOUT_MODE_PLACE_PORTAL := -14
const LAYOUT_MODE_DELETE_PORTAL := -16
const LAYOUT_MODE_FOUNTAIN := -17
const LAYOUT_MODE_DELETE_CANVAS := -18
const LAYOUT_MODE_DELETE_RESPAWN := -19

## 这些模式都属于"布局编辑"，走同一套鼠标处理。
const LAYOUT_MODES := [
	LAYOUT_MODE_MOVE_SPAWN,
	LAYOUT_MODE_PLACE_RESPAWN,
	LAYOUT_MODE_MOVE_RESPAWN,
	LAYOUT_MODE_DELETE_RESPAWN,
	LAYOUT_MODE_PLACE_CANVAS,
	LAYOUT_MODE_MOVE_CANVAS,
	LAYOUT_MODE_DELETE_CANVAS,
	LAYOUT_MODE_PLACE_PORTAL,
	LAYOUT_MODE_DELETE_PORTAL,
	LAYOUT_MODE_FOUNTAIN,
]
