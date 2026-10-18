extends CanvasLayer
## 跨关卡的蓝图库。只在窗口打开时暂停；放置仍使用当前关卡的真实画布。
const Store := preload("res://blueprint/src/blueprint_store.gd")
const Place := preload("res://blueprint/src/blueprint_place.gd")
const Codec := preload("res://actor/canvas/blueprint/src/blueprint_codec.gd")
const Placement := preload("res://actor/canvas/blueprint/src/blueprint_placement.gd")
const Preview := preload("res://ui/hud/blueprint/blueprint_preview.tscn")
const InkTheme := preload("res://ui/theme/asset/ink_attack_theme.tres")
const Palette := preload("res://ink/general/src/ink_palette.gd")
const PAGE_SIZE := 12
var store := Store.new()
var modal := false
var placing := false
var _was_paused := false
var _level: Node
var _canvas: Node
var _selection_canvas: Node
var _old_tool := 0
var _mode := ""
var _items: Array = []
var _selected: Dictionary = {}
var _save_data: Dictionary = {}
## 当前的放置会话（幽灵、落点、合法性）；机制在 blueprint_placement.gd，这里只管界面。
var _placement: RefCounted
var _last_error := ""
var _page := 0
var _confirm_delete := false
var _images := {}
var _textures := {}
var backdrop: ColorRect
var panel: PanelContainer
var actions: VBoxContainer
var hint: Label
var placement_hint: Label
var toast: Label
var _toast_until := 0
var _title: Label
var _body: HBoxContainer
var _library: VBoxContainer
var _cards: GridContainer
var _search: LineEdit
var _favorites: CheckButton
var _page_label: Label
var _previous_page: Button
var _next_page: Button
var _detail: VBoxContainer
var _preview: Control
var _save_preview: Control
var _name: LineEdit
var _description: TextEdit
var _tags: LineEdit
var _info: Label
var _status: Label
var _use: Button
var _save: Button
var _favorite: Button
var _delete: Button

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 110 # 相机与画布布局更新后再定位选区操作按钮。
	layer = 80
	_build_ui()
	get_viewport().size_changed.connect(_layout)
	_layout()

func is_world_input_blocked() -> bool:
	return modal or placing

func blocks_world_event(event: InputEvent) -> bool:
	if modal or placing:
		return true
	# 全局输入早于 GUI 悬停更新；同帧移入并点击按钮也不能穿透选框。
	if actions.visible and event is InputEventMouse:
		for button: Control in actions.get_children():
			if button.get_global_rect().has_point(event.position):
				return true
	return false

func _pointer_over_ui(point: Vector2) -> bool:
	for control: Control in get_tree().root.find_children("*", "Control", true, false):
		# 容器和仅传递鼠标的布局节点不是可点击界面。
		if not (control is BaseButton or control is LineEdit or control is TextEdit or control is Range):
			continue
		if control.get_viewport() != get_viewport() or not control.is_visible_in_tree() or control.mouse_filter == Control.MOUSE_FILTER_IGNORE:
			continue
		if not Rect2(Vector2.ZERO, control.size).has_point(control.get_global_transform_with_canvas().affine_inverse() * point):
			continue
		# ScrollContainer 外的按钮仍是 visible，但其像素已被祖先裁掉，不能拦截世界输入。
		var ancestor := control.get_parent()
		var clipped := false
		while ancestor != null and not ancestor is Viewport:
			if ancestor is Control and ancestor.clip_contents \
			and not Rect2(Vector2.ZERO, ancestor.size).has_point(ancestor.get_global_transform_with_canvas().affine_inverse() * point):
				clipped = true
				break
			ancestor = ancestor.get_parent()
		if not clipped:
			return true
	return false

func _button(text_value: String, callback: Callable, parent: Node) -> Button:
	var button := Button.new()
	button.text = text_value
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.focus_mode = Control.FOCUS_NONE if parent == actions else Control.FOCUS_ALL
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _label(text_value: String, parent: Node) -> Label:
	var label := Label.new()
	label.text = text_value
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label

func _build_ui() -> void:
	var ui := Control.new()
	ui.name = "BlueprintUI"
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.theme = InkTheme
	ui.add_theme_font_size_override("font_size", 16)
	ui.add_theme_color_override("font_placeholder_color", Color(0.25, 0.235, 0.204, 0.75))
	add_child(ui)
	actions = VBoxContainer.new()
	actions.name = "SelectionActions"
	actions.add_theme_constant_override("separation", 4)
	actions.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(actions)
	_button("删除    Backspace", _delete_selection, actions)
	_button("保存为蓝图    Save", save_selection, actions)
	hint = _label("Ctrl＋左键拖动：只移动选框　R：旋转 2°", ui)
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_shadow_color", Color(0.97, 0.95, 0.85))
	hint.add_theme_constant_override("shadow_outline_size", 3)
	placement_hint = _label("", ui)
	placement_hint.add_theme_color_override("font_shadow_color", Color(0.97, 0.95, 0.85))
	placement_hint.add_theme_constant_override("shadow_outline_size", 4)
	backdrop = ColorRect.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.035, 0.031, 0.024, 0.65)
	ui.add_child(backdrop)
	panel = PanelContainer.new()
	panel.name = "BlueprintLibrary"
	ui.add_child(panel)
	var contents := VBoxContainer.new()
	contents.add_theme_constant_override("separation", 10)
	panel.add_child(contents)
	var header := HBoxContainer.new()
	contents.add_child(header)
	_title = _label("蓝图手册", header)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.add_theme_font_size_override("font_size", 24)
	_button("返回  Esc", close, header)
	contents.add_child(HSeparator.new())
	_body = HBoxContainer.new()
	_body.add_theme_constant_override("separation", 16)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	contents.add_child(_body)
	_save_preview = Preview.instantiate()
	_save_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(_save_preview)
	_library = VBoxContainer.new()
	_library.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(_library)
	_search = LineEdit.new()
	_search.placeholder_text = "搜索名称、描述或标签…"
	_search.text_changed.connect(func(_value): _page = 0; _refresh_cards())
	_library.add_child(_search)
	_favorites = CheckButton.new()
	_favorites.text = "只看收藏"
	_favorites.toggled.connect(func(_value): _page = 0; _refresh_cards())
	_library.add_child(_favorites)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_library.add_child(scroll)
	_cards = GridContainer.new()
	_cards.columns = 2
	_cards.add_theme_constant_override("h_separation", 8)
	_cards.add_theme_constant_override("v_separation", 8)
	_cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_cards)
	var pager := HBoxContainer.new()
	_library.add_child(pager)
	_previous_page = _button("上一页", func(): _page = maxi(0, _page - 1); _refresh_cards(), pager)
	_page_label = _label("", pager)
	_page_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_next_page = _button("下一页", func(): _page += 1; _refresh_cards(), pager)
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 292
	_body.add_child(right)
	var detail_scroll := ScrollContainer.new()
	detail_scroll.custom_minimum_size.x = 292
	detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(detail_scroll)
	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override("separation", 4)
	_detail.custom_minimum_size.x = 272
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.add_child(_detail)
	_preview = Preview.instantiate()
	_preview.custom_minimum_size = Vector2(220, 112)
	_detail.add_child(_preview)
	_name = LineEdit.new()
	_name.max_length = 64
	_name.placeholder_text = "蓝图名称"
	# 回车即提交。以前只有点按钮才写盘，打完名字直接按回车会被静默丢掉，
	# 切到另一张蓝图时再被磁盘上的旧名字覆盖。
	_name.text_submitted.connect(func(_text): _save_pressed())
	_detail.add_child(_name)
	_description = TextEdit.new()
	_description.custom_minimum_size.y = 48
	_description.placeholder_text = "写下用途或使用方法…"
	_description.add_theme_stylebox_override("normal", InkTheme.get_stylebox("normal", "LineEdit"))
	_description.add_theme_stylebox_override("focus", InkTheme.get_stylebox("focus", "LineEdit"))
	_description.add_theme_color_override("font_color", Color(0.035, 0.031, 0.024))
	_description.add_theme_color_override("caret_color", Color(0.035, 0.031, 0.024))
	_detail.add_child(_description)
	_tags = LineEdit.new()
	_tags.placeholder_text = "标签，以逗号分隔"
	_detail.add_child(_tags)
	_info = _label("", _detail)
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.add_theme_font_size_override("font_size", 13)
	_status = _label("", _detail)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", Color(0.55, 0.22, 0.12))
	var footer := VBoxContainer.new()
	right.add_child(footer)
	_use = _button("使用蓝图", _use_selected, footer)
	_use.theme_type_variation = &"PrimaryButton"
	_save = _button("保存信息", _save_pressed, footer)
	var management := HBoxContainer.new()
	footer.add_child(management)
	_favorite = _button("收藏", _toggle_favorite, management)
	_delete = _button("删除蓝图", _trash_selected, management)
	_delete.theme_type_variation = &"DangerButton"
	for field in [_search, _name, _tags, _description]:
		field.add_theme_color_override("font_placeholder_color", Color(0.25, 0.235, 0.204, 0.75))
	toast = _label("", ui)
	toast.add_theme_color_override("font_shadow_color", Color(0.97, 0.95, 0.85))
	toast.add_theme_constant_override("shadow_outline_size", 6)
	backdrop.hide()
	panel.hide()
	actions.hide()
	hint.hide()
	placement_hint.hide()
	toast.hide()

func _layout() -> void:
	var size := get_viewport().get_visible_rect().size
	var extent := Vector2(minf(900, size.x - 28), minf(500, size.y - 24))
	panel.position = (size - extent) * 0.5
	panel.size = extent
	_cards.columns = 2 if size.x >= 820 else 1
	toast.position = Vector2(24, size.y - 52)

func _current_level() -> Node:
	var router := get_tree().get_first_node_in_group(&"level_router")
	if router != null and router.level_root.get_child_count() > 0:
		return router.level_root.get_child(0)
	var player := get_tree().get_first_node_in_group(&"player")
	return player.get_parent() if player != null else null

func _available_canvases() -> Array:
	var result: Array = []
	var level := _current_level()
	if level == null:
		return result
	for canvas in get_tree().get_nodes_in_group(&"canvas_workbench"):
		if canvas.get_parent() == level and canvas.active and canvas.visible \
			and (canvas._map_editor_mode or canvas.is_player_near_workbench()):
			result.append(canvas)
	return result

func target_canvas() -> Node:
	var canvases := _available_canvases()
	if is_instance_valid(_selection_canvas) and canvases.has(_selection_canvas):
		return _selection_canvas
	var mouse := get_viewport().get_mouse_position()
	var best: Node
	var distance := INF
	for canvas in canvases:
		var rect := Rect2(Vector2.ZERO, Vector2(canvas.surface.canvas_size))
		var local: Vector2 = canvas.surface.get_global_transform_with_canvas().affine_inverse() * mouse
		var d := local.distance_squared_to(local.clamp(rect.position, rect.end))
		if d < distance:
			distance = d
			best = canvas
	return best

func _process(delta: float) -> void:
	if toast.visible and Time.get_ticks_msec() >= _toast_until:
		toast.hide()
	if (modal or placing) and (not is_instance_valid(_level) or _level != _current_level()):
		close()
		cancel_placement()
	if placing:
		_update_placement(delta)
	_update_selection_actions()

func _update_selection_actions() -> void:
	if modal or placing or get_tree().paused:
		actions.hide()
		hint.hide()
		return
	var canvas: Node
	for candidate in _available_canvases():
		if candidate.surface.has_selection() and not candidate.surface._selecting and not candidate.surface._selection_dragging:
			canvas = candidate
			break
	_selection_canvas = canvas
	if canvas == null:
		actions.hide()
		hint.hide()
		return
	var surface = canvas.surface
	var transform: Transform2D = surface.get_global_transform_with_canvas()
	var rect: Rect2i = surface.selection_rect()
	var bounds := transform * Rect2(rect)
	var viewport := get_viewport().get_visible_rect()
	if not bounds.intersects(viewport):
		actions.hide()
		hint.hide()
		return
	# 不可每帧 hide/show：Godot 会在隐藏时清除 Button 的按下状态，
	# 真实鼠标跨帧按下再松开就永远发不出 pressed 信号。
	if not actions.visible:
		actions.show()
		actions.reset_size()
	var x := bounds.end.x + 10
	if x + actions.size.x > viewport.size.x - 8:
		x = bounds.position.x - actions.size.x - 10
	actions.position = Vector2(clampf(x, 8, maxf(8, viewport.size.x - actions.size.x - 8)),
		clampf(bounds.position.y, 8, maxf(8, viewport.size.y - actions.size.y - 8)))
	hint.show()
	hint.reset_size()
	hint.position = Vector2(clampf(bounds.end.x - hint.size.x, 8, maxf(8, viewport.size.x - hint.size.x - 8)),
		clampf(bounds.end.y + 8, 8, maxf(8, viewport.size.y - hint.size.y - 8)))

func _delete_selection() -> void:
	if not is_instance_valid(_selection_canvas) or not _available_canvases().has(_selection_canvas):
		return
	var surface = _selection_canvas.surface
	_selection_canvas._delete_selection(surface.selection_rect(), surface.selection_mask())
	surface.clear_selected_area()

func save_selection() -> void:
	if not is_instance_valid(_selection_canvas) or not _available_canvases().has(_selection_canvas):
		return
	var surface = _selection_canvas.surface
	var data := Codec.capture(_selection_canvas, surface.selection_rect(), surface.selection_mask())
	if data.has("error"):
		notify_user(data.error)
		return
	_save_data = data
	_images.erase("draft")
	_save_data.name = "未命名蓝图 %03d" % (store.list_all().size() + 1)
	_open("save")
	_show_detail(_save_data)
	_name.grab_focus()
	_name.select_all()

func open_library() -> void:
	if modal:
		return
	var menu := get_tree().get_first_node_in_group(&"esc_menu")
	if menu != null and menu.visible:
		return
	var dialogue := get_tree().get_first_node_in_group(&"dialogue_box")
	if dialogue != null and dialogue.log_root.visible:
		dialogue.hide_log()
	cancel_placement()
	_open("library")
	# 删蓝图为真删文件；旧版本留下的 .trash 残骸顺手清掉。
	store.purge_trash()
	_items = store.list_all()
	_search.clear()
	_page = 0
	_refresh_cards()
	_search.grab_focus()

func _open(mode: String) -> void:
	toast.hide()
	_level = _current_level()
	_mode = mode
	_was_paused = get_tree().paused
	modal = true
	get_tree().paused = true
	backdrop.show()
	panel.show()
	_library.visible = mode == "library"
	_save_preview.visible = mode == "save"
	_title.text = "保存蓝图" if mode == "save" else "蓝图手册"
	_save.text = "保存到蓝图库" if mode == "save" else "保存信息"
	_layout()

func close() -> void:
	if not modal:
		return
	modal = false
	backdrop.hide()
	panel.hide()
	get_tree().paused = _was_paused
	_save_data = {}
	_items = []
	_selected = {}
	_preview.set_image(null)
	_save_preview.set_image(null)
	for card in _cards.get_children():
		_cards.remove_child(card)
		card.queue_free()

func _image(data: Dictionary) -> Image:
	# 同一秒内也能保存多次；Store 的文件签名负责失效。
	var key := "draft" if str(data.get("id", "")).is_empty() else store.cache_key(data.id)
	if not _images.has(key):
		if _images.size() > PAGE_SIZE + 2:
			_images.clear()
			_textures.clear()
		_images[key] = Codec.preview(data)
	return _images[key]

func _set_preview(control: Control, data: Dictionary) -> void:
	if data.is_empty():
		control.set_image(null)
		return
	var image := _image(data)
	var key := image.get_instance_id()
	if not _textures.has(key):
		if _textures.size() > PAGE_SIZE + 4:
			_textures.clear()
		_textures[key] = ImageTexture.create_from_image(image)
	control.set_image(image, _textures[key])

func _refresh_cards() -> void:
	for child in _cards.get_children():
		_cards.remove_child(child)
		child.queue_free()
	var filtered: Array = []
	var query := _search.text.strip_edges().to_lower()
	for data in _items:
		if _favorites.button_pressed and not data.favorite:
			continue
		var haystack: String = (data.name + " " + data.description + " " + " ".join(data.tags)).to_lower()
		if query.is_empty() or haystack.contains(query):
			filtered.append(data)
	var pages := maxi(1, ceili(float(filtered.size()) / PAGE_SIZE))
	_page = clampi(_page, 0, pages - 1)
	_page_label.text = "%d / %d · %d 张" % [_page + 1, pages, filtered.size()]
	_previous_page.disabled = _page == 0
	_next_page.disabled = _page >= pages - 1
	if filtered.is_empty():
		_label("还没有蓝图\n框选作品后点击「保存为蓝图」" if _items.is_empty() else "没有匹配的蓝图\n试试其他关键词或关闭收藏筛选", _cards)
	for data in filtered.slice(_page * PAGE_SIZE, (_page + 1) * PAGE_SIZE):
		var card := Button.new()
		card.custom_minimum_size = Vector2(170, 132)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.tooltip_text = data.name
		card.focus_mode = Control.FOCUS_ALL
		card.toggle_mode = true
		card.set_meta("blueprint_id", data.id)
		card.set_pressed_no_signal(data.id == _selected.get("id", ""))
		_cards.add_child(card)
		var box := VBoxContainer.new()
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		box.offset_left = 8
		box.offset_top = 8
		box.offset_right = -8
		box.offset_bottom = -8
		card.add_child(box)
		var preview := Preview.instantiate()
		preview.custom_minimum_size = Vector2(140, 76)
		box.add_child(preview)
		_set_preview(preview, data)
		var title := _label(("★ " if data.favorite else "") + data.name, box)
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		title.custom_minimum_size.x = 140
		title.add_theme_font_size_override("font_size", 14)
		var caption := _label("%d×%d px%s" % [data.size[0], data.size[1], " · 编辑器" if data.editor_only else ""], box)
		caption.add_theme_font_size_override("font_size", 12)
		card.pressed.connect(_show_detail.bind(data))
	if _mode == "library":
		var retained := false
		for data in filtered:
			if data.id == _selected.get("id", ""):
				retained = true
				break
		if not retained:
			_show_detail(filtered[0] if not filtered.is_empty() else {})

func _cost_text(amounts: Dictionary, canvas = null) -> String:
	var text := ""
	var health = canvas.surface._health_node() if is_instance_valid(canvas) else null
	for entry in Palette.INKS:
		var id: int = entry.material.id
		if amounts.get(id, 0) <= 0:
			continue
		text += "%s %d px" % [entry.name, amounts[id]]
		if health != null and not canvas.surface.ink_free:
			text += " / 余 %d" % health.ink_of(id)
		text += "  "
	return text

func _show_detail(data: Dictionary) -> void:
	_selected = data
	for card in _cards.get_children():
		if card is Button:
			card.set_pressed_no_signal(card.get_meta("blueprint_id", "") == data.get("id", ""))
	_confirm_delete = false
	_delete.text = "删除蓝图"
	var empty := data.is_empty()
	_name.editable = not empty
	_description.editable = not empty
	_tags.editable = not empty
	for control in [_use, _save, _favorite, _delete]:
		control.disabled = empty
	_use.visible = _mode == "library"
	_favorite.visible = _mode == "library"
	_delete.visible = _mode == "library"
	_name.text = "" if empty else data.name
	_description.text = "" if empty else data.description
	_tags.text = "" if empty else ", ".join(data.tags)
	_set_preview(_preview, data)
	_set_preview(_save_preview, data)
	var detail := "请选择蓝图" if empty else "%d × %d px\n%s\n齿轮 %d · 弹簧 %d · 动力箭头 %d\n导轨 %d · 滑块销 %d" % [
		data.size[0], data.size[1], _cost_text(Codec.costs(data), target_canvas()),
		data.gears.size(), data.springs.size(), data.motors.size(),
		data.get("rails", []).size(), data.get("slider_pins", []).size()]
	# 显示存档文件名，蓝图手册里的每一张都能和目录里的文件对上号。
	var file := store.file_name(str(data.get("id", "")))
	if not empty and not file.is_empty():
		detail += "\n文件：" + file
	_info.text = detail
	_status.text = ""
	if empty:
		return
	_favorite.text = "取消收藏" if data.favorite else "收藏"
	var canvas := target_canvas()
	if canvas == null:
		_status.text = "请靠近画布使用；地图编辑模式不限制距离"
	elif data.editor_only and not canvas._map_editor_mode:
		_status.text = "含齿轮的蓝图仅编辑器可用"
	_use.disabled = canvas == null or (data.editor_only and not canvas._map_editor_mode)

func _metadata(data: Dictionary) -> void:
	data.name = _name.text.strip_edges()
	data.description = _description.text.left(2000)
	data.tags = []
	for tag in _tags.text.replace("，", ",").split(",", false):
		var value := tag.strip_edges().left(24)
		if not value.is_empty() and not data.tags.has(value) and data.tags.size() < 8:
			data.tags.append(value)

func _save_pressed() -> void:
	if _selected.is_empty():
		return
	var data := _selected.duplicate(true)
	_metadata(data)
	if not store.save(data):
		_status.text = store.error
		return
	if _mode == "save":
		close()
		notify_user("已保存到蓝图库")
	else:
		_items = store.list_all()
		_images.clear()
		_textures.clear()
		_refresh_cards()
		_show_detail(data)
		_status.text = "信息已保存"

func _toggle_favorite() -> void:
	if _selected.is_empty():
		return
	var data := _selected.duplicate(true)
	data.favorite = not data.favorite
	if store.save(data):
		_items = store.list_all()
		_refresh_cards()
		_show_detail(data)
	else:
		_status.text = store.error

func _trash_selected() -> void:
	if _selected.is_empty():
		return
	if not _confirm_delete:
		_confirm_delete = true
		_delete.text = "再次点击确认"
		_status.text = "仅移入蓝图回收文件，不影响地图中的作品"
		return
	if store.trash(_selected.id):
		_items = store.list_all()
		_refresh_cards()
		_show_detail(_items[0] if not _items.is_empty() else {})
	else:
		_status.text = "无法删除，蓝图已保留"

func _use_selected() -> void:
	if not _selected.is_empty():
		begin_placement(_selected)

func begin_placement(data: Dictionary) -> bool:
	var canvas := target_canvas()
	if canvas == null or (data.editor_only and not canvas._map_editor_mode):
		_status.text = "请靠近画布，或在地图编辑器中使用此蓝图"
		return false
	if not Store.validate(data):
		return false
	close()
	_placement = Placement.new()
	if not _placement.begin(canvas, data):
		_placement = null
		return false
	placing = true
	_canvas = canvas
	_level = _current_level()
	_old_tool = canvas.surface.tool
	canvas.set_tool(canvas.SurfaceScript.Tool.SELECT_DELETE)
	canvas.surface.clear_selected_area()
	placement_hint.show()
	_update_placement(1.0)
	return true

func cancel_placement() -> void:
	if not placing:
		return
	placing = false
	if _placement != null:
		_placement.cancel()
		_placement = null
	if is_instance_valid(_canvas) and _canvas.is_inside_tree():
		_canvas.set_tool(_old_tool)
	_canvas = null
	placement_hint.hide()

func _update_placement(delta: float, screen_point := Vector2.INF) -> void:
	if _placement == null or not _available_canvases().has(_canvas) or not _placement.is_active():
		cancel_placement()
		notify_user("已取消放置：目标画布不可用或已离开画布")
		return
	var mouse: Vector2 = get_viewport().get_mouse_position() if screen_point == Vector2.INF else screen_point
	_placement.update(delta, mouse)
	_last_error = _placement.error
	var controls := "左键放置 · Shift＋左键连续放置 · 右键 / Esc 取消"
	placement_hint.text = (controls + "\n" + _cost_text(_placement.amounts, _canvas)) if _last_error.is_empty() \
		else "无法放置：" + _last_error + "\n" + controls
	placement_hint.reset_size()
	var size := get_viewport().get_visible_rect().size
	var preview_corner: Vector2 = _placement.ghost_corner_screen()
	placement_hint.position = Vector2(
		clampf(preview_corner.x, 12, maxf(12, size.x - placement_hint.size.x - 12)),
		clampf(preview_corner.y - placement_hint.size.y - 8, 12, maxf(12, size.y - placement_hint.size.y - 12)))

func _input(event: InputEvent) -> void:
	if modal:
		if event.is_action_pressed("escape"):
			close()
			get_viewport().set_input_as_handled()
		return
	if not placing:
		return
	if event.is_action_pressed("escape") or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT):
		cancel_placement()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _pointer_over_ui(event.position):
			cancel_placement()
			return
		get_viewport().set_input_as_handled()
		# 使用这次点击的位置，而不是上一帧的鼠标轮询值。
		_update_placement(1.0, event.position)
		if not placing:
			return
		var error: String = _placement.commit()
		if not error.is_empty():
			notify_user(error)
		elif not event.shift_pressed:
			cancel_placement()
		else:
			_placement.check_elapsed = 1.0

func notify_user(message: String) -> void:
	toast.text = message
	toast.show()
	_toast_until = Time.get_ticks_msec() + 4000

func _exit_tree() -> void:
	if modal:
		get_tree().paused = _was_paused
