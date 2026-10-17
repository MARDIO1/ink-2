extends SceneTree

const Store := preload("res://ui/hud/blueprint/src/blueprint_store.gd")
const Codec := preload("res://actor/canvas/blueprint/src/blueprint_codec.gd")
const Surface := preload("res://actor/canvas/src/canvas_surface.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	failures += int(not okay)
	print("[CanvasIssues] %s %s" % ["PASS" if okay else "FAIL", label])

func _run() -> void:
	var body = load("res://addons/pixel_destruction/physics/pbody.gd").new()
	var shape = load("res://addons/pixel_destruction/core/pixel_shape.gd").new()
	shape.set_pixel(0, 0, Palette.BLACK.id)
	body.rebuild([shape])
	check("shape can query its live owner", shape.owner_body == body)
	var body_ref: WeakRef = weakref(body)
	body = null
	check("retaining shape does not leak removed body", body_ref.get_ref() == null and shape.owner_body == null)
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	level.starting_ink[Palette.BLACK.id] = 35000.0
	level.starting_ink[Palette.YELLOW.id] = 4200.0
	root.add_child(level)
	await process_frame
	var health = level.get_node("Player/InkHealth")
	check("map quotas initialize before player ready", health.ink_of(Palette.BLACK.id) == 35000.0
		and health.ink_of(Palette.YELLOW.id) == 4200.0 and health.ink_of(Palette.GREY.id) == 20000.0)
	health.reduce(Palette.BLACK.id, 1000)
	health.add(Palette.BLACK.id, 50000)
	check("refills and ratios respect per-color map caps", health.ink_of(Palette.BLACK.id) == 35000
		and health.ratio_of(Palette.BLACK.id) == 1 and health.ratio() == 1)
	var canvas = level.get_node("MapCanvas")
	canvas.active = true
	canvas.set_map_editor_mode(true)
	canvas.canvas_size = Vector2i(128, 96)
	var surface = canvas.surface
	var large := Surface.new()
	large.canvas_size = Vector2i(4096, 2048)
	large.tool = Surface.Tool.RECT
	large.brush_size = 7
	var large_start := Time.get_ticks_usec()
	var large_pixels: Dictionary = large._shape_pixels(Vector2.ZERO, Vector2(4096, 2048))
	print("[CanvasIssues] 4096x2048 rectangle contour: %.2f ms" % ((Time.get_ticks_usec() - large_start) / 1000.0))
	check("large rectangle generates only perimeter pixels", large_pixels.size() == 2 * (4096 + 2048 - 14) * 7)
	large.free()
	surface.ink_free = false
	surface.clear()
	surface.tool = Surface.Tool.RECT
	var matching := true
	for thickness in [1, 2, 7, 40]:
		surface.brush_size = thickness
		for endpoints in [[Vector2(10.5, 20.5), Vector2(100.5, 80.5)],
			[Vector2(100.5, 80.5), Vector2(10.5, 20.5)],
			[Vector2.ZERO, Vector2(128, 96)], [Vector2(20, 30), Vector2(20, 30)],
			[Vector2(4, 10), Vector2(4, 80)]]:
			var pixels: Dictionary = surface._shape_pixels(endpoints[0], endpoints[1])
			var lo := Vector2i(endpoints[0].min(endpoints[1]).floor())
			var hi := Vector2i(endpoints[0].max(endpoints[1]).ceil()) - Vector2i.ONE
			hi = hi.max(lo)
			var expected := {}
			for y in range(lo.y, hi.y + 1):
				for x in range(lo.x, hi.x + 1):
					if x - lo.x < thickness or hi.x - x < thickness or y - lo.y < thickness or hi.y - y < thickness:
						expected[Vector2i(x, y)] = true
			matching = matching and pixels == expected
	check("rectangle contours match reference including reverse and degenerate drags", matching)
	surface.brush_size = 3
	surface._shape_origin = Vector2(10, 10)
	surface._begin_undo_step()
	surface._preview_shape(Vector2(80, 70))
	surface._preview_shape(Vector2(90, 60))
	var expected: Dictionary = surface._shape_pixels(Vector2(10, 10), Vector2(90, 60))
	check("drag delta removes old edges and keeps new shape exact", surface.black_image.get_used_rect() == Rect2i(10, 10, 80, 50)
		and surface.ink_px_of(Palette.BLACK.id) == expected.size())
	var start := Time.get_ticks_usec()
	for i in 100:
		surface._preview_shape(Vector2(90, 60))
	print("[CanvasIssues] stationary preview 100 frames: %.3f ms" % ((Time.get_ticks_usec() - start) / 1000.0))
	surface._shape_saved.clear()
	surface._shape_preview_key.clear()
	surface._commit_undo_step()
	check("rectangle undo clears entire drag", surface.undo_last_edit() and surface.ink_px_of(Palette.BLACK.id) == 0)
	check("rectangle redo restores final contour only", surface.redo_last_edit() and surface.ink_px_of(Palette.BLACK.id) == expected.size())
	surface._revert_shape()
	var data := {"version": 1, "id": "", "name": "cache", "description": "", "tags": [],
		"updated": 0, "favorite": false, "editor_only": false, "size": [160, 192],
		"pixels": [], "rods": [], "blue": [], "anchors": [], "springs": [], "motors": [], "bodies": [], "gears": []}
	for i in 160 * 192:
		data.pixels.append([i, Palette.BLACK.id if i % 3 else Palette.GREY.id])
	var store := Store.new()
	store.directory = "user://canvas_issue_test_%d" % Time.get_ticks_usec()
	var saved := true
	for i in 5:
		data.id = "sample%d" % i
		saved = store.save(data) and saved
	check("five representative 30k-pixel blueprints saved in isolated directory", saved)
	start = Time.get_ticks_usec()
	var cold := store.list_all()
	var cold_ms := (Time.get_ticks_usec() - start) / 1000.0
	start = Time.get_ticks_usec()
	var warm := store.list_all()
	var warm_ms := (Time.get_ticks_usec() - start) / 1000.0
	print("[CanvasIssues] five blueprints cold=%.2f ms warm=%.2f ms" % [cold_ms, warm_ms])
	check("warm listing reuses five validated file entries", cold.size() == 5 and warm.size() == 5 and store._cache.size() == 5)
	warm[0].pixels.clear()
	check("callers cannot mutate cached pixel data", store.read(warm[0].id).pixels.size() == 160 * 192)
	var changed := store.read("sample0")
	changed.name = "renamed"
	check("same-second save invalidates cache", store.save(changed) and store.read("sample0").name == "renamed")
	var file := FileAccess.open(store.directory.path_join("sample0.inkbp"), FileAccess.WRITE)
	changed.name = "external size change"
	file.store_string(JSON.stringify(changed))
	file.close()
	check("external file size change invalidates cache", store.read("sample0").name == changed.name)
	start = Time.get_ticks_usec()
	var preview := Codec.preview(cold[0])
	print("[CanvasIssues] 30k-pixel preview: %.2f ms" % ((Time.get_ticks_usec() - start) / 1000.0))
	var same := true
	for entry in cold[0].pixels:
		var actual := preview.get_pixelv(Codec.cell(entry[0], 160))
		var color := Palette.color_for_material_id(entry[1])
		same = same and absf(actual.r - color.r) <= 1.0 / 255 and absf(actual.g - color.g) <= 1.0 / 255 and absf(actual.b - color.b) <= 1.0 / 255 and actual.a == color.a
	check("batched preview preserves every pixel color", same)
	check("trash removes cached blueprint from library", store.trash("sample0") and store.list_all().size() == 4)
	var ui = load("res://ui/game_ui.tscn").instantiate()
	root.add_child(ui)
	await process_frame
	var hud = ui.get_node("Hud")
	var menu = ui.get_node("Esc")
	check("gameplay HUD buttons cannot retain keyboard focus", hud.get_node("Root/ExitButton").focus_mode == Control.FOCUS_NONE
		and hud.get_node("Root/LogButton").focus_mode == Control.FOCUS_NONE)
	hud.get_node("Root/ExitButton").pressed.emit()
	menu._on_continue_button_pressed()
	for pressed in [true, false]:
		var space := InputEventKey.new()
		space.keycode = KEY_SPACE
		space.physical_keycode = KEY_SPACE
		space.pressed = pressed
		root.push_input(space, true)
	check("space after closing pause menu cannot reopen it", not menu.visible and not paused)
	var blueprints = root.get_node("Blueprints")
	var original_store = blueprints.store
	blueprints.store = store
	start = Time.get_ticks_usec()
	blueprints.open_library()
	var first_open_ms := (Time.get_ticks_usec() - start) / 1000.0
	var cached_image = blueprints._image(blueprints._items[0])
	var cached_texture = blueprints._textures[cached_image.get_instance_id()]
	blueprints.close()
	start = Time.get_ticks_usec()
	blueprints.open_library()
	print("[CanvasIssues] library build first=%.2f ms reopen=%.2f ms" % [first_open_ms, (Time.get_ticks_usec() - start) / 1000.0])
	check("library reopen retains previews and uploaded textures", blueprints._image(blueprints._items[0]) == cached_image
		and blueprints._textures[cached_image.get_instance_id()] == cached_texture)
	blueprints.close()
	blueprints.store = original_store
	var layout := Control.new()
	layout.size = root.size
	root.add_child(layout)
	check("noninteractive full-screen layout does not cancel blueprint placement", not blueprints._pointer_over_ui(Vector2(300, 250)))
	layout.free()
	for name in DirAccess.get_files_at(store.directory):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(store.directory.path_join(name)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(store.directory))
	ui.queue_free()
	level.queue_free()
	await process_frame
	print("[CanvasIssues] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
