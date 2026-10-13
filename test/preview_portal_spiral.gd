extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(400, 400)
	var background := ColorRect.new()
	background.size = Vector2(400, 400)
	background.color = Color(0.94, 0.92, 0.87)
	root.add_child(background)
	var portal: Node2D = load("res://actor/portal/src/map_portal.gd").new()
	portal.position = Vector2(200, 200)
	portal.scale = Vector2(2, 2)
	root.add_child(portal)
	portal.set_physics_process(false)
	portal.set_process(false)
	DirAccess.make_dir_recursive_absolute("D:/Ink/output")
	for i in 2:
		portal._spiral_material.set_shader_parameter("phase", float(i) * 0.5)
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("D:/Ink/output/portal_spiral_%d.png" % i)
	quit()
