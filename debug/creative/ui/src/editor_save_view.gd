extends Node
## 保存表单只负责输入校验和反馈；唯一写入端口 save_scene 由组合根提供。
const EDITOR_THEME := preload("res://ui/theme/asset/ink_attack_theme.tres")
var save_scene: Callable
var presentation_root: Node
var map_path := ""
var baked_map_path := ""
var _save_directory_dialog: FileDialog = null
var _map_save_window: PopupPanel = null
var _save_name_input: LineEdit = null
var _save_directory_input: LineEdit = null
var _save_preview: TextureRect = null
var _save_status: Label

func export_map_to(path: String) -> Error:
	return save_scene.call(path)

func _build_save_directory_dialog() -> void:
	if _save_directory_dialog != null:
		return
	var dialog := FileDialog.new()
	dialog.name = "SaveMapDirectoryDialog"
	dialog.title = "选择地图保存文件夹"
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access = FileDialog.ACCESS_RESOURCES
	dialog.current_dir = map_path.get_base_dir()
	dialog.dir_selected.connect(_on_save_directory_chosen)
	presentation_root.add_child(dialog)
	_save_directory_dialog = dialog

func _request_map_save_directory() -> void:
	if _save_directory_dialog == null:
		_build_save_directory_dialog()
	if _save_directory_dialog == null:
		push_error("Creative: 无法打开地图保存目录选择器")
		return
	# 目录框属于保存表单，不能作为同级弹窗抢走焦点并自动关闭 PopupPanel。
	if is_instance_valid(_map_save_window) and _map_save_window.visible \
	and _save_directory_dialog.get_parent() != _map_save_window:
		_save_directory_dialog.reparent(_map_save_window)
	_save_directory_dialog.current_dir = map_path.get_base_dir()
	_save_directory_dialog.popup_centered(Vector2i(get_viewport().get_visible_rect().size * 0.72))

func _build_map_save_window() -> void:
	if _map_save_window != null:
		return
	var popup := PopupPanel.new()
	popup.name = "MapSaveWindow"
	popup.theme = EDITOR_THEME
	presentation_root.add_child(popup)
	_map_save_window = popup
	var column := VBoxContainer.new()
	column.name = "Content"
	column.custom_minimum_size = Vector2(520, 440)
	column.add_theme_constant_override("separation", 10)
	popup.add_child(column)
	var title := Label.new()
	title.text = "保存地图"
	title.theme_type_variation = &"TitleLabel"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	_save_preview = TextureRect.new()
	_save_preview.name = "MapThumbnail"
	_save_preview.custom_minimum_size = Vector2(480, 270)
	_save_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_save_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	column.add_child(_save_preview)
	var name_row := HBoxContainer.new()
	column.add_child(name_row)
	var name_label := Label.new()
	name_label.text = "名称"
	name_label.custom_minimum_size = Vector2(68, 0)
	name_row.add_child(name_label)
	_save_name_input = LineEdit.new()
	_save_name_input.name = "MapNameInput"
	_save_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_name_input.placeholder_text = "输入地图名称"
	_save_name_input.text_submitted.connect(func(_text: String): _confirm_named_map_save())
	name_row.add_child(_save_name_input)
	var dir_row := HBoxContainer.new()
	column.add_child(dir_row)
	var dir_label := Label.new()
	dir_label.text = "路径"
	dir_label.custom_minimum_size = Vector2(68, 0)
	dir_row.add_child(dir_label)
	_save_directory_input = LineEdit.new()
	_save_directory_input.name = "MapDirectoryInput"
	_save_directory_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_directory_input.editable = false
	dir_row.add_child(_save_directory_input)
	var browse := Button.new()
	browse.name = "BrowseButton"
	browse.text = "选择路径"
	browse.pressed.connect(_request_map_save_directory)
	dir_row.add_child(browse)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(actions)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.pressed.connect(popup.hide)
	actions.add_child(cancel)
	var save := Button.new()
	actions.name = "Actions"
	cancel.name = "CancelButton"
	save.name = "SaveButton"
	save.text = "保存"
	save.pressed.connect(_confirm_named_map_save)
	actions.add_child(save)
	_save_status = Label.new()
	_save_status.name = "SaveStatus"
	_save_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_save_status.custom_minimum_size.x = 480
	_save_status.hide()
	column.add_child(_save_status)

func _open_map_save_window() -> void:
	if _map_save_window == null:
		_build_map_save_window()
	if _map_save_window == null:
		return
	_save_name_input.text = map_path.get_file().get_basename()
	_save_directory_input.text = map_path.get_base_dir()
	_save_status.hide()
	_refresh_map_save_preview()
	_map_save_window.popup_centered()
	_save_name_input.grab_focus()

func _refresh_map_save_preview() -> void:
	if _save_preview == null or DisplayServer.get_name() == "headless":
		return
	var image := get_viewport().get_texture().get_image()
	if image == null:
		return
	image.resize(480, 270, Image.INTERPOLATE_NEAREST)
	_save_preview.texture = ImageTexture.create_from_image(image)

func _on_save_directory_chosen(directory: String) -> void:
	if _save_directory_input != null:
		_save_directory_input.text = directory

func _confirm_named_map_save() -> void:
	if _save_name_input == null or _save_directory_input == null:
		return
	var name := _save_name_input.text.strip_edges().validate_filename()
	if name.to_lower().ends_with(".tscn"):
		name = name.trim_suffix(".tscn")
	var directory := _save_directory_input.text.strip_edges()
	if name.is_empty() or directory.is_empty():
		_save_status.text = "请输入地图名称并选择保存目录。"
		_save_status.show()
		_save_name_input.grab_focus()
		return
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(directory)):
		_save_status.text = "保存目录不存在，请重新选择路径。"
		_save_status.show()
		return
	var previous_map := map_path
	var previous_bake := baked_map_path
	map_path = directory.path_join(name + ".tscn")
	baked_map_path = directory.path_join(name + ".png")
	var error := export_map_to(map_path)
	if error == OK and _map_save_window != null:
		_map_save_window.hide()
	elif error != OK:
		map_path = previous_map
		baked_map_path = previous_bake
		_save_status.text = "保存失败：%s；当前地图路径未改变。" % error_string(error)
		_save_status.show()
