extends SceneTree

const Tool := preload("res://actor/canvas/src/canvas_surface.gd").Tool
var checks := 0
var failures := 0

class SurfaceProbe extends Node2D:
	var canvas_size := Vector2i(100, 80)
	var brush_size := 7
	var tool := Tool.BRUSH
	func _inside(point: Vector2) -> bool:
		return Rect2(Vector2.ZERO, Vector2(canvas_size)).has_point(point)

class CanvasProbe extends Node2D:
	var active := true

class EditorProbe extends Node:
	const MONSTER_MODE_NONE := -1
	var active := false
	var _monster_mode := MONSTER_MODE_NONE
	var _dragging_monster := false
	var _layout_drag_target: Node

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	print("[GameCursor] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1

func _click(position: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	root.push_input(motion, true)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = position
		root.push_input(event, true)

func _run() -> void:
	var cursor := root.get_node("InkCursor")
	cursor.set_process(false)
	# 隔离测试替身，避免蓝图库将替身当作真实画布轮询。
	root.get_node("Blueprints").set_process(false)
	check("project loads cursor overlay once", cursor.scene_file_path == "res://ui/cursor/cursor.tscn" and root.get_node_or_null("InkCursor2") == null)
	check("menus keep system cursor", not cursor._has_gameplay())
	cursor._refresh_cursor(Vector2(20, 20), false, false)
	check("inactive overlay does not own mouse", not cursor.pointer.visible and not cursor._owns_mouse)
	check("provided images retain original dimensions", cursor.CANVAS_TEXTURE.get_size() == Vector2(60, 60) and cursor.WORLD_TEXTURE.get_size() == Vector2(60, 76))
	check("overlay ignores GUI input and runs while paused", cursor.pointer.mouse_filter == Control.MOUSE_FILTER_IGNORE and cursor.pointer.focus_mode == Control.FOCUS_NONE and cursor.process_mode == Node.PROCESS_MODE_ALWAYS and cursor.layer > 1000)
	check("pixel art uses nearest filtering", cursor.pointer.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST)
	var level := Node2D.new()
	root.add_child(level)
	var player := Node2D.new()
	level.add_child(player)
	player.add_to_group(&"player")
	check("independent levels enable gameplay cursor", cursor._has_gameplay())
	var canvas := CanvasProbe.new()
	canvas.position = Vector2(100, 100)
	level.add_child(canvas)
	canvas.add_to_group(&"canvas_workbench")
	var surface := SurfaceProbe.new()
	surface.name = "CanvasSurface"
	canvas.add_child(surface)
	var inside := Vector2(150, 140)
	cursor._refresh_cursor(inside, true, false)
	check("inside canvas selects ring", cursor.pointer.visible and cursor.pointer.texture == cursor.CANVAS_TEXTURE and cursor._owns_mouse)
	if DisplayServer.get_name() != "headless":
		check("system cursor is hidden while custom cursor is visible", Input.mouse_mode == Input.MOUSE_MODE_HIDDEN)
	check("ring center is click hotspot", (cursor.pointer.position + cursor.pointer.size / 2).is_equal_approx(inside))
	check("small brush retains minimum visible ring", is_equal_approx(cursor.pointer.size.x * 52.0 / 60.0, 12.0))
	surface.brush_size = 1
	cursor._refresh_cursor(inside, true, false)
	check("single pixel brush stays visible", is_equal_approx(cursor.pointer.size.x * 52.0 / 60.0, 12.0))
	surface.brush_size = 33
	cursor._refresh_cursor(inside, true, false)
	check("ring outer edge follows brush diameter not transparent padding", is_equal_approx(cursor.pointer.size.x * 52.0 / 60.0, 33.0))
	for tool in [Tool.NAIL, Tool.GEAR, Tool.GEAR_8]:
		surface.tool = tool
		cursor._refresh_cursor(inside, true, false)
		check("placement tool %d uses arrow without moving click hotspot" % tool, cursor.pointer.texture == cursor.WORLD_TEXTURE and (cursor.pointer.position + Vector2(2, 1)).is_equal_approx(inside))
	surface.tool = Tool.BRUSH
	var editor := EditorProbe.new()
	editor.name = "Creative"
	level.add_child(editor)
	editor.active = true
	editor._monster_mode = -14 # 传送门/其他地图部件，所有非 NONE 布局模式均使用箭头。
	cursor._refresh_cursor(inside, true, false)
	check("editor placement uses arrow over drawing surface", cursor.pointer.texture == cursor.WORLD_TEXTURE)
	editor._monster_mode = -1
	editor._dragging_monster = true
	cursor._refresh_cursor(inside, true, false)
	check("immediate component drag retains arrow", cursor.pointer.texture == cursor.WORLD_TEXTURE)
	editor._dragging_monster = false
	root.get_node("Blueprints").placing = true
	cursor._refresh_cursor(inside, true, false)
	check("blueprint placement uses arrow", cursor.pointer.texture == cursor.WORLD_TEXTURE)
	root.get_node("Blueprints").placing = false
	cursor._refresh_cursor(inside, true, false)
	check("returning to drawing restores brush ring", cursor.pointer.texture == cursor.CANVAS_TEXTURE)
	check("canvas boundaries match drawing half-open bounds", cursor._canvas_at(Vector2(100, 100)) == canvas and cursor._canvas_at(Vector2(200, 140)) == null and cursor._canvas_at(Vector2(150, 180)) == null)
	var outside := Vector2(400, 250)
	cursor._refresh_cursor(outside, true, false)
	check("outside canvas selects arrow with tip hotspot", cursor.pointer.texture == cursor.WORLD_TEXTURE and cursor.pointer.position + Vector2(2, 1) == outside and cursor.pointer.size == Vector2(15, 19))
	cursor._refresh_cursor(inside, true, true)
	check("GUI over canvas selects arrow", cursor.pointer.texture == cursor.WORLD_TEXTURE)
	canvas.active = false
	check("inactive canvas is ignored", cursor._canvas_at(inside) == null)
	canvas.active = true
	canvas.hide()
	check("hidden canvas is ignored", cursor._canvas_at(inside) == null)
	canvas.show()
	surface.hide()
	check("hidden drawing surface is ignored", cursor._canvas_at(inside) == null)
	surface.show()
	root.canvas_transform = Transform2D(0.0, Vector2(2, 2), 0.0, Vector2(40, -30))
	var transformed := surface.get_global_transform_with_canvas() * Vector2(50, 40)
	check("camera zoom and pan use visible drawing coordinates", cursor._canvas_at(transformed) == canvas and cursor._canvas_at(inside) == null)
	cursor._refresh_cursor(transformed, true, false)
	check("zoom doubles brush ring diameter", is_equal_approx(cursor.pointer.size.x * 52.0 / 60.0, 66.0))
	root.canvas_transform = Transform2D(0.0, Vector2(0.1, 0.1), 0.0, Vector2(40, 30))
	transformed = surface.get_global_transform_with_canvas() * Vector2(50, 40)
	cursor._refresh_cursor(transformed, true, false)
	check("zooming far out retains minimum visible ring", is_equal_approx(cursor.pointer.size.x * 52.0 / 60.0, 12.0))
	root.canvas_transform = Transform2D.IDENTITY
	canvas.rotation = 0.4
	canvas.scale = Vector2(1.5, 0.8)
	transformed = surface.get_global_transform_with_canvas() * Vector2(50, 40)
	check("rotated scaled canvas uses local bounds", cursor._canvas_at(transformed) == canvas)
	cursor._refresh_cursor(transformed, true, false)
	check("nonuniform canvas scale matches ring axes", is_equal_approx(cursor.pointer.size.x * 52.0 / 60.0, 49.5) and is_equal_approx(cursor.pointer.size.y * 52.0 / 60.0, 26.4))
	check("rotated ring remains centered on click", (cursor.pointer.position + (cursor.pointer.size * 0.5).rotated(cursor.pointer.rotation)).is_equal_approx(transformed))
	canvas.rotation = 0
	canvas.scale = Vector2.ONE
	var second := CanvasProbe.new()
	second.position = Vector2(300, 100)
	level.add_child(second)
	second.add_to_group(&"canvas_workbench")
	var second_surface := SurfaceProbe.new()
	second_surface.name = "CanvasSurface"
	second.add_child(second_surface)
	check("multiple canvases are detected independently", cursor._canvas_at(Vector2(350, 140)) == second and cursor._canvas_at(inside) == canvas)
	second_surface.brush_size = 21
	cursor._refresh_cursor(Vector2(350, 140), true, false)
	check("switching canvases uses hovered canvas brush size", is_equal_approx(cursor.pointer.size.x * 52.0 / 60.0, 21.0))
	second.queue_free()
	check("deleted canvas is ignored immediately", cursor._canvas_at(Vector2(350, 140)) == null)
	cursor._on_mouse_exited()
	check("leaving window releases system mouse", not cursor.pointer.visible and not cursor._owns_mouse and not cursor._mouse_in_window)
	if DisplayServer.get_name() != "headless":
		check("leaving restores actual system cursor", Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)
	cursor._on_mouse_entered()
	cursor._refresh_cursor(inside, true, false)
	check("reentering restores custom cursor", cursor.pointer.visible and cursor._mouse_in_window)
	cursor._refresh_cursor(Vector2(-1, 20), true, false)
	check("outside viewport releases cursor", not cursor.pointer.visible and not cursor._owns_mouse)
	cursor._refresh_cursor(inside, true, false)
	root.focus_exited.emit()
	check("losing focus releases cursor immediately", not cursor.pointer.visible and not cursor._owns_mouse)
	paused = true
	cursor.set_process(true)
	check("cursor remains processable during pause", cursor.can_process())
	cursor.set_process(false)
	paused = false
	var button := Button.new()
	button.position = Vector2(480, 200)
	button.size = Vector2(100, 50)
	root.add_child(button)
	var pressed := [false]
	button.pressed.connect(func(): pressed[0] = true)
	await process_frame
	cursor._refresh_cursor(Vector2(510, 220), true, true)
	_click(Vector2(510, 220))
	check("software cursor does not block button clicks", pressed[0])
	button.queue_free()
	level.queue_free()
	await process_frame
	check("unloading gameplay disables cursor", not cursor._has_gameplay())
	cursor._refresh_cursor(inside, false, false)
	check("returning to menu releases ownership", not cursor.pointer.visible and not cursor._owns_mouse)
	var temporary := (load("res://ui/cursor/cursor.tscn") as PackedScene).instantiate()
	root.add_child(temporary)
	temporary.set_process(false)
	temporary._refresh_cursor(inside, true, false)
	check("temporary overlay acquires mouse before removal", temporary._owns_mouse)
	temporary.free()
	check("freeing overlay restores cursor ownership", not cursor._owns_mouse)
	if DisplayServer.get_name() != "headless":
		check("removing overlay restores actual system cursor", Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)
	print("[GameCursor] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
