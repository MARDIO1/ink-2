extends RefCounted
## 编辑器交互态：当前模式 + 正在进行的拖动 / 选中。
##
## **只存状态，不含行为**。行为仍留在 `creative.gd`，等 P2 把 layout / monster 工具
## 搬成独立模块时，它们只需要这一个 session，不必再开一排端口。
##
## 这些字段原本散在 `creative.gd` 的状态区里，和 UI 代理、导出配置混在一起。

const Modes := preload("res://debug/creative/application/editor_modes.gd")

## 当前工具。取值见 `editor_modes.gd`（负数常量，历史包袱，P4 换掉）。
var mode := Modes.MONSTER_MODE_NONE

#region 小怪编辑
var selected_monster: Node2D = null
var dragging_monster := false
var drag_offset := Vector2.ZERO
var drag_start_position := Vector2.ZERO
var drag_start_scale := Vector2.ONE
## 拖动期间锁住视图与手部：避免相机跟随把目标甩走。
var monster_drag_view_locked := false
var monster_drag_inverse := Transform2D.IDENTITY
var pending_monster_move: Node2D = null
var drag_player_states: Array[Dictionary] = []
var drag_hand_control: Node = null
var drag_hand_mode := Node.PROCESS_MODE_INHERIT
#endregion


#region 布局拖动与选中
var layout_drag_target = null
var layout_drag_offset := Vector2.ZERO
var layout_drag_start := Vector2.ZERO
var layout_drag_start_scale := Vector2.ONE
var layout_drag_resizing := false
var selected_control_target = null
var selected_portal: Node2D = null
#endregion
