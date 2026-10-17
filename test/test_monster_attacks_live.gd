extends SceneTree
const Attack := preload("res://actor/monster/src/monster_attack.gd")
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for kind in ([2] if "--bomb" in OS.get_cmdline_user_args() else ([3] if "--shield" in OS.get_cmdline_user_args() else [1, 3, 2])):
		var level := (load("res://test/fixtures/maps/base_level.tscn") as PackedScene).instantiate()
		var creative = level.get_node("Creative")
		creative.auto_save_edits = false
		creative.auto_save_on_exit = false
		root.add_child(level)
		level.get_node("SimulationRuntime/PhysicsStep").freeze_view_scale = 32.0
		level.get_node("debugHUD").process_mode = Node.PROCESS_MODE_DISABLED
		await process_frame
		creative.set_active(true)
		for actor in get_nodes_in_group(&"map_monster"):
			actor.attacks_enabled = false
		for body in level.world.bodies:
			if body.is_static:
				body.collision_layer = 0
				body.collision_mask = 0
		var floor_body := PBody.new()
		var floor_shape := Shape.new()
		floor_shape.fill_rect(Rect2i(-500, 0, 1000, 30), 1)
		floor_body.position = Vector2(1000, 0)
		floor_body.make_static()
		level.world.add_body(floor_body, [floor_shape])
		level.realign_body_nodes()
		var monster = creative.place_monster(kind, Vector2(1000, -2), false)
		monster.contact_damage_scale = 0.0
		if monster._ragdoll.shield_body != null:
			monster._ragdoll.shield_body.tags["living"] = true
		creative.set_active(false)
		await process_frame
		var player = level.get_node("Player")
		player.get_node("PlayerInput").process_mode = Node.PROCESS_MODE_DISABLED
		player.get_node("FallDeath").process_mode = Node.PROCESS_MODE_DISABLED
		player.get_node("InkHealth").damage_enabled = true
		player.body.tags["editor_physics_paused"] = true
		player.body.position = monster.body.com_world() + Vector2(-75 if kind != 2 else -300, 0) - player.body.local_com
		if kind == 3:
			player.body.position.x = monster._ragdoll.shield_body.aabb.position.x - player.body.aabb.size.x * 0.5 + 8.0 - player.body.local_com.x
		player.body.refresh_com()
		player.body.update_aabb()
		level.world.freeze(player.body)
		var active_seen := false
		var windup_seen := false
		var thrown := false
		var arm_swing := 0.0
		var captured := false
		for frame in 480:
			await physics_frame
			if not is_instance_valid(monster):
				break
			windup_seen = windup_seen or monster._attack.phase == Attack.Phase.WINDUP
			active_seen = active_seen or monster._attack.phase == Attack.Phase.ACTIVE
			thrown = thrown or not get_nodes_in_group(&"monster_projectile").is_empty()
			if "--preview" in OS.get_cmdline_user_args() and not captured and monster._attack.phase == Attack.Phase.ACTIVE and monster._attack.elapsed > 0.2:
				captured = true
				root.size = Vector2i(960, 540)
				for layer: CanvasLayer in level.find_children("*", "CanvasLayer", true, false):
					layer.visible = false
				var camera := level.get_node("Camera2D") as Camera2D
				camera.set_process(false)
				camera.set_physics_process(false)
				camera.global_position = level.to_global(monster.body.com_world()) + Vector2(-80, 25)
				camera.zoom = Vector2(1.5, 1.5)
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png("res://.codex-tmp/monster_attack_%d.png" % kind)
			for index in monster._ragdoll.parts.size():
				var striking: bool = monster._ragdoll.parts[index] == monster._ragdoll.shield_holder if kind == 3 else str(monster._ragdoll.parts[index].bone.name) == monster._attack.striking_arm
				if striking:
					arm_swing = maxf(arm_swing, absf(monster._ragdoll.joints[index].movement()))
		# 冻结的主角挡在盾面前，盾击只能有微小角位移；仍须真实命中扣血。
		var passed := windup_seen and active_seen and (thrown if kind == 2 else arm_swing > (0.005 if kind == 3 else 0.03))
		if not active_seen:
			print("[AttackLiveState] body=", monster.body.com_world(), " target=", player.body.com_world(),
				" rotation=", monster.body.rotation, " recovery=", monster._ragdoll.recovery_strength,
				" hit=", monster._hit_recovery, " cooldown=", monster._attack.cooldown)
		# 红墨投掷遵守画布的真实距离、遮挡和冲量，不保证固定 1800 伤害。
		if kind != 2:
			passed = passed and player.get_node("InkHealth").ink_of(1) < 20000.0
		print("[MonsterAttackLive] kind=", kind, " windup=", windup_seen, " active=", active_seen,
			" thrown=", thrown, " arm=", arm_swing, " HP=", player.get_node("InkHealth").ink_of(1),
			" result=", "PASS" if passed else "FAIL")
		if not passed:
			failures += 1
		level.world.remove_body(floor_body)
		floor_shape.owner_body = null
		level.realign_body_nodes()
		level.queue_free()
		await process_frame
	quit(1 if failures else 0)
