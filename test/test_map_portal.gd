extends SceneTree

const Portal := preload("res://actor/portal/src/map_portal.gd")
const MAIN := preload("res://map/main.tscn")
var failures := 0
var checks := 0

class RouterProbe extends Node:
	var requests: Array[String] = []
	func request_level_change(path: String) -> bool:
		requests.append(path)
		return true

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, value: bool) -> void:
	checks += 1
	if not value:
		failures += 1
	print("[Portal] ", "PASS " if value else "FAIL ", label)

func _run() -> void:
	var level := MAIN.instantiate()
	root.add_child(level)
	await process_frame
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.set_active(true)
	var choices := Portal.LevelList.find_levels()
	_check("target map choices", not choices.is_empty())
	var destination := choices[0] if not choices.is_empty() else ""
	var portal = creative.place_portal(Vector2(500, 0), destination)
	portal.set_physics_process(false)
	_check("default display size 150x150", portal.portal_size == Vector2(150, 150))
	var image := (load(Portal.TEXTURE_PATH) as Texture2D).get_image()
	_check("transparent asset size 150x150", image.get_size() == Vector2i(150, 150) and image.get_pixel(75, 75).a == 0.0)
	var center_mask := Portal._center_mask.get_image()
	_check("spiral mask confined to central hole", center_mask.get_pixel(75, 75).a == 1.0 \
		and center_mask.get_pixel(0, 0).a == 0.0 and center_mask.get_pixel(149, 149).a == 0.0)
	_check("spiral uses shader behind paper", portal._spiral.material.shader == Portal.SPIRAL_SHADER and portal._spiral.show_behind_parent)
	var phase: float = portal._spiral_phase
	portal._process(0.1)
	_check("spiral rotates", portal._spiral_phase > phase and portal._spiral_material.get_shader_parameter("phase") == portal._spiral_phase)
	_check("placement and owner", portal.owner == level and creative._portals().size() == 1)
	_check("UI controls", creative._portal_destination.item_count == choices.size() + 1 \
		and creative._layout_buttons.has(creative.LAYOUT_MODE_PLACE_PORTAL))
	var grid := creative._monster_palette_panel.find_child("LayoutGrid", true, false) as GridContainer
	_check("three category rows without setup/stop buttons", grid.columns == 3 and grid.get_child_count() == 9 \
		and grid.get_child(0).name == "PlaceRespawnButton" and grid.get_child(3).name == "PlacePlayCanvasButton" \
		and grid.get_child(6).name == "PlacePortalButton" and not grid.get_child(8) is OptionButton \
		and not grid.has_node("ConfigurePortalButton") and not grid.has_node("StopLayoutButton"))
	portal._process(0.5)
	_check("editor label shows destination map", portal._editor_label == "通往：" + destination.get_file().get_basename())
	creative.active = false
	portal._process(0.5)
	_check("destination label hidden in play mode", portal._editor_label.is_empty())
	creative.active = true
	_check("control tool picks portal", creative._pick_control_target(portal.global_position) == portal)
	creative._begin_layout_drag(portal, portal.global_position)
	portal.global_position += Vector2(100, 30)
	creative._finish_layout_drag()
	creative.undo_last_edit()
	_check("move undo", portal.global_position.is_equal_approx(Vector2(500, 0)))
	creative.select_control_tool()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = root.get_canvas_transform() * portal.global_position
	creative._handle_layout_mouse_button(press)
	_check("control left click selects portal", creative._layout_drag_target == portal and creative._selected_portal == portal)
	var motion := InputEventMouseMotion.new()
	motion.position = root.get_canvas_transform() * (portal.global_position + Vector2(30, 20))
	creative._handle_layout_mouse_motion(motion)
	press.pressed = false
	creative._handle_layout_mouse_button(press)
	_check("control left drag moves portal", portal.global_position.is_equal_approx(Vector2(530, 20)))
	creative.undo_last_edit()
	creative._open_portal_menu(portal)
	creative._portal_destination.hide()
	creative._portal_destination.index_pressed.emit(0)
	_check("submenu changes existing portal destination", portal.target_map.is_empty())
	creative.undo_last_edit()
	creative.set_portal_destination(portal, "")
	creative.undo_last_edit()
	_check("destination undo", portal.target_map == destination)
	_check("invalid destination rejected", not creative.set_portal_destination(portal, "res://missing.tscn"))
	_check("less than two seconds", not portal.advance_overlap(1.99, true, false))
	_check("continuous two seconds", portal.advance_overlap(0.01, true, false))
	_check("only once per entry", not portal.advance_overlap(3, true, false))
	portal.advance_overlap(0, false, false)
	portal.advance_overlap(1.5, true, false)
	portal.advance_overlap(0, false, false)
	_check("leave resets timer", not portal.advance_overlap(0.6, true, false))
	_check("editor never fires", not portal.advance_overlap(10, true, true) and portal.overlap_time == 0)
	var player = level.get_node("Player")
	var body = player.body
	body.rotation = 0
	body.position += portal.position - body.com_world()
	body.refresh_com()
	body.update_aabb()
	_check("real player body overlap", portal.overlaps_player(player))
	body.position += Vector2(1000, 0)
	body.update_aabb()
	_check("outside hole not overlap", not portal.overlaps_player(player))
	_check("explicit target resolves", portal.resolve_destination() == destination)
	portal.target_map = "res://missing.tscn"
	_check("missing map safe", portal.resolve_destination().is_empty())
	portal.target_map = ""
	var original_map: String = creative.map_path
	creative.map_path = choices[-1] if not choices.is_empty() else ""
	_check("last level no wrap", portal.resolve_destination().is_empty())
	if choices.size() > 1:
		creative.map_path = choices[0]
		_check("default next map", portal.resolve_destination() == choices[1])
	creative.map_path = original_map
	portal.target_map = destination
	var router := RouterProbe.new()
	root.add_child(router)
	router.add_to_group(&"level_router")
	await portal._activate()
	_check("routes to requested map", router.requests == [destination])
	var packed := PackedScene.new()
	_check("save playable scene", creative._pack_as_playable_scene(packed, level) == OK)
	var restored := packed.instantiate()
	var restored_portal = restored.get_node_or_null(NodePath(str(portal.name)))
	_check("save preserves position and destination", restored_portal != null \
		and restored_portal.target_map == destination and restored_portal.position == portal.position)
	restored.free()
	creative.delete_portal(portal)
	_check("delete", creative._portals().is_empty())
	creative.undo_last_edit()
	_check("delete undo", creative._portals().size() == 1 and creative._portals()[0].target_map == destination)
	creative.place_portal(Vector2(800, 0))
	creative.undo_last_edit()
	_check("placement undo", creative._portals().size() == 1)
	grid.get_node("PlacePortalButton").pressed.emit()
	_check("placement opens target submenu first", creative._portal_destination.visible \
		and creative._monster_mode == creative.CONTROL_MODE)
	creative._portal_destination.hide()
	creative._portal_destination.index_pressed.emit(0)
	_check("submenu choice enters placement mode", creative._monster_mode == creative.LAYOUT_MODE_PLACE_PORTAL)
	press.pressed = true
	press.position = root.get_canvas_transform() * Vector2(800, 0)
	creative._handle_layout_mouse_button(press)
	var placed_portal = creative._selected_portal
	_check("single placement switches to control", creative._portals().size() == 2 \
		and creative._monster_mode == creative.CONTROL_MODE)
	press.pressed = false
	creative._handle_layout_mouse_button(press)
	press.pressed = true
	creative._handle_layout_mouse_button(press)
	_check("new portal immediately draggable", creative._layout_drag_target == placed_portal)
	motion.position = root.get_canvas_transform() * Vector2(840, 30)
	creative._handle_layout_mouse_motion(motion)
	press.pressed = false
	creative._handle_layout_mouse_button(press)
	_check("automatic control moves without placing more", creative._portals().size() == 2 \
		and placed_portal.global_position.is_equal_approx(Vector2(840, 30)))
	creative.undo_last_edit()
	creative.undo_last_edit()
	_check("single placement and drag undo", creative._portals().size() == 1)
	var remaining_portal = creative._portals()[0]
	var right_click := InputEventMouseButton.new()
	right_click.button_index = MOUSE_BUTTON_RIGHT
	right_click.pressed = true
	right_click.position = root.get_canvas_transform() * Vector2(1800, 0)
	_check("right click empty space does not delete", not creative._handle_layout_mouse_button(right_click) \
		and creative._portals().size() == 1)
	right_click.position = root.get_canvas_transform() * remaining_portal.global_position
	creative._selected_control_target = remaining_portal
	_check("control right click deletes portal", creative._handle_layout_mouse_button(right_click) \
		and creative._portals().is_empty() and creative._selected_control_target == null)
	creative.undo_last_edit()
	_check("right click deletion undo preserves destination", creative._portals().size() == 1 \
		and creative._portals()[0].target_map == destination)
	body = null
	packed = null
	level.queue_free()
	router.queue_free()
	await process_frame
	# 实际应用路由：切关后更换 Level 子场景，并重建游戏 UI，而不是替换整个 Root。
	var app = (load("res://root/root.tscn") as PackedScene).instantiate()
	root.add_child(app)
	await process_frame
	var first_loaded: bool = await app.request_level_change("res://map/main.tscn")
	_check("real async router loads level and UI", first_loaded and app.get_node("Level").get_child_count() == 1 \
		and app.get_node("UI").get_child_count() == 1)
	var old_level: WeakRef = weakref(app.get_node("Level").get_child(0))
	var second_loaded: bool = await app.request_level_change("res://map/main.tscn")
	await process_frame
	_check("second transition replaces old level", second_loaded and old_level.get_ref() == null \
		and app.get_node("Level").get_child_count() == 1)
	app.queue_free()
	await process_frame
	print("[Portal] ", checks, " checks; ", failures, " failures")
	quit(0 if failures == 0 else 1)
