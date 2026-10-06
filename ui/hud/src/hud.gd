extends CanvasLayer
## 成品 HUD：墨水瓶与横条是血条/蓝条的位子，数据未接，值由 export 给。
## Tab 在成品 HUD 与 debugHUD 之间切换。

const MENU_SCENE := "res://ui/menu/menu.tscn"

## 蓝条当前比例，0-1；接玩家数据前当静态占位。
@export_range(0.0, 1.0, 0.01) var bar_ratio: float = 0.72
## 调试 HUD 的相对路径；Tab 切换时用它决定显隐。
@export var debug_hud_path: NodePath = ^"../debugHUD"

@onready var status_bar: ProgressBar = $Root/StatusBar
@onready var debug_hud = get_node(debug_hud_path)


func _ready() -> void:
	status_bar.value = bar_ratio * 100.0
	debug_hud.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug"):
		_switch_debug_hud()


func _switch_debug_hud() -> void:
	debug_hud.visible = not debug_hud.visible
	debug_hud.forces.enabled = debug_hud.visible
	debug_hud.forces.queue_redraw()
	visible = not debug_hud.visible


func _on_exit_button_pressed() -> void:
	get_tree().change_scene_to_file(MENU_SCENE)
