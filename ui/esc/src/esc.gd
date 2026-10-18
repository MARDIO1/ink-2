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
	if event.is_action_pressed("escape"):
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
		continue_button.grab_focus()
	elif _previous_focus != null:
		var previous := _previous_focus.get_ref() as Control
		if previous != null and previous.is_visible_in_tree():
			previous.grab_focus()


func _exit_tree() -> void:
	if visible:
		get_tree().paused = _was_paused


func _build_help_page() -> void:
	help_page = VBoxContainer.new()
	help_page.name = "HelpPage"
	help_page.add_theme_constant_override("separation", 12)
	$Center/Panel.add_child(help_page)
	var title := Label.new()
	title.text = "操作说明"
	title.theme_type_variation = &"TitleLabel"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help_page.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(360, 300)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	help_page.add_child(scroll)
	var content := Label.new()
	content.custom_minimum_size.x = 336
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.text = "游玩\nA / D 移动 · 空格跳跃 · Tab 调试视图\n靠近画布展开工具栏，离开后恢复操纵。\n\n画布\n1 画笔 · 2 橡皮 · 3 形状 · 4 填充\n5 清空 · 6 框选 · 7 固化 · 8 墨化 · F 操纵\n画笔右键临时擦除；形状含矩形、圆形、直线。\n灰墨＋圆形放固定钉子；白墨＋圆形放背景钉子。\n右键框选按钮切换矩形 / 圆形。\n左拖选区连同图像移动；Ctrl＋左拖只移动选框。\nBackspace 或框内右键删除；框选后可保存蓝图。\nCtrl＋Z 撤销 · Ctrl＋Y 重做（也可点击撤销/重做）。\n\n地图编辑器\nF2 进入/退出 · CapsLock 展开右侧工具\n9 固定钉子（兼容） · 0 扩展画布 · F5 打开地图保存窗口\n操纵：左键选中拖动，右键删除，滚轮缩放支持的物品。\n齿轮：按下定圆心，拖动定半径，使用当前颜色。\n传送门：先选择目标地图，再单击放置。\n\n蓝图手册\n可在任意位置查看；游玩时靠近画布才能放置。\n左键放置 · Shift＋左键连续放置 · 右键 / Esc 取消。\n含齿轮的蓝图仅地图编辑器可用。"
	scroll.add_child(content)
	var back := Button.new()
	back.name = "BackButton"
	back.text = "返回  Esc"
	back.custom_minimum_size.y = 58
	back.theme_type_variation = &"MenuActionButton"
	back.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	back.pressed.connect(_on_help_back_pressed)
	help_page.add_child(back)
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
