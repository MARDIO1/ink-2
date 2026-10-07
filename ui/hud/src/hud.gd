extends CanvasLayer
## 成品 HUD：横条（血条/蓝条位）显示玩家墨水量，数据来自 Player/InkHealth。
## Tab 在成品 HUD 与 debugHUD 之间切换。

const MENU_SCENE := "res://ui/menu/menu.tscn"

## 接不到墨水源时横条的静态占位比例，0-1。
@export_range(0.0, 1.0, 0.01) var bar_ratio: float = 0.72
## 玩家墨水生命值节点的相对路径（本节点是 Main 的子级）。
@export var health_path: NodePath = ^"../Player/InkHealth"
## 调试 HUD 的相对路径；Tab 切换时用它决定显隐。
@export var debug_hud_path: NodePath = ^"../debugHUD"

@onready var status_bar: ProgressBar = $Root/StatusBar
@onready var ink_meter: Label = $Root/InkMeter
@onready var debug_hud = get_node(debug_hud_path)

var _health = null


func _ready() -> void:
	debug_hud.visible = false
	_health = get_node_or_null(health_path)
	if _health != null:
		_health.changed.connect(_refresh_bar)
	_refresh_bar()


## 横条 = 墨水量。只有接不到生命值节点时才退回 bar_ratio 占位。
func _refresh_bar() -> void:
	if _health == null:
		status_bar.value = bar_ratio * 100.0
		ink_meter.text = "墨水 -- px"
		return
	status_bar.value = _health.ratio() * 100.0
	#只读瓶子自己的余量。画布各有各的账，屏幕上不该出现"全局已消耗"这种和画布绑在一起的概念。
	ink_meter.text = "墨水 %d px" % int(round(_health.ink))


## 走 `_input` 不走 `_unhandled_input`：画布工具按钮（`Canvas/Buttons/*`）点过之后会占住焦点，
## 那时 Godot 的 GUI 会把 Tab 当 ui_focus_next 吃掉，`_unhandled_input` 收不到。
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("debug"):
		get_viewport().set_input_as_handled()
		_switch_debug_hud()


func _switch_debug_hud() -> void:
	debug_hud.visible = not debug_hud.visible
	debug_hud.forces.enabled = debug_hud.visible
	debug_hud.forces.queue_redraw()
	visible = not debug_hud.visible


func _on_exit_button_pressed() -> void:
	get_tree().change_scene_to_file(MENU_SCENE)
