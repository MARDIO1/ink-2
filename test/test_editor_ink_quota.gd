extends SceneTree
## 地图编辑器右侧的「关卡墨水配额」表格：改的是关卡根节点的 starting_ink，只对当前地图生效。

const Palette := preload("res://ink/general/src/ink_palette.gd")
var failures := 0
var checks := 0


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[InkQuota] %s %s" % ["PASS" if ok else "FAIL", label])


func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	await process_frame
	var creative = level.get_node("Creative")
	creative.auto_save_on_exit = false
	creative.auto_save_edits = false
	creative.set_active(true)
	await process_frame
	var health = level.get_node_or_null("Player/InkHealth")
	check("level has an ink health node", health != null)
	if health == null:
		quit(1)
		return
	# 进入编辑器本身不该占用一次撤销。
	creative._clear_edit_history()

	var grid = creative._monster_palette.get_node_or_null(
		"Root/Panel/Scroll/Margin/VBox/InkQuotaGrid")
	check("toolbar has the ink quota table", grid != null)
	if grid == null:
		quit(1)
		return
	check("quota table has one row per ink", grid.get_child_count() == Palette.ink_count() * 2)
	for entry in Palette.INKS:
		var quota: SpinBox = creative._ink_quota_fields[entry.material.id]
		check("%s displays 20000 initially" % entry.name, quota.get_line_edit().text.contains("20000")
			and is_equal_approx(quota.value, 20000.0))
		var line := quota.get_line_edit()
		var text_width := line.get_theme_font("font").get_string_size(line.text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, line.get_theme_font_size("font_size")).x
		check("%s quota text fits without clipping" % entry.name,
			line.size.x - line.get_theme_stylebox("normal").get_minimum_size().x >= text_width)

	var blue: int = Palette.BLUE.id
	var red: int = Palette.RED.id
	var field: SpinBox = creative._ink_quota_fields.get(blue)
	check("blue has a quota field", field != null)
	if field == null:
		quit(1)
		return
	check("quota starts from the player default", is_equal_approx(field.value, health.max_ink)
		and is_equal_approx(creative.ink_quota_of(red), health.max_ink))

	field.value = 35000.0
	await process_frame
	check("editing writes into this map's starting_ink",
		is_equal_approx(float(level.starting_ink.get(blue, 0.0)), 35000.0))
	check("live capacity follows without reloading the level",
		is_equal_approx(health.max_of(blue), 35000.0))
	check("other colors keep the player default", is_equal_approx(health.max_of(red), health.max_ink))
	check("raising the quota does not silently refill the player",
		is_equal_approx(health.ink_of(blue), 20000.0))

	check("quota edit is undoable", creative.undo_last_edit() and not level.starting_ink.has(blue))
	check("undo refreshes the table", is_equal_approx(field.value, health.max_ink)
		and is_equal_approx(health.max_of(blue), health.max_ink))
	check("quota edit is redoable", creative.redo_last_edit()
		and is_equal_approx(float(level.starting_ink.get(blue, 0.0)), 35000.0))

	creative.reset_ink_quota()
	check("reset clears this map's quota",
		level.starting_ink.is_empty() and is_equal_approx(health.max_of(blue), health.max_ink)
		and is_equal_approx(field.value, health.max_ink))

	field.value = 12000.0
	await process_frame
	check("quota is stored on the map node itself",
		is_equal_approx(float(level.starting_ink.get(blue, 0.0)), 12000.0))
	var other = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	check("a fresh map does not inherit the quota", other.get("starting_ink").is_empty())
	other.free()

	level.queue_free()
	await process_frame
	print("[InkQuota] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
