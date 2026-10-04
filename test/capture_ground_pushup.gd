extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene: Node = load("res://map/asset/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	var control: Node = scene.get_node("Player/Hand/HandControl")
	control._remove_arm()
	# 使用正常世界步进、地面查询抓取及重力，不手工创建抓取 Joint。
	_place(control.player_body, Vector2(0, 215))
	_place(control.body, Vector2(0, 231))
	control.set_target_world(Vector2(0, 300))
	var on_box := "box" in OS.get_cmdline_user_args()
	if on_box:
		_place(control.player_body, Vector2(0, 180))
		_place(scene.get_node("Box").body, Vector2(0, 215))
		_place(control.body, Vector2(0, 199))
		control.set_target_world(Vector2(0, 330))
	control.set_grip(true)
	for frame in 240:
		await physics_frame
	# 验收截图把支点和身体都纳入画面，游戏相机不改。
	var camera: Camera2D = scene.get_node("Camera2D")
	camera.set_physics_process(false)
	camera.global_position = Vector2(30, 160)
	camera.zoom = Vector2(2, 2)
	camera.force_update_scroll()
	await process_frame
	await RenderingServer.frame_post_draw
	var file_name := "box_pushup" if on_box else "ground_pushup"
	root.get_texture().get_image().save_png("res://test/%s.png" % file_name)
	quit()


func _place(body, center: Vector2) -> void:
	body.rotation = 0.0
	body.position = center - body.local_com
	body.linear_velocity = Vector2.ZERO
	body.angular_velocity = 0.0
	body.clear_forces()
	body.awake = true
	body.refresh_com()
	body.update_aabb()
