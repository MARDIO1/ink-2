extends SceneTree
const Portal := preload("res://actor/portal/src/map_portal.gd")
const PortalScene := preload("res://actor/portal/map_portal.tscn")
var failures := 0
var checks := 0

class BodyProbe extends RefCounted:
	var aabb := Rect2(-10, -10, 20, 20)

class PlayerProbe extends Node2D:
	var body := BodyProbe.new()

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	print("[PortalScene] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1

func _compare_visuals() -> void:
	var viewports: Array[SubViewport] = []
	for legacy in [false, true]:
		var viewport := SubViewport.new()
		viewport.size = Vector2i(180, 180)
		viewport.world_2d = World2D.new()
		viewport.transparent_bg = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		var host := Node2D.new()
		viewport.add_child(host)
		var portal = Portal.new() if legacy else PortalScene.instantiate()
		host.add_child(portal)
		portal.position = Vector2(90, 90)
		portal.set_process(false)
		portal.set_physics_process(false)
		portal._spiral_material.set_shader_parameter("phase", 0.7)
		viewports.append(viewport)
	await process_frame
	await RenderingServer.frame_post_draw
	var new_image := viewports[0].get_texture().get_image()
	var old_image := viewports[1].get_texture().get_image()
	check("scene rendering matches legacy portal pixel for pixel", new_image.get_data() == old_image.get_data())
	for viewport in viewports:
		viewport.queue_free()
	await process_frame

func _run() -> void:
	var level := Node2D.new()
	level.name = "PortalSceneFixture"
	root.add_child(level)
	var first = PortalScene.instantiate()
	var second = PortalScene.instantiate()
	check("scene contains editable paper and spiral nodes", first.has_node("PaperFrame") and first.has_node("SpiralCenter") and first.get_child_count() == 2)
	first.name = "FirstPortal"
	second.name = "SecondPortal"
	level.add_child(first)
	level.add_child(second)
	first.owner = level
	second.owner = level
	first.set_physics_process(false)
	second.set_physics_process(false)
	check("ready reuses scene nodes without duplicates", first.get_child_count() == 2 and first._spiral == first.get_node("SpiralCenter"))
	check("scene frame matches original texture", first._paper_frame.texture.resource_path == Portal.TEXTURE_PATH and first._paper_frame.show_behind_parent)
	check("spiral remains masked behind paper", first._spiral.show_behind_parent and first._spiral.texture.get_image().get_pixel(75, 75).a == 1.0 and first._spiral.texture.get_image().get_pixel(0, 0).a == 0.0)
	check("portal instances have independent materials", first._spiral_material != second._spiral_material)
	first._process(0.3)
	check("animating one portal leaves other phase unchanged", first._spiral_phase > 0 and is_zero_approx(float(second._spiral_material.get_shader_parameter("phase"))))
	first.portal_size = Vector2(300, 180)
	check("inspector size updates paper and spiral immediately", first._paper_frame.scale == Vector2(2, 1.2) and first._spiral.scale == Vector2(2, 1.2))
	# 旧地图中的纯脚本节点保留原行为，不要求批量改写关卡。
	var legacy := Portal.new()
	legacy.name = "LegacyPortal"
	legacy.portal_size = first.portal_size
	level.add_child(legacy)
	legacy.owner = level
	legacy.set_physics_process(false)
	check("legacy portal still creates rotating center", legacy._paper_frame == null and legacy._spiral != null and legacy.get_child_count() == 1)
	check("scene and legacy portals use identical picking region", first.contains_world_point(Vector2(80, 0)) == legacy.contains_world_point(Vector2(80, 0)) and not first.contains_world_point(Vector2(120, 0)))
	var player := PlayerProbe.new()
	level.add_child(player)
	check("scene and legacy detect same player overlap", first.overlaps_player(player) and legacy.overlaps_player(player))
	player.body.aabb.position = Vector2(600, 600)
	check("scene portal rejects player outside hole", not first.overlaps_player(player))
	check("scene still waits two continuous seconds", not first.advance_overlap(1.9, true, false) and first.advance_overlap(0.1, true, false) and not first.advance_overlap(5, true, false))
	first.advance_overlap(0, false, false)
	check("editor still disables portal activation", not first.advance_overlap(10, true, true) and first.overlap_time == 0)
	first.target_map = "res://map/asset/imported/第一关.tscn"
	first.position = Vector2(350, 200)
	var packed := PackedScene.new()
	check("portal instance can be packed with level", packed.pack(level) == OK)
	var restored = packed.instantiate()
	var restored_first = restored.get_node("FirstPortal")
	check("packed level retains reusable scene reference", restored_first.scene_file_path == "res://actor/portal/map_portal.tscn")
	check("packed level preserves custom size target and position", restored_first.portal_size == first.portal_size and restored_first.target_map == first.target_map and restored_first.position == first.position)
	root.add_child(restored)
	for portal in [restored_first, restored.get_node("SecondPortal"), restored.get_node("LegacyPortal")]:
		portal.set_physics_process(false)
	check("restored scene does not duplicate visual children", restored_first.get_child_count() == 2)
	restored.queue_free()
	level.queue_free()
	await process_frame
	# 地图编辑器的新增、删除与撤销都通过相同 PackedScene。
	var map = load("res://map/asset/imported/main.tscn").instantiate()
	map.auto_step = false
	map.get_node("Creative").auto_save_edits = false
	map.get_node("Creative").auto_save_on_exit = false
	root.add_child(map)
	current_scene = map
	await process_frame
	var creative = map.get_node("Creative")
	creative.active = true
	var placed = creative.place_portal(Vector2(10000, -10000), "res://map/asset/imported/第一关.tscn")
	placed.set_physics_process(false)
	check("editor placement instantiates portal scene", placed.scene_file_path == "res://actor/portal/map_portal.tscn" and placed.owner == map and placed.has_node("PaperFrame"))
	placed.portal_size = Vector2(210, 120)
	creative.delete_portal(placed)
	var undone: bool = creative.undo_last_edit()
	var portal = creative._portals()[0] if not creative._portals().is_empty() else null
	check("deletion undo restores scene instance and settings", undone and portal != null and portal.scene_file_path == "res://actor/portal/map_portal.tscn" and portal.portal_size == Vector2(210, 120) and portal.target_map == "res://map/asset/imported/第一关.tscn")
	if portal != null:
		portal.set_physics_process(false)
	check("deletion redo removes portal", creative.redo_last_edit() and creative._portals().is_empty())
	map.queue_free()
	await process_frame
	if OS.get_cmdline_user_args().has("--render-compare"):
		await _compare_visuals()
	print("[PortalScene] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
