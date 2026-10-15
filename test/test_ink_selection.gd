extends SceneTree
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, ok: bool) -> void:
	print("[InkSelection] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _verify(buttons: Array, selected: int) -> bool:
	var marked := 0
	for i in buttons.size():
		var marker: Control = buttons[i].get_node("InkSelectionIndicator")
		if marker.selected:
			marked += 1
		if marker.selected != (i == selected) or buttons[i].button_pressed != (i == selected):
			return false
		if marker.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			return false
	return marked == 1

func _run() -> void:
	var level: Node = load("res://map/asset/imported/main.tscn").instantiate()
	root.add_child(level)
	await process_frame
	var play: Node = level.get_node("SmallCanvas")
	_check("play initial selection visible", _verify(play._ink_buttons, play.surface.selected_ink))
	_check("play palette includes every ink", play._ink_buttons.size() == play.InkPalette.ink_count())
	var white_index: int = -1
	var blue_index: int = -1
	for index in play.InkPalette.ink_count():
		if play.InkPalette.ink_at(index) == play.InkPalette.WHITE:
			white_index = index
		if play.InkPalette.ink_at(index) == play.InkPalette.BLUE:
			blue_index = index
	_check("blue entry registered", blue_index >= 0)
	_check("white entry uses white material", play.InkPalette.ink_at(white_index) == play.InkPalette.WHITE)
	var white_button: Button = play._ink_buttons[white_index]
	var black_button: Button = play._ink_buttons[0]
	var white_style := white_button.get_theme_stylebox("normal") as StyleBoxFlat
	var black_style := black_button.get_theme_stylebox("normal") as StyleBoxFlat
	_check("white matches palette size and rounded border", white_button.custom_minimum_size == black_button.custom_minimum_size
		and white_style.corner_radius_top_left == black_style.corner_radius_top_left
		and white_style.border_width_left == black_style.border_width_left
		and white_style.bg_color == play.InkPalette.color_of(play.InkPalette.WHITE))
	_check("white indicator stays legible", white_button.get_node("InkSelectionIndicator").contrast == Color.BLACK)
	for index in play.InkPalette.ink_count():
		play._ink_buttons[index].pressed.emit()
		_check("play color and persistent indicator", play.surface.selected_ink == index and _verify(play._ink_buttons, index))
		_check("play label names actual ink", play._selected_ink_label.text == "当前：%s" % play.InkPalette.ink_name(index))
	var creative: Node = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.set_active(true)
	_check("editor initial selection visible", _verify(creative._editor_ink_buttons, creative._map_canvas.surface.selected_ink))
	_check("editor palette includes white", creative._editor_ink_buttons.size() == creative.InkPalette.ink_count()
		and creative._editor_ink_buttons[white_index].tooltip_text == "白墨")
	_check("editor colors share one row", (creative._editor_ink_buttons[white_index].get_parent() as GridContainer).columns == creative.InkPalette.ink_count())
	_check("editor white matches other color buttons", creative._editor_ink_buttons[white_index].custom_minimum_size == creative._editor_ink_buttons[0].custom_minimum_size
		and creative._editor_ink_buttons[white_index].get_node("InkSelectionIndicator").contrast == Color.BLACK)
	for index in [1, 2, 3, white_index, blue_index, 0]:
		creative._editor_ink_buttons[index].pressed.emit()
		_check("editor click updates canvas and indicator", creative._map_canvas.surface.selected_ink == index and _verify(creative._editor_ink_buttons, index))
		_check("editor label names actual ink", creative._editor_ink_label.text.ends_with(creative.InkPalette.ink_name(index)))
		_check("selection animates", creative._editor_ink_buttons[index].get_node("InkSelectionIndicator").pulse > 0.0)
	creative._map_canvas.select_ink(2)
	_check("external canvas selection syncs editor UI", _verify(creative._editor_ink_buttons, 2))
	await create_timer(0.3).timeout
	_check("animation ends but marker remains", creative._editor_ink_buttons[2].get_node("InkSelectionIndicator").pulse == 0.0 and _verify(creative._editor_ink_buttons, 2))
	creative._editor_ink_buttons[2].pressed.emit()
	_check("repeat click cannot unselect", _verify(creative._editor_ink_buttons, 2))
	if OS.get_cmdline_user_args().has("--preview"):
		creative._toggle_monster_palette_panel()
		await process_frame
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute("D:/Ink/output")
		root.get_texture().get_image().save_png("D:/Ink/output/ink_selection_preview.png")
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
