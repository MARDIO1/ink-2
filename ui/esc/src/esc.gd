extends CanvasLayer
## 游戏内 ESC 菜单：打开时暂停世界，继续 / 回主菜单 / 退出。

## 回主菜单 = 重新进 root：root 的第一屏就是主菜单，菜单/关卡/UI 全归它一套逻辑管。
const ROOT_SCENE := "res://root/root.tscn"

@onready var continue_button: Button = $Center/Panel/Buttons/ContinueButton


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
	get_tree().change_scene_to_file(ROOT_SCENE)


func _on_quit_button_pressed() -> void:
	_set_open(false)
	get_tree().quit()
