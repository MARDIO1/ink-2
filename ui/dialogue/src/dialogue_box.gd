class_name DialogueBox
extends CanvasLayer
## 底部像素对话框：从 JSON 读取台词，以打字机效果逐字显示。
##
## 单击正在播放的句子会立即显示完整句子；再次单击进入下一句。

signal line_started(index: int, text: String)
signal dialogue_finished
signal history_changed(lines: PackedStringArray)

@export_file("*.json") var dialogue_file: String = "res://ui/dialogue/asset/dialogue_lines.json"
@export_range(1.0, 120.0, 1.0) var characters_per_second: float = 24.0
@export var hide_when_finished: bool = true

@onready var root: Control = $Root
@onready var panel: PanelContainer = $Root/DialoguePanel
@onready var dialogue_label: Label = $Root/DialoguePanel/PixelText/TextViewport/DialogueLabel
@onready var next_hint: Label = $Root/DialoguePanel/PixelText/TextViewport/NextHint
@onready var log_root: Control = $LogRoot
@onready var history_label: Label = $LogRoot/Center/Panel/Margin/Column/HistoryScroll/HistoryLabel

var lines: PackedStringArray = PackedStringArray()
var current_line: int = -1
var _visible_character_count: int = 0
var _type_accumulator: float = 0.0
var _typing: bool = false
var viewed_lines: PackedStringArray = PackedStringArray()
var _log_was_paused := false
var _log_focus: WeakRef


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"dialogue_box")
	panel.gui_input.connect(_on_panel_gui_input)
	_load_lines_from_file()
	# 进入关卡时不自动播放；台词只能由对话触发点或工具栏文本框通过 start_dialogue() 触发。
	root.hide()
	_refresh_history_text()


func _process(delta: float) -> void:
	if not _typing or get_tree().paused:
		return
	_type_accumulator += delta * characters_per_second
	var characters_to_add := int(_type_accumulator)
	if characters_to_add <= 0:
		return
	_type_accumulator -= characters_to_add
	_visible_character_count = mini(
		_visible_character_count + characters_to_add,
		dialogue_label.text.length()
	)
	dialogue_label.visible_characters = _visible_character_count
	if _visible_character_count >= dialogue_label.text.length():
		_finish_typing()


## 从第一句开始播放。传入自定义台词时，会临时替代 JSON 文件中的内容。
func start_dialogue(custom_lines: PackedStringArray = PackedStringArray()) -> void:
	if not custom_lines.is_empty():
		lines = custom_lines.duplicate()
	if lines.is_empty():
		_finish_dialogue()
		return
	root.show()
	current_line = 0
	_show_current_line()


## 推进对话。正在打字时先补全本句；本句完整时再进入下一句。
func advance() -> void:
	if not root.visible:
		return
	if _typing:
		_finish_typing()
		return
	current_line += 1
	if current_line >= lines.size():
		_finish_dialogue()
		return
	_show_current_line()


## 跳过整段对话；未显示的句子不写入已读日志。
func skip_dialogue() -> void:
	if not root.visible:
		return
	current_line = lines.size()
	_finish_dialogue(true)


## 在运行时替换全部台词；restart 为 true 时立即从第一句重新播放。
func set_lines(new_lines: PackedStringArray, restart: bool = true) -> void:
	lines = new_lines.duplicate()
	if restart:
		start_dialogue()


func _show_current_line() -> void:
	var line := lines[current_line]
	viewed_lines.append(line)
	_refresh_history_text()
	history_changed.emit(viewed_lines.duplicate())
	dialogue_label.text = line
	dialogue_label.visible_characters = 0
	_visible_character_count = 0
	_type_accumulator = 0.0
	_typing = true
	next_hint.hide()
	line_started.emit(current_line, line)


func _finish_typing() -> void:
	_typing = false
	_visible_character_count = dialogue_label.text.length()
	dialogue_label.visible_characters = -1
	next_hint.show()


func _finish_dialogue(force_hide := false) -> void:
	_typing = false
	next_hint.hide()
	if force_hide or hide_when_finished:
		root.hide()
	dialogue_finished.emit()


func toggle_log() -> void:
	if log_root.visible:
		hide_log()
	else:
		show_log()


func show_log() -> void:
	if log_root.visible:
		return
	var menu := get_tree().get_first_node_in_group(&"esc_menu")
	var blueprints := get_node_or_null("/root/Blueprints")
	if (menu != null and menu.visible) or (blueprints != null and blueprints.modal):
		return
	_log_was_paused = get_tree().paused
	var focus := get_viewport().gui_get_focus_owner()
	_log_focus = weakref(focus) if focus != null else null
	get_tree().paused = true
	_refresh_history_text()
	log_root.show()
	$LogRoot/Center/Panel/Margin/Column/CloseButton.grab_focus()


func hide_log() -> void:
	if not log_root.visible:
		return
	log_root.hide()
	get_tree().paused = _log_was_paused
	if _log_focus != null:
		var focus := _log_focus.get_ref() as Control
		if focus != null and focus.is_visible_in_tree():
			focus.grab_focus()


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed("escape") or event.is_echo():
		return
	var menu := get_tree().get_first_node_in_group(&"esc_menu")
	if menu != null and menu.visible:
		return
	if log_root.visible:
		hide_log()
		get_viewport().set_input_as_handled()
		return
	if root.visible:
		skip_dialogue()
		get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	if is_instance_valid(log_root) and log_root.visible:
		get_tree().paused = _log_was_paused


func _refresh_history_text() -> void:
	if history_label == null:
		return
	history_label.text = "还没有看过对话。" if viewed_lines.is_empty() else "\n\n".join(viewed_lines)


func _load_lines_from_file() -> void:
	lines.clear()
	if dialogue_file.is_empty() or not FileAccess.file_exists(dialogue_file):
		push_warning("找不到对话文本文件：%s" % dialogue_file)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(dialogue_file))
	if not (parsed is Array):
		push_warning("对话文本必须是 JSON 字符串数组：%s" % dialogue_file)
		return
	for value in parsed:
		if value is String and not value.is_empty():
			lines.append(value)


func _on_panel_gui_input(event: InputEvent) -> void:
	if get_tree().paused:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		panel.accept_event()
		advance()
