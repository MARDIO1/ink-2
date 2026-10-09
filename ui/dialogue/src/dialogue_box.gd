class_name DialogueBox
extends CanvasLayer
## 底部像素对话框：从 JSON 读取台词，以打字机效果逐字显示。
##
## 单击正在播放的句子会立即显示完整句子；再次单击进入下一句。

signal line_started(index: int, text: String)
signal dialogue_finished

@export_file("*.json") var dialogue_file: String = "res://ui/dialogue/asset/dialogue_lines.json"
@export_range(1.0, 120.0, 1.0) var characters_per_second: float = 24.0
@export var start_automatically: bool = true
@export var hide_when_finished: bool = true

@onready var root: Control = $Root
@onready var panel: PanelContainer = $Root/DialoguePanel
@onready var dialogue_label: Label = $Root/DialoguePanel/PixelText/TextViewport/DialogueLabel
@onready var next_hint: Label = $Root/DialoguePanel/PixelText/TextViewport/NextHint

var lines: PackedStringArray = PackedStringArray()
var current_line: int = -1
var _visible_character_count: int = 0
var _type_accumulator: float = 0.0
var _typing: bool = false


func _ready() -> void:
	add_to_group(&"dialogue_box")
	panel.gui_input.connect(_on_panel_gui_input)
	_load_lines_from_file()
	if start_automatically and not lines.is_empty():
		start_dialogue()
	else:
		root.hide()


func _process(delta: float) -> void:
	if not _typing:
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


## 在运行时替换全部台词；restart 为 true 时立即从第一句重新播放。
func set_lines(new_lines: PackedStringArray, restart: bool = true) -> void:
	lines = new_lines.duplicate()
	if restart:
		start_dialogue()


func _show_current_line() -> void:
	var line := lines[current_line]
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


func _finish_dialogue() -> void:
	_typing = false
	next_hint.hide()
	if hide_when_finished:
		root.hide()
	dialogue_finished.emit()


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
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		panel.accept_event()
		advance()
