extends CanvasLayer
## 成品 HUD：瓶内液面显示玩家墨水量（来源 InkHealth），顶部横条只留空框。
## Tab 在成品 HUD 与 debugHUD 之间切换。

## 退出按钮回主菜单 = 重新进 root（root 第一屏是主菜单）。
const ROOT_SCENE := "res://root/root.tscn"
## UI 与关卡不在同一棵子树时的兜底查找：玩家 / 调试 HUD 都按组找（场景里挂的组见
## `map/main.tscn` 的 `Player` 与 `debug/hud/debug_hud.tscn` 的根节点）。
const PLAYER_GROUP := "player"
const DEBUG_HUD_GROUP := "debug_hud"

## 接不到墨水源时瓶内液面的静态占位比例，0-1。
@export_range(0.0, 1.0, 0.01) var bar_ratio: float = 0.72
## 玩家墨水生命值节点的相对路径（本节点是 Main 的子级）。
@export var health_path: NodePath = ^"../Player/InkHealth"
## 同树时的显式路径；找不到就按组找。
@export var debug_hud_path: NodePath = ^"../debugHUD"

@onready var bottle_fill: TextureProgressBar = $Root/BottleFill
@onready var ink_meter: Label = $Root/InkMeter
var debug_hud = null

var _health = null


func _ready() -> void:
	var explicit_hud := get_node_or_null(debug_hud_path)
	debug_hud = explicit_hud if explicit_hud != null else get_tree().get_first_node_in_group(DEBUG_HUD_GROUP)
	if debug_hud != null:
		debug_hud.visible = false
	_health = get_node_or_null(health_path)
	if _health == null:
		var player := get_tree().get_first_node_in_group(PLAYER_GROUP)
		_health = player.get_node_or_null("InkHealth") if player != null else null
	if _health != null:
		_health.changed.connect(_refresh_ink)
	_refresh_ink()


## 瓶内液面 = 墨水量。只有接不到生命值节点时才退回 bar_ratio 占位。
func _refresh_ink() -> void:
	if _health == null:
		bottle_fill.value = bar_ratio * 100.0
		ink_meter.text = "墨水 -- px"
		return
	bottle_fill.value = _health.ratio() * 100.0
	#只读瓶子自己的余量。画布各有各的账，屏幕上不该出现"全局已消耗"这种和画布绑在一起的概念。
	ink_meter.text = "墨水 %d px" % int(round(_health.ink))


## 走 `_input` 不走 `_unhandled_input`：画布工具按钮（`Canvas/Buttons/*`）点过之后会占住焦点，
## 那时 Godot 的 GUI 会把 Tab 当 ui_focus_next 吃掉，`_unhandled_input` 收不到。
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("debug"):
		get_viewport().set_input_as_handled()
		_switch_debug_hud()


func _switch_debug_hud() -> void:
	if debug_hud == null:
		return
	debug_hud.visible = not debug_hud.visible
	debug_hud.forces.enabled = debug_hud.visible
	debug_hud.forces.queue_redraw()
	visible = not debug_hud.visible


func _on_exit_button_pressed() -> void:
	get_tree().change_scene_to_file(ROOT_SCENE)


func _on_log_button_pressed() -> void:
	var dialogue := get_tree().get_first_node_in_group(&"dialogue_box")
	if dialogue != null and dialogue.has_method("toggle_log"):
		dialogue.toggle_log()
