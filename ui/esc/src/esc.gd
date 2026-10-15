extends CanvasLayer
## 游戏内 ESC 菜单：打开时暂停世界，继续 / 回主菜单 / 退出。

## 回主菜单 = 重新进 root：root 的第一屏就是主菜单，菜单/关卡/UI 全归它一套逻辑管。
const ROOT_SCENE := "res://root/root.tscn"

@onready var continue_button: Button = $Center/Panel/Buttons/ContinueButton
@onready var sound_page: VBoxContainer = $Center/Panel/SoundPage
@onready var music_slider: HSlider = $Center/Panel/SoundPage/MusicSlider
@onready var sfx_slider: HSlider = $Center/Panel/SoundPage/SfxSlider
@onready var audio_settings: Node = get_node("/root/AudioSettings")
var _recovery_busy := false
var _recovery_status: Label


func _ready() -> void:
	add_to_group(&"esc_menu")
	visible = false
	_recovery_status = Label.new()
	_recovery_status.name = "RecoveryStatus"
	_recovery_status.custom_minimum_size.x = 300
	_recovery_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_recovery_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_recovery_status.visible = false
	$Center/Panel/Buttons.add_child(_recovery_status)


func open_menu() -> void:
	_set_open(true)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("escape"):
		get_viewport().set_input_as_handled()
		if _recovery_busy:
			return
		if visible and sound_page.visible:
			_on_sound_back_pressed()
			return
		_set_open(not visible)


func _set_open(open: bool) -> void:
	if sound_page.visible:
		audio_settings.save_settings()
	sound_page.hide()
	$Center/Panel/Buttons.show()
	visible = open
	get_tree().paused = open
	if open:
		var recovery := _recovery_controller()
		$Center/Panel/Buttons/EscapeStuckButton.disabled = recovery == null or recovery._editor_active()
		continue_button.grab_focus()


func _on_sound_button_pressed() -> void:
	if _recovery_busy:
		return
	$Center/Panel/Buttons.hide()
	sound_page.show()
	music_slider.set_value_no_signal(audio_settings.music_volume * 100.0)
	sfx_slider.set_value_no_signal(audio_settings.sfx_volume * 100.0)
	_update_volume_labels()
	music_slider.grab_focus()


func _on_music_volume_changed(value: float) -> void:
	audio_settings.set_music_volume(value / 100.0)
	_update_volume_labels()


func _on_sfx_volume_changed(value: float) -> void:
	audio_settings.set_sfx_volume(value / 100.0)
	_update_volume_labels()


func _update_volume_labels() -> void:
	$Center/Panel/SoundPage/MusicRow/Value.text = "%d%%" % roundi(music_slider.value)
	$Center/Panel/SoundPage/SfxRow/Value.text = "%d%%" % roundi(sfx_slider.value)


func _on_sound_back_pressed() -> void:
	audio_settings.save_settings()
	sound_page.hide()
	$Center/Panel/Buttons.show()
	$Center/Panel/Buttons/SoundButton.grab_focus()


func _on_continue_button_pressed() -> void:
	if _recovery_busy:
		return
	_set_open(false)


func _recovery_controller() -> Node:
	var player := get_tree().get_first_node_in_group(&"player")
	return player.get_node_or_null("FallDeath") if player != null else null


func _on_escape_stuck_button_pressed(skipped: Array = [], search = null) -> bool:
	if _recovery_busy:
		return false
	var recovery := _recovery_controller()
	if recovery == null:
		return false
	_recovery_busy = true
	for button in $Center/Panel/Buttons.get_children():
		if button is Button:
			button.disabled = true
	show_recovery_status("")
	var succeeded: bool = await recovery.escape_stuck(skipped, search)
	_recovery_busy = false
	for button in $Center/Panel/Buttons.get_children():
		if button is Button:
			button.disabled = false
	if succeeded:
		_set_open(false)
	else:
		show_recovery_status(recovery.recovery_error)
	return succeeded


func show_recovery_status(message: String) -> void:
	_recovery_status.text = message
	_recovery_status.visible = not message.is_empty()


func _on_menu_button_pressed() -> void:
	_set_open(false)
	get_tree().change_scene_to_file(ROOT_SCENE)


func _on_quit_button_pressed() -> void:
	_set_open(false)
	get_tree().quit()
