#region 依赖
extends SceneTree

const MAIN := preload("res://map/asset/main.tscn")
const DT := 1.0 / 60.0
#endregion


#region 截图摆放与对照
func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for side_offset in [16.0, 24.0, 28.0]:
		for mode in ["bare", "move", "hand", "no_friction", "no_sleep"]:
			var scene := MAIN.instantiate()
			scene.auto_step = false
			scene.auto_render = false
			scene.set_physics_process(false)
			var control: Node = scene.get_node("Player/Hand/HandControl")
			var movement: Node = scene.get_node("Player/PlayerInput")
			control.set_physics_process(false)
			movement.set_physics_process(false)
			root.add_child(scene)
			await process_frame
			var player = scene.get_node("Player").body
			var box = scene.get_node("Box").body
			var angle := 0.24
			# 玩家一角触地，方块靠在右侧；改变间距覆盖接触和初始穿插。
			var center := Vector2(0, 231 - 12 * sin(angle) - 16 * cos(angle))
			_place(player, center, angle)
			_place(box, center + Vector2(side_offset, -20).rotated(angle), angle)
			_place(control.body, center + Vector2(72, -70), 0.0)
			control.set_target_world(center + Vector2(72, -70))
			control.set_grip(false)
			if mode != "hand":
				control._remove_arm()
				control.arm_joint = null
			if mode == "no_friction":
				for body in scene.world.bodies:
					body.friction = 0.0
				scene.world.solver.global_friction = 0.0
			if mode == "no_sleep":
				scene.world.sleeping_enabled = false
			if DisplayServer.get_name() != "headless" and side_offset == 24.0 and mode == "hand":
				await _capture(scene, [player, box], "tilted_stack_initial")
			for frame in 900:
				if mode in ["move", "hand"]:
					movement._physics_process(DT)
				if mode == "hand":
					control._physics_process(DT)
				scene.world.step(DT)
				if frame in [59, 299, 899]:
					print("[TiltStack] x=", side_offset, " ", mode, " t=", (frame + 1) * DT,
						" player=", player.com_world(), " angle=", rad_to_deg(player.rotation),
						" box=", box.com_world(), " angle=", rad_to_deg(box.rotation),
						" awake=", player.awake, "/", box.awake)
			if DisplayServer.get_name() != "headless" and side_offset == 24.0 and mode == "hand":
				await _capture(scene, [player, box], "tilted_stack")
			control._release_grab()
			control._remove_arm()
			control.arm_joint = null
			scene.queue_free()
			await process_frame
	quit()
#endregion


#region 实际画面
func _capture(scene, bodies: Array, file_name: String) -> void:
	for body in bodies:
		scene.renderer.sync(body)
	scene.get_node("Camera2D")._physics_process(DT)
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://test/%s.png" % file_name)
#endregion


#region 初始化位姿
func _place(body, center: Vector2, angle: float) -> void:
	body.rotation = angle
	body.position = center - body.local_com.rotated(angle)
	body.linear_velocity = Vector2.ZERO
	body.angular_velocity = 0.0
	body.clear_forces()
	body.awake = true
	body.refresh_com()
	body.update_aabb()
#endregion
