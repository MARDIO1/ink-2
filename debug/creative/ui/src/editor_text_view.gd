extends Window
## 地图文字输入窗口：多行文本，确认后把内容交给调用方。
##
## 只发意图，不放置节点：`confirmed(content, world_position)` 由编辑器执行。

signal confirmed(content: String, world_position: Vector2)

const THEME := preload("res://ui/theme/asset/ink_attack_theme.tres")

var _input: TextEdit
var _status: Label
var _position := Vector2.ZERO


func _init() -> void:
	name = "MapTextInput"
	title = "放置地图文本"
	size = Vector2i(560, 330)
	min_size = Vector2i(440, 280)
	transient = true
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
	help.text = "输入要写在地图上的文字；支持换行，显示时使用沐瑶软笔手写体。"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(help)
	_input = TextEdit.new()
	_input.name = "TextInput"
	_input.placeholder_text = "输入地图文本……"
	_input.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_input.custom_minimum_size = Vector2(0, 150)
	column.add_child(_input)
	_status = Label.new()
	_status.modulate = Color(0.75, 0.12, 0.08)
	column.add_child(_status)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 8)
	column.add_child(actions)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.pressed.connect(close_view)
	actions.add_child(cancel)
	var confirm := Button.new()
	confirm.text = "放置文本"
	confirm.pressed.connect(_submit)
	actions.add_child(confirm)


func open_at(world_position: Vector2) -> void:
	_position = world_position
	_input.text = ""
	_status.text = ""
	popup_centered(Vector2i(560, 330))
	_input.call_deferred("grab_focus")


func close_view() -> void:
	hide()


## 当前输入的文字（已去掉首尾空白）。
func content() -> String:
	return _input.text.strip_edges()


## 供外部（如快捷键）直接确认当前内容。
func submit_now() -> void:
	_submit()


func _submit() -> void:
	var text_value := content()
	if text_value.is_empty():
		_status.text = "请输入要放置的文字。"
		return
	hide()
	confirmed.emit(text_value, _position)
