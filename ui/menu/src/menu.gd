extends Control
## 主菜单：开始进入主场景，退出关闭程序；ESC 等同退出。

const GAME_SCENE := "res://map/main.tscn"

@onready var start_button: Button = $StartButton


func _ready() -> void:
	start_button.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		get_tree().quit()


func _on_start_button_pressed() -> void:
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_quit_button_pressed() -> void:
	get_tree().quit()
