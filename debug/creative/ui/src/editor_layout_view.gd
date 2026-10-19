extends Node
## 编辑器的"布局表单"：新增游玩画布的尺寸、复活点的激活区域。
##
## 只负责控件与取值；真正的放置、写属性、记历史由 Creative 在收到确认后执行。
## 取消不发信号，调用方据此保持文档不变。

signal canvas_size_confirmed(size: Vector2i)
signal canvas_size_canceled
signal respawn_area_confirmed(size: Vector2, offset: Vector2)

var _canvas_dialog: ConfirmationDialog
var _canvas_width: SpinBox
var _canvas_height: SpinBox
var _respawn_dialog: ConfirmationDialog
var _respawn_fields: Array[SpinBox] = []


## 构建"新增游玩画布"表单；`parent` 决定它挂在哪个界面上。
func ensure_canvas_dialog(parent: Control, theme: Theme) -> void:
	if _canvas_dialog != null or parent == null:
		return
	_canvas_dialog = ConfirmationDialog.new()
	_canvas_dialog.name = "CanvasSizeDialog"
	_canvas_dialog.title = "新增游玩画布"
	_canvas_dialog.theme = theme
	_canvas_dialog.get_ok_button().text = "开始放置"
	parent.add_child(_canvas_dialog)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	_canvas_dialog.add_child(column)
	for dimension in ["宽度", "高度"]:
		var row := HBoxContainer.new()
		column.add_child(row)
		var label := Label.new()
		label.text = dimension + "（像素）"
		label.custom_minimum_size.x = 105.0
		row.add_child(label)
		var input := SpinBox.new()
		input.min_value = 16.0
		input.max_value = 4096.0
		input.step = 1.0
		input.custom_minimum_size.x = 170.0
		input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(input)
		if dimension == "宽度":
			_canvas_width = input
		else:
			_canvas_height = input
	_canvas_dialog.confirmed.connect(func(): canvas_size_confirmed.emit(canvas_size_value()))
	_canvas_dialog.canceled.connect(func(): canvas_size_canceled.emit())


func open_canvas(current: Vector2i) -> void:
	if _canvas_dialog == null:
		return
	set_canvas_size(current)
	_canvas_dialog.popup_centered()


func set_canvas_size(size: Vector2i) -> void:
	if _canvas_width != null:
		_canvas_width.value = clampi(size.x, 16, 4096)
	if _canvas_height != null:
		_canvas_height.value = clampi(size.y, 16, 4096)


func canvas_size_value() -> Vector2i:
	if _canvas_width == null or _canvas_height == null:
		return Vector2i.ZERO
	return Vector2i(int(_canvas_width.value), int(_canvas_height.value))


## 构建"复活点激活区域"表单；`parent` 通常是右侧工具栏根节点。
func ensure_respawn_dialog(parent: Node, theme: Theme) -> void:
	if _respawn_dialog != null or parent == null:
		return
	_respawn_dialog = ConfirmationDialog.new()
	_respawn_dialog.name = "RespawnAreaDialog"
	_respawn_dialog.title = "复活点：脚底落地激活区域"
	_respawn_dialog.theme = theme
	_respawn_dialog.get_ok_button().text = "应用"
	_respawn_dialog.get_cancel_button().text = "取消"
	parent.add_child(_respawn_dialog)
	var column := VBoxContainer.new()
	_respawn_dialog.add_child(column)
	for index in 4:
		var row := HBoxContainer.new()
		column.add_child(row)
		var label := Label.new()
		label.text = ["宽度", "高度", "水平偏移", "垂直偏移"][index] + "（像素）"
		label.add_theme_color_override("font_color", Color(0.95, 0.93, 0.85))
		label.custom_minimum_size.x = 150
		row.add_child(label)
		var field := SpinBox.new()
		field.min_value = 1 if index < 2 else -8192
		field.max_value = 8192
		field.custom_minimum_size.x = 160
		row.add_child(field)
		_respawn_fields.append(field)
	_respawn_dialog.confirmed.connect(func():
		var values := respawn_area_values()
		respawn_area_confirmed.emit(values.size, values.offset))


func open_respawn(size: Vector2, offset: Vector2) -> void:
	if _respawn_dialog == null:
		return
	if _respawn_fields.size() == 4:
		_respawn_fields[0].value = size.x
		_respawn_fields[1].value = size.y
		_respawn_fields[2].value = offset.x
		_respawn_fields[3].value = offset.y
	_respawn_dialog.popup_centered(Vector2i(390, 240))


## 收起两个表单（退出编辑态时调用）。
func close_forms() -> void:
	if _canvas_dialog != null:
		_canvas_dialog.hide()
	if _respawn_dialog != null:
		_respawn_dialog.hide()


## 当前填写的区域，返回 {"size": Vector2, "offset": Vector2}。
func respawn_area_values() -> Dictionary:
	if _respawn_fields.size() != 4:
		return {"size": Vector2.ZERO, "offset": Vector2.ZERO}
	return {"size": Vector2(_respawn_fields[0].value, _respawn_fields[1].value),
		"offset": Vector2(_respawn_fields[2].value, _respawn_fields[3].value)}
