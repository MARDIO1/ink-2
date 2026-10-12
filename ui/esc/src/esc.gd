extends CanvasLayer
## 游戏内 ESC 菜单：打开时暂停世界，继续 / 回主菜单 / 退出。

## 回主菜单 = 重新进 root：root 的第一屏就是主菜单，菜单/关卡/UI 全归它一套逻辑管。
const ROOT_SCENE := "res://root/root.tscn"

@onready var continue_button: Button = $Center/Panel/Buttons/ContinueButton


func _ready() -> void:
	add_to_group(&"esc_menu")
	visible = false


func open_menu() -> void:
	_set_open(true)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("escape"):
		get_viewport().set_input_as_handled()
		_set_open(not visible)


func _set_open(open: bool) -> void:
	visible = open
	get_tree().paused = open
	if open:
		var recovery := _recovery_controller()
		$Center/Panel/Buttons/EscapeStuckButton.disabled = recovery == null or recovery._editor_active()
		continue_button.grab_focus()


func _on_continue_button_pressed() -> void:
	_set_open(false)


func _recovery_controller() -> Node:
	var player := get_tree().get_first_node_in_group(&"player")
	return player.get_node_or_null("FallDeath") if player != null else null


func _on_escape_stuck_button_pressed() -> void:
	var recovery := _recovery_controller()
	if recovery != null and recovery.escape_stuck():
		_set_open(false)


func _on_menu_button_pressed() -> void:
	_set_open(false)
	get_tree().change_scene_to_file(ROOT_SCENE)


func _on_quit_button_pressed() -> void:
	_set_open(false)
	get_tree().quit()
