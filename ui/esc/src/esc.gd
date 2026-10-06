extends CanvasLayer
## 游戏内 ESC 菜单：打开时暂停世界，继续 / 回主菜单 / 退出。

const MENU_SCENE := "res://ui/menu/menu.tscn"

@onready var continue_button: Button = $Buttons/ContinueButton


func _ready() -> void:
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("escape"):
		get_viewport().set_input_as_handled()
		_set_open(not visible)


func _set_open(open: bool) -> void:
	visible = open
	get_tree().paused = open
	if open:
		continue_button.grab_focus()


func _on_continue_button_pressed() -> void:
	_set_open(false)


func _on_menu_button_pressed() -> void:
	_set_open(false)
	get_tree().change_scene_to_file(MENU_SCENE)


func _on_quit_button_pressed() -> void:
	_set_open(false)
	get_tree().quit()
