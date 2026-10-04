extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene: Node = load("res://map/asset/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	var control: Node = scene.get_node("Player/Arm/Hand/HandControl")
	for frame in 120:
		control.set_target_world(control.player_body.com_world() + Vector2(60, -30))
		await physics_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://test/hand_visual.png")
	quit()
