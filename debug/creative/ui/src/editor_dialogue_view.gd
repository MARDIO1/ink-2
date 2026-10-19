extends Window
## 对话触发点输入窗口：多行文案，Enter 换下一句，确认后把整段内容交给调用方。
##
## 只发意图，不放置任何节点：`confirmed(lines, world_position)` 由编辑器接收后执行。
## 关闭、取消、失焦都只是隐藏窗口，不产生文档变更。

signal confirmed(lines: PackedStringArray, world_position: Vector2)

const THEME := preload("res://ui/theme/asset/ink_attack_theme.tres")

var _lines_box: VBoxContainer
var _status: Label
var _position := Vector2.ZERO


func _init() -> void:
	name = "DialogueTriggerInput"
	title = "设置对话触发点（100×100）"
	size = Vector2i(560, 430)
	min_size = Vector2i(440, 320)
	transient = true
	exclusive = true
	unresizable = false
	visible = false
	theme = THEME
	close_requested.connect(close_view)
	_build()


func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var help := Label.new()
	help.text = "输入第一句，按 Enter 切换到下一句；播放时将按此顺序逐句输出。"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(help)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	_lines_box = VBoxContainer.new()
	_lines_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lines_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_lines_box)

	_status = Label.new()
	_status.modulate = Color(0.75, 0.12, 0.08)
	column.add_child(_status)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(actions)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.pressed.connect(close_view)
	actions.add_child(cancel)
	var confirm := Button.new()
	confirm.text = "放置触发点"
	confirm.pressed.connect(_submit)
	actions.add_child(confirm)


## 打开窗口并清空上一次的输入。
func open_at(world_position: Vector2) -> void:
	_position = world_position
	for child in _lines_box.get_children():
		child.queue_free()
	_status.text = ""
	var first := _add_line("")
	popup_centered(Vector2i(560, 430))
	first.call_deferred("grab_focus")


## 关闭不提交；编辑器退出编辑态时也走这里。
func close_view() -> void:
	hide()


## 当前填写的文案（已去掉空行与首尾空白），按输入顺序。
func lines() -> PackedStringArray:
	var out := PackedStringArray()
	for child in _lines_box.get_children():
		if not child is LineEdit:
			continue
		var sentence: String = child.text.strip_edges()
		if not sentence.is_empty():
			out.append(sentence)
	return out


## 追加一行输入并返回控件（测试与快捷键复用）。
func add_line(initial_text: String = "") -> LineEdit:
	return _add_line(initial_text)


## 第 index 行的输入控件（越界返回 null）。
func line_input(index: int) -> LineEdit:
	if index < 0 or index >= _lines_box.get_child_count():
		return null
	return _lines_box.get_child(index) as LineEdit


## 当前行数（含空行）。
func line_count() -> int:
	return _lines_box.get_child_count()


func _add_line(initial_text: String) -> LineEdit:
	var input := LineEdit.new()
	input.placeholder_text = "第 %d 句" % (_lines_box.get_child_count() + 1)
	input.text = initial_text
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.text_submitted.connect(_on_line_submitted.bind(input))
	_lines_box.add_child(input)
	return input


func _on_line_submitted(_text: String, input: LineEdit) -> void:
	var index := input.get_index()
	var next: LineEdit = null
	if index + 1 < _lines_box.get_child_count():
		next = _lines_box.get_child(index + 1) as LineEdit
	else:
		next = _add_line("")
	if next != null:
		next.grab_focus()


## 供外部（如快捷键）直接确认当前内容。
func submit_now() -> void:
	_submit()


func _submit() -> void:
	var filled := lines()
	if filled.is_empty():
		_status.text = "请至少输入一句文案。"
		return
	hide()
	confirmed.emit(filled, _position)
