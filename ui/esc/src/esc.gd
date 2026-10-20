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
var _was_paused := false
var _settings_only := false
var _previous_focus: WeakRef
var help_page: VBoxContainer


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
	_build_help_page()


func open_menu() -> void:
	_settings_only = false
	_set_open(true)


## 主菜单复用声音子页，返回直接关闭，不露出游戏暂停菜单。
func open_sound_settings() -> void:
	_settings_only = true
	_set_open(true)
	_on_sound_button_pressed()


func _unhandled_input(event: InputEvent) -> void:
	if _settings_only and not visible:
		return
	if event.is_action_pressed("escape") and not event.is_echo():
		get_viewport().set_input_as_handled()
		if _recovery_busy:
			return
		if visible and sound_page.visible:
			_on_sound_back_pressed()
			return
		if visible and help_page.visible:
			_on_help_back_pressed()
			return
		_set_open(not visible)


func _set_open(open: bool) -> void:
	if open == visible:
		return
	if open:
		var blueprints := get_node_or_null("/root/Blueprints")
		if blueprints != null and blueprints.modal:
			return
		var dialogue := get_tree().get_first_node_in_group(&"dialogue_box")
		if dialogue != null and dialogue.log_root.visible:
			dialogue.hide_log()
		_was_paused = get_tree().paused
		var focus := get_viewport().gui_get_focus_owner()
		_previous_focus = weakref(focus) if focus != null else null
	if sound_page.visible:
		audio_settings.save_settings()
	sound_page.hide()
	help_page.hide()
	$Center/Panel/Buttons.show()
	visible = open
	get_tree().paused = true if open else _was_paused
	if open:
		show_recovery_status("")
		var recovery := _recovery_controller()
		$Center/Panel/Buttons/EscapeStuckButton.disabled = recovery == null or recovery._editor_active()
		_refresh_restart_button()
		continue_button.grab_focus()
	elif _previous_focus != null:
		var previous := _previous_focus.get_ref() as Control
		if previous != null and previous.is_visible_in_tree():
			previous.grab_focus()


func _exit_tree() -> void:
	if visible:
		get_tree().paused = _was_paused


func _build_help_page() -> void:
	help_page = preload("res://ui/esc/src/help_page.gd").new()
	$Center/Panel.add_child(help_page)
	help_page.back_pressed.connect(_on_help_back_pressed)
	help_page.hide()


func _on_help_button_pressed() -> void:
	if _recovery_busy:
		return
	$Center/Panel/Buttons.hide()
	sound_page.hide()
	help_page.show()
	help_page.get_node("BackButton").grab_focus()


func _on_help_back_pressed() -> void:
	help_page.hide()
	$Center/Panel/Buttons.show()
	$Center/Panel/Buttons/HelpButton.grab_focus()


func _on_sound_button_pressed() -> void:
	if _recovery_busy:
		return
	$Center/Panel/Buttons.hide()
	help_page.hide()
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
	if _settings_only:
		_set_open(false)
		return
	audio_settings.save_settings()
	sound_page.hide()
	$Center/Panel/Buttons.show()
	$Center/Panel/Buttons/SoundButton.grab_focus()


func _on_continue_button_pressed() -> void:
	if _recovery_busy:
		return
	_set_open(false)


func _refresh_restart_button() -> void:
	var router := get_tree().get_first_node_in_group(&"level_router")
	$Center/Panel/Buttons/RestartButton.disabled = router == null or not router.can_restart_current_level()


func _on_restart_button_pressed() -> void:
	if _recovery_busy:
		return
	var router := get_tree().get_first_node_in_group(&"level_router")
	if router == null or not router.can_restart_current_level():
		return
	_set_open(false)
	# 路由器持有异步任务；重载会释放当前菜单，不能在菜单里等待结果。
	router.restart_current_level()


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
	$Center/Panel/Buttons/EscapeStuckButton.disabled = recovery._editor_active()
	_refresh_restart_button()
	if succeeded:
		_was_paused = false # 脱离卡死成功即返回游玩，不保留恢复搜索的临时暂停。
		_set_open(false)
	return succeeded


func show_recovery_status(message: String) -> void:
	_recovery_status.text = message
	_recovery_status.visible = not message.is_empty()


func _on_menu_button_pressed() -> void:
	if _recovery_busy:
		return
	if not _save_editor_before_leave():
		return
	_set_open(false)
	get_tree().paused = false
	get_tree().change_scene_to_file(ROOT_SCENE)


func _on_quit_button_pressed() -> void:
	if _recovery_busy:
		return
	if not _save_editor_before_leave():
		return
	_set_open(false)
	get_tree().quit()


## 仍在地图编辑器里直接回标题/退出游戏时，先把最新地图写盘，避免丢修改。
func _save_editor_before_leave() -> bool:
	var creative := get_tree().get_first_node_in_group(&"creative_editor")
	if creative == null or not creative.has_method("save_editor_snapshot_before_leave"):
		return true
	var error: Error = creative.save_editor_snapshot_before_leave()
	if error != OK:
		push_error("ESC: 地图保存失败，已取消离开 (%d)" % error)
		show_recovery_status("地图保存失败，已取消离开")
		return false
	return true
