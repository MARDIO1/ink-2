extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var level = load("res://map/main.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	var play_canvas = level.get_node("SmallCanvas")
	var play_caption: Label = play_canvas.hand_button.get_node("Caption")
	var play_brush_caption: Label = play_canvas.tool_grid.get_node("Brush/Caption")
	var captions_valid: bool = play_caption.text == "放下画笔" \
		and play_caption.get_theme_font_size("font_size") == play_brush_caption.get_theme_font_size("font_size") \
		and play_caption.get_theme_font("font") == play_brush_caption.get_theme_font("font")
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.set_active(true)
	var row = creative._monster_palette_panel.find_child("BrushSizeRow", true, false)
	var slider: HSlider = row.get_node("BrushSizeSlider")
	var label: Label = row.get_node("BrushSizeLabel")
	var canvas = creative._map_canvas
	var source: HSlider = canvas.brush_panel.get_node("PenSlider")
	var editor_caption: Label = canvas.hand_button.get_node("Caption")
	var editor_brush_caption: Label = canvas.tool_grid.get_node("Brush/Caption")
	captions_valid = captions_valid and editor_caption.text == "放下画笔" \
		and editor_caption.get_theme_font_size("font_size") == editor_brush_caption.get_theme_font_size("font_size") \
		and editor_caption.get_theme_font("font") == editor_brush_caption.get_theme_font("font")
	print("[HandCaption] matching captions in play and editor: ", "PASS" if captions_valid else "FAIL")
	slider.value = 13
	var valid: bool = canvas.surface.brush_size == 13 and source.value == 13 \
		and label.text == "粗细：13 px"
	source.value = 5
	valid = valid and slider.value == 5 and canvas.surface.brush_size == 5 \
		and label.text == "粗细：5 px"
	print("[EditorBrushSize] slider, brush and original control synchronized: ", "PASS" if valid else "FAIL")
	level.queue_free()
	await process_frame
	quit(0 if valid and captions_valid else 1)
