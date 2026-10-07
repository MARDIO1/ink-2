extends Control
## 主菜单：**不是独立场景**，由 `root` 挂进 UI 容器当第一屏。
## 「开始」只对外喊一声 `start_pressed`（换屏由 root 做），「退出」/ESC 关程序。

signal start_pressed

@onready var start_button: Button = $ButtonCenter/Buttons/StartButton


func _ready() -> void:
	start_button.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		get_tree().quit()


func _on_start_button_pressed() -> void:
	start_pressed.emit()


func _on_quit_button_pressed() -> void:
	get_tree().quit()
