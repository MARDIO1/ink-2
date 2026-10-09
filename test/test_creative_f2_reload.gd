extends SceneTree

const ROOT_SCENE := preload("res://root/root.tscn")
const MAP_SCENE := preload("res://map/asset/map.tscn")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var app := ROOT_SCENE.instantiate()
	root.add_child(app)
	current_scene = app
	await process_frame
	var original_level: Node = app.load_level(MAP_SCENE)
	await process_frame
	await process_frame
	var creative: Node = original_level.get_node("Creative")
	creative.auto_save_on_exit = false
	creative.auto_save_edits = false
	var f2 := InputEventAction.new()
	f2.action = &"creative"
	f2.pressed = true
	creative._input(f2)
	await process_frame
	await process_frame
	var restored_level: Node = app.get_node("Level").get_child(0)
	var restored_creative: Node = restored_level.get_node("Creative")
	var hand: Node = restored_level.get_node("Player/Arm/Hand/HandControl")
	var valid: bool = restored_level != original_level and bool(restored_creative.active)
	var autosave_path := "res://test/.creative_autosave.tmp.tscn"
	var autosave_absolute := ProjectSettings.globalize_path(autosave_path)
	var snapshot_path := "res://test/.creative_autosave.tmp.edit.res"
	var snapshot_absolute := ProjectSettings.globalize_path(snapshot_path)
	if FileAccess.file_exists(autosave_path):
		DirAccess.remove_absolute(autosave_absolute)
	if FileAccess.file_exists(snapshot_path):
		DirAccess.remove_absolute(snapshot_absolute)
	restored_creative.map_path = autosave_path
	restored_creative.auto_save_edits = true
	restored_creative.auto_save_delay = 0.05
	var pixel_world: Node = restored_level
	var map_surface: Node = restored_level.get_node("MapCanvas/CanvasSurface")
	var map_canvas: Node = restored_level.get_node("MapCanvas")
	var before_delete := _nonliving_pixel_count(pixel_world)
	var delete_pixel := _first_nonliving_canvas_pixel(pixel_world, map_surface)
	valid = valid and delete_pixel.x >= 0
	if delete_pixel.x >= 0:
		map_canvas._delete_selection(Rect2i(delete_pixel, Vector2i.ONE))
	var after_delete := _nonliving_pixel_count(pixel_world)
	valid = valid and after_delete < before_delete
	map_surface.write_pixel(Vector2i(20, 20), Color.BLACK)
	map_surface.refresh()
	restored_creative._record_edit({"type": &"autosave_probe"})
	await create_timer(0.12).timeout
	valid = valid and FileAccess.file_exists(autosave_path)
	var snapshot := ResourceLoader.load(snapshot_path, "Image", ResourceLoader.CACHE_MODE_IGNORE) as Image
	valid = valid and snapshot != null and snapshot.get_pixel(20, 20).a > 0.5
	var saved_scene := ResourceLoader.load(
		autosave_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE
	) as PackedScene
	var saved_level: Node = saved_scene.instantiate() if saved_scene != null else null
	if saved_level != null:
		saved_level.auto_step = false
		root.add_child(saved_level)
		await process_frame
		await process_frame
		var saved_surface: Node = saved_level.get_node("MapCanvas/CanvasSurface")
		valid = valid and saved_surface.is_solid(20, 20)
		valid = valid and _nonliving_pixel_count(saved_level) == after_delete
		saved_level.queue_free()
		await process_frame
	else:
		valid = false
	restored_creative.auto_save_on_exit = false
	restored_creative.auto_save_edits = false
	var player: Node = restored_level.get_node("Player")
	player.body.position += Vector2(300.0, 120.0)
	restored_creative.set_active(false)
	valid = valid and bool(hand.enabled)
	valid = valid and int(restored_level.get_node("SmallCanvas/CanvasSurface").tool) == 0
	var spawn: Marker2D = restored_level.get_node_or_null("PlayerSpawn") as Marker2D
	valid = valid and spawn != null and player.body.position.distance_to(spawn.global_position) < 0.01
	var expected_spawn: Vector2 = restored_level.get_node("MapCanvas").to_global(
		Vector2(restored_level.get_node("MapCanvas").canvas_size) * 0.5
	)
	valid = valid and spawn.global_position.distance_to(expected_spawn) < 0.01
	var grab_target = _first_nonliving_body(restored_level)
	valid = valid and grab_target != null
	if grab_target != null:
		var grab_point := _first_solid_world_point(grab_target)
		hand._remove_arm()
		hand.body.rotation = 0.0
		hand.body.position = grab_point - hand.FINGERTIP - hand.body.local_com
		hand.body.refresh_com()
		hand.body.update_aabb()
		hand.set_grip(true)
		hand._update_grip(0.0)
		valid = valid and hand.grabbed_body == grab_target
		hand.set_grip(false)
	hand._release_grab()
	if FileAccess.file_exists(autosave_path):
		DirAccess.remove_absolute(autosave_absolute)
	if FileAccess.file_exists(snapshot_path):
		DirAccess.remove_absolute(snapshot_absolute)
	print("[CreativeF2Reload] ", "PASS" if valid else "FAIL")
	quit(0 if valid else 1)


func _first_nonliving_body(pixel_world: Node):
	for body in pixel_world.world.bodies:
		if not body.tags.has(&"living") and not body.shapes.is_empty():
			return body
	return null


func _first_solid_world_point(body) -> Vector2:
	for shape in body.shapes:
		var rect: Rect2i = shape.local_aabb()
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				if shape.get_pixel(x, y) != 0:
					return body.to_world(Vector2(x + 0.5, y + 0.5))
	return body.com_world()


func _nonliving_pixel_count(pixel_world: Node) -> int:
	var total := 0
	for body in pixel_world.world.bodies:
		if body.tags.has(&"living"):
			continue
		for shape in body.shapes:
			total += shape.pixel_count()
	return total


func _first_nonliving_canvas_pixel(pixel_world: Node, surface: Node) -> Vector2i:
	for body in pixel_world.world.bodies:
		if body.tags.has(&"living"):
			continue
		for shape in body.shapes:
			var rect: Rect2i = shape.local_aabb()
			for y in range(rect.position.y, rect.end.y):
				for x in range(rect.position.x, rect.end.x):
					if shape.get_pixel(x, y) == 0:
						continue
					var world_point: Vector2 = body.to_world(Vector2(x + 0.5, y + 0.5))
					var pixel := Vector2i((surface.to_local(world_point) - Vector2(0.5, 0.5)).round())
					if Rect2i(Vector2i.ZERO, surface.canvas_size).has_point(pixel):
						return pixel
	return Vector2i(-1, -1)
