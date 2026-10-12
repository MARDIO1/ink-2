extends SceneTree

const Ragdoll := preload("res://actor/monster/src/monster_ragdoll.gd")
var _valid := true


func _initialize() -> void:
	call_deferred("_run")


func _check(label: String, condition: bool) -> void:
	print("[ShieldCleanup] ", label, ": ", condition)
	_valid = _valid and condition


func _run() -> void:
	# 透明窗口必须同时不存在视觉像素和碰撞像素，镜像后也一样。
	var image := Image.create(8, 6, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	image.fill_rect(Rect2i(0, 0, 2, 6), Color.BLACK)
	image.fill_rect(Rect2i(6, 0, 2, 6), Color.BLACK)
	var texture := ImageTexture.create_from_image(image)
	for mirrored in [false, true]:
		var shape = Ragdoll.texture_shape(texture, 1, 128, 1.0, true, mirrored)
		_check("transparent window, mirrored=%s" % mirrored,
			shape.pixel_count() == 24 and shape.get_pixel(0, 0) == 0)
	var level := (load("res://map/main.tscn") as PackedScene).instantiate()
	root.add_child(level)
	# 本测试同帧反复重建刚体，不用于测量游戏帧耗时。
	level.get_node("debugHUD").process_mode = Node.PROCESS_MODE_DISABLED
	await process_frame
	await physics_frame
	level.world.gravity = Vector2.ZERO
	level.set_physics_process(false)
	var player = level.get_node("Player")
	player.set_physics_process(false)
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.set_active(true)
	var baseline_bodies: int = level.world.bodies.size()
	var baseline_joints: int = level.world.joints.size()
	for iteration in 3:
		var monster = creative.place_monster(3, Vector2(1000, 100), false)
		await process_frame
		monster.set_physics_process(false)
		monster._editor_physics_paused = false
		var body_count: int = level.world.bodies.size()
		var joint_count: int = level.world.joints.size()
		_check("six registered bodies", body_count == baseline_bodies + 6)
		for turn in 8:
			var old_bodies: Array = [monster.body, monster._ragdoll.shield_body]
			for part in monster._ragdoll.parts:
				old_bodies.append(part.body)
			player.body.position = Vector2(1000 + (200 if turn % 2 == 0 else -200), 0)
			player.body.refresh_com()
			monster._update_walk_state()
			for old_body in old_bodies:
				_valid = _valid and not level.world.bodies.has(old_body) and old_body.rapier_id == 0
			_valid = _valid and level.world.bodies.size() == body_count
			_valid = _valid and level.world.joints.size() == joint_count
		_check("turning does not accumulate native bodies/joints", _valid)
		var shield = monster._ragdoll.shield_body
		var shield_shape = shield.shapes[0]
		var bounds: Rect2i = shield_shape.local_aabb()
		var removals: Dictionary = {}
		# 削掉盾牌上沿，走真正的破坏入口，而不是只改贴图。
		for y in range(bounds.position.y, bounds.position.y + 10):
			for x in range(bounds.position.x, bounds.end.x):
				removals[Vector2i(x, y)] = true
		var fracture: Dictionary = level.world.fracture_pixels(shield, {shield_shape: removals})
		monster._sync_shield_visual()
		var art: Sprite2D = monster.get_node("ShieldArt")
		var damaged_image := art.texture.get_image()
		var matches := true
		for shape in shield.shapes:
			var remaining_bounds: Rect2i = shape.local_aabb()
			for y in range(remaining_bounds.position.y, remaining_bounds.end.y):
				for x in range(remaining_bounds.position.x, remaining_bounds.end.x):
					var p := Vector2i(x, y) - Vector2i(art.offset)
					matches = matches and ((damaged_image.get_pixelv(p).a > 0.0) == (shape.get_pixel(x, y) != 0))
		_check("damaged visual matches remaining collision pixels", matches and not art.centered)
		if iteration < 2:
			monster.shield_break_threshold = 0.9
			monster._ragdoll.shield_initial_pixels *= 4
		else:
			# 完全擦除时引擎已移除原刚体；怪物不能保留幽灵引用。
			removals.clear()
			for shape in shield.shapes:
				bounds = shape.local_aabb()
				var mask: Dictionary = {}
				for y in range(bounds.position.y, bounds.end.y):
					for x in range(bounds.position.x, bounds.end.x):
						mask[Vector2i(x, y)] = true
				removals[shape] = mask
			level.world.fracture_pixels(shield, removals)
		monster._ragdoll._check_shield_break(monster)
		monster._sync_shield_visual()
		_check("detached shield is visible debris or removed", monster.shield_broken and not art.visible
			and (shield.internal_render if iteration < 2 else monster._ragdoll.shield_body == null))
		_check("detached shield has no contact filters", monster._ragdoll.self_contact_filters.size() == 6
			and monster._ragdoll.shield_joint == null and not shield.tags.has("monster_receiver"))
		for fragment in fracture.fragments:
			level.world.remove_body(fragment)
		monster.queue_free()
		await process_frame
		level.sync_world_bodies()
		_check("deletion returns body/joint counts to baseline",
			level.world.bodies.size() == baseline_bodies and level.world.joints.size() == baseline_joints)
	level.queue_free()
	await process_frame
	quit(0 if _valid else 1)
