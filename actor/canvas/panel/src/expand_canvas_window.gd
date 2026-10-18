extends RefCounted
## 「扩展画布」窗口：四个方向的像素增量、尺寸预览与确认。
##
## **不持有 Canvas**：主题、尺寸来源和两个回调都由调用方传入；
## 真正的扩/缩操作仍由画布执行（`expand_canvas_sides`），这里只管输入与显示。

const SIDES := ["Left", "Right", "Top", "Bottom"]
const SIDE_LABELS := {"Left": "左侧", "Right": "右侧", "Top": "上侧", "Bottom": "下侧"}


## 返回 {"window", "inputs", "preview"}。`on_change` 在任一方向变化时触发（无参），
## `on_confirm` 在点「确认调整」时触发。
static func build(host: Node, theme: Theme, on_change: Callable, on_confirm: Callable) -> Dictionary:
	var window := Window.new()
	window.name = "ExpandCanvasWindow"
	window.title = "扩展画布"
	window.size = Vector2i(420, 390)
	window.min_size = Vector2i(380, 350)
	window.visible = false
	window.transient = true
	window.theme = theme
	window.close_requested.connect(window.hide)
	host.add_child(window)
	window.hide()

	var margin := MarginContainer.new()
	margin.name = "Content"
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_bottom", 24)
	window.add_child(margin)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 16)
	margin.add_child(column)

	var explanation := Label.new()
	explanation.text = "正数扩展，负数缩小并删除越界内容。保留内容的世界位置不变，可 Ctrl+Z 撤销。"
	explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(explanation)

	var preview := Label.new()
	preview.name = "SizePreview"
	column.add_child(preview)

	var input_grid := GridContainer.new()
	input_grid.name = "Inputs"
	input_grid.columns = 2
	input_grid.add_theme_constant_override("h_separation", 24)
	input_grid.add_theme_constant_override("v_separation", 10)
	column.add_child(input_grid)
	var inputs := {}
	for side in SIDES:
		var label := Label.new()
		label.text = SIDE_LABELS[side]
		input_grid.add_child(label)
		var amount := SpinBox.new()
		amount.name = side + "Amount"
		amount.custom_minimum_size = Vector2(210, 42)
		amount.min_value = -8192
		amount.max_value = 8192
		amount.step = 1
		amount.value = 0
		amount.suffix = " px"
		amount.value_changed.connect(on_change.unbind(1))
		input_grid.add_child(amount)
		inputs[side] = amount

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 12)
	column.add_child(actions)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.pressed.connect(window.hide)
	actions.add_child(cancel)
	var confirm := Button.new()
	confirm.text = "确认调整"
	confirm.pressed.connect(on_confirm)
	actions.add_child(confirm)
	return {"window": window, "inputs": inputs, "preview": preview}


## 四个方向的增量，顺序固定为 (左, 右, 上, 下)。
static func amounts(inputs: Dictionary) -> Vector4i:
	return Vector4i(
		int((inputs.get("Left") as SpinBox).value) if inputs.has("Left") else 0,
		int((inputs.get("Right") as SpinBox).value) if inputs.has("Right") else 0,
		int((inputs.get("Top") as SpinBox).value) if inputs.has("Top") else 0,
		int((inputs.get("Bottom") as SpinBox).value) if inputs.has("Bottom") else 0)


## 把所有输入清回 0（每次打开窗口都要重置）。
static func reset(inputs: Dictionary) -> void:
	for input: SpinBox in inputs.values():
		input.value = 0


## 按当前输入刷新「当前 → 调整后」提示；宽高不足 1 时补一行错误说明。
static func refresh_preview(preview: Label, inputs: Dictionary, size: Vector2i) -> void:
	if preview == null:
		return
	var delta := amounts(inputs)
	var width := size.x + delta.x + delta.y
	var height := size.y + delta.z + delta.w
	preview.text = "当前：%d × %d px    调整后：%d × %d px" % [size.x, size.y, width, height]
	if width < 1 or height < 1:
		preview.text += "\n宽高必须至少为 1 px"
