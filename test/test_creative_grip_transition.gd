extends SceneTree

const ROOT_SCENE := preload("res://root/root.tscn")
const MAP_SCENE := preload("res://map/1（终极版）.tscn")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var app := ROOT_SCENE.instantiate()
	root.add_child(app)
	current_scene = app
	app.load_level(MAP_SCENE)
	await process_frame
	await process_frame
	var creative: Node = app.get_node("Level").get_child(0).get_node("Creative")
	creative.auto_save_on_exit = false
	creative.auto_save_edits = false
	creative.set_active(true)
	await process_frame
	await process_frame
	var level: Node = app.get_node("Level").get_child(0)
	creative = level.get_node("Creative")
	creative.auto_save_on_exit = false
	creative.auto_save_edits = false
	creative.set_active(false)
	var hand: Node = level.get_node("Player/Arm/Hand/HandControl")
	var target = _first_nonliving_body(level)
	var point := _first_solid_world_point(target)
	hand._remove_arm()
	hand.body.rotation = 0.0
	hand.body.position = point - hand.FINGERTIP - hand.body.local_com
	hand.body.refresh_com()
	hand.body.update_aabb()
	var tip: Vector2 = hand.body.com_world() + hand.FINGERTIP.rotated(hand.body.rotation)
	var hit = hand.Query.closest_point(tip, hand.GRAB_RADIUS, [hand.body, hand.player_body])
	hand.set_grip(true)
	hand._update_grip(0.0)
	var valid: bool = (bool(hand.enabled) and hand.is_physics_processing()
		and hit.hit and hit.body == target and hand.grabbed_body == target)
	print("[CreativeGripTransition] ", "PASS" if valid else "FAIL")
	hand.set_grip(false)
	hand._release_grab()
	quit(0 if valid else 1)


func _first_nonliving_body(level: Node):
	for body in level.world.bodies:
		if not body.tags.has(&"living") and not body.shapes.is_empty():
			return body
	return null


func _first_solid_world_point(body) -> Vector2:
	if body == null:
		return Vector2.ZERO
	for shape in body.shapes:
		var rect: Rect2i = shape.local_aabb()
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				if shape.get_pixel(x, y) != 0:
					return body.to_world(Vector2(x + 0.5, y + 0.5))
	return body.com_world()
