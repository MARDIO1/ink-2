extends HBoxContainer
## 游玩态只撤销所属画布；编辑态走 Creative 的混合时间线，避免绕过物件历史。
var canvas: Node
var compact := false
var undo_button: Button
var redo_button: Button

func _ready() -> void:
	theme = preload("res://ui/theme/asset/ink_attack_theme.tres")
	add_theme_constant_override("separation", 4)
	undo_button = _button("Undo", "撤销", "撤销上一步（Ctrl+Z）", _undo)
	redo_button = _button("Redo", "重做", "重做上一步（Ctrl+Y）", _redo)
	refresh()

func _button(node_name: String, caption: String, hint: String, callback: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = caption
	button.tooltip_text = hint
	button.focus_mode = Control.FOCUS_NONE
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if compact:
		button.add_theme_font_size_override("font_size", 10)
		var style := theme.get_stylebox("normal", "Button").duplicate() as StyleBoxFlat
		style.set_content_margin_all(3)
		button.add_theme_stylebox_override("normal", style)
		var disabled_style := theme.get_stylebox("disabled", "Button").duplicate() as StyleBoxFlat
		disabled_style.set_content_margin_all(3)
		button.add_theme_stylebox_override("disabled", disabled_style)
	button.pressed.connect(callback)
	add_child(button)
	return button

func _editor() -> Node:
	var creative := canvas.get_parent().get_node_or_null("Creative")
	return creative if canvas._map_editor_mode and creative != null and creative.active else null

func _process(_delta: float) -> void:
	refresh()

func refresh() -> void:
	if not is_instance_valid(canvas) or undo_button == null:
		return
	var creative := _editor()
	var undo_empty: bool = creative._edit_history.is_empty() if creative != null else canvas.surface._undo_steps.is_empty()
	var redo_empty: bool = creative._redo_history.is_empty() if creative != null else canvas.surface._redo_steps.is_empty()
	var blueprints := get_node_or_null("/root/Blueprints")
	var blocked: bool = not canvas.active or get_tree().paused or (blueprints != null and blueprints.is_world_input_blocked())
	undo_button.disabled = blocked or undo_empty
	redo_button.disabled = blocked or redo_empty
	undo_button.tooltip_text = "暂无可撤销操作（Ctrl+Z）" if undo_empty else "撤销上一步（Ctrl+Z）"
	redo_button.tooltip_text = "暂无可重做操作（Ctrl+Y）" if redo_empty else "重做上一步（Ctrl+Y）"

func _undo() -> void:
	refresh()
	if undo_button.disabled:
		return
	var creative := _editor()
	if creative != null:
		creative.undo_last_edit()
	else:
		canvas.surface.undo_last_edit()
	refresh()

func _redo() -> void:
	refresh()
	if redo_button.disabled:
		return
	var creative := _editor()
	if creative != null:
		creative.redo_last_edit()
	else:
		canvas.surface.redo_last_edit()
	refresh()
