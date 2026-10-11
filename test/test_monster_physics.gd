extends SceneTree

const MapMonsterScript := preload("res://actor/monster/src/map_monster.gd")
const PixelBody2D := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
const Ragdoll := preload("res://actor/monster/src/monster_ragdoll.gd")


func _initialize() -> void:
	call_deferred("_run")


func _pair_exists(world, first, second) -> bool:
	for index in world.contact_pair_count():
		var info: Dictionary = world.contact_info(index)
		if (info.id_a == first.rapier_id and info.id_b == second.rapier_id) \
		or (info.id_a == second.rapier_id and info.id_b == first.rapier_id):
			return true
	return false


func _wait_for_pair(world, first, second, frame_limit: int) -> bool:
	for _frame in frame_limit:
		await physics_frame
		if _pair_exists(world, first, second):
			return true
	return false


func _wait_for_monster_contact(world, monster, other, frame_limit: int) -> bool:
	for _frame in frame_limit:
		await physics_frame
		if _pair_exists(world, monster.body, other):
			return true
		for part in monster._ragdoll.parts:
			if _pair_exists(world, part.body, other):
				return true
	return false


func _reset_monster(monster, position: Vector2) -> void:
	monster._hit_cooldown = 0.0
	monster._hit_recovery = 0.0
	monster.last_contact_impulse = Vector2.ZERO
	monster.global_position = position
	monster.global_rotation = 0.0
	monster.sync_physics_from_node()


func _check_limb_fit(monster) -> bool:
	var valid := true
	for part in monster._ragdoll.parts:
		var sprite: Sprite2D = part.bone.get_node(str(part.bone.name) + "Art")
		var frame := Transform2D(part.bone.global_rotation, part.bone.global_position)
		var polygon := Ragdoll.sprite_polygon(sprite, frame)
		var shape := Ragdoll.sprite_shape(sprite, frame, monster.material_id)
		valid = valid and polygon.size() >= 4 and polygon.size() <= 12
		var bounds := shape.local_aabb()
		# 必须削掉矩形的透明角落，而不是仅仅缓存一个没有参与碰撞的多边形。
		valid = valid and shape.pixel_count() < int(bounds.size.x * bounds.size.y * 0.97)
		var image := sprite.texture.get_image()
		var transform := frame.affine_inverse() * sprite.global_transform
		var offset := sprite.offset - sprite.texture.get_size() * 0.5
		for y in image.get_height():
			for x in image.get_width():
				if image.get_pixel(x, y).a > 0.1:
					var point := transform * (Vector2(x + 0.5, y + 0.5) + offset)
					valid = valid and shape.get_pixel(floori(point.x), floori(point.y)) != 0
	return valid


func _reset_body(body, position: Vector2, velocity := Vector2.ZERO) -> void:
	body.position = position
	body.rotation = 0.0
	body.linear_velocity = velocity
	body.angular_velocity = 0.0
	body.awake = true
	body.sleep_timer = 0.0
	body.refresh_com()
	body.update_aabb()
	body.compute_swept_aabb(0.0)


func _run() -> void:
	var valid := true
	var monster_kind := MapMonsterScript.Kind.SHIELD_SOLDIER if "--great-shield" in OS.get_cmdline_user_args() else MapMonsterScript.Kind.LITTLE_SOLDIER
	var level := (load("res://map/main.tscn") as PackedScene).instantiate()
	root.add_child(level)
	await process_frame
	await physics_frame

	var creative := level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.set_active(true)
	var monster = creative.place_monster(
		monster_kind, Vector2(0, -40), false, "physics-test"
	)
	await process_frame
	await physics_frame
	var monster_body = monster.body if monster != null else null
	var ground_body = level.get_node("Ground").body
	var editor_freeze_valid: bool = monster_body != null and monster_body.frozen
	valid = valid and monster._ragdoll.parts.size() == 4 and monster._ragdoll.joints.size() == 4
	for part in monster._ragdoll.parts:
		editor_freeze_valid = editor_freeze_valid and part.body.frozen
	var fit_valid := _check_limb_fit(monster)
	valid = valid and fit_valid
	print("[MonsterPhysics] simplified polygon/opaque pixel coverage: ", fit_valid)
	# 直接走渲染器入口，确保没有对应节点的四肢也遵守 invisible 标志。
	var hidden_valid := true
	for part in monster._ragdoll.parts:
		level.renderer.sync(part.body)
		hidden_valid = hidden_valid and not level.renderer._nodes.has(part.body.id)
		hidden_valid = hidden_valid and not level.renderer._tiles.has(part.body.id)
	valid = valid and hidden_valid
	print("[MonsterPhysics] invisible limb rendering: ", hidden_valid)
	var arms_down := true
	for part in monster._ragdoll.parts:
		if str(part.bone.name).ends_with("Arm"):
			var direction: Vector2 = Vector2(part.control.rest_direction).rotated(part.bone.rotation).normalized()
			arms_down = arms_down and direction.dot(Vector2.DOWN) > 0.96
	valid = valid and arms_down
	print("[MonsterPhysics] initial arms naturally down: ", arms_down)
	var sole_heights: Array[float] = []
	for part in monster._ragdoll.parts:
		if str(part.bone.name).ends_with("Leg"):
			var sprite: Sprite2D = part.bone.get_node(str(part.bone.name) + "Art")
			var bottom := -INF
			for point in Ragdoll.sprite_polygon(sprite, monster.global_transform):
				bottom = maxf(bottom, point.y)
			sole_heights.append(bottom)
	var soles_valid: bool = absf(sole_heights[0] - sole_heights[1]) < 0.01
	valid = valid and soles_valid
	print("[MonsterPhysics] level soles: ", soles_valid,
		"; raised lower foot (source px): ", monster._ragdoll.foot_height_correction)
	creative.set_active(false)
	editor_freeze_valid = editor_freeze_valid and not monster_body.frozen
	for part in monster._ragdoll.parts:
		editor_freeze_valid = editor_freeze_valid and not part.body.frozen
	valid = valid and editor_freeze_valid
	print("[MonsterPhysics] editor freeze/play thaw: ", editor_freeze_valid)
	valid = valid and monster_body != null
	valid = valid and level.world.bodies.has(monster_body)
	valid = valid and monster_body.tags.has("living") and monster_body.tags.has("map_monster")
	valid = valid and monster_body.collision_layer == 1 and monster_body.collision_mask == 0xFFFFFFFF
	valid = valid and not monster_body.internal_render and not monster_body.shapes.is_empty()

	# 缩放重建不能留下旧 PBody/PixelShape 引用环。
	for factor in [1.1, 1.0]:
		var previous_body_ref: WeakRef = weakref(monster_body)
		monster.scale = Vector2.ONE * factor
		monster.sync_physics_from_node(true)
		monster_body = monster.body
		var scaled_fit := _check_limb_fit(monster)
		valid = valid and scaled_fit
		print("[MonsterPhysics] scaled outline fit: ", scaled_fit)
		# 最近一步的接触缓存会短暂持有旧体，等待下一步更新后再验证释放。
		await physics_frame
		await process_frame
		valid = valid and previous_body_ref.get_ref() == null
		print("[MonsterPhysics] scale release: ", previous_body_ref.get_ref() == null)

	# 动态小兵应在真实 Rapier 世界中落到静态地图，而不是穿过地面。
	var touched_ground := await _wait_for_monster_contact(level.world, monster, ground_body, 240)
	valid = valid and touched_ground
	valid = valid and monster_body.position.y > -40.0
	print("[MonsterPhysics] ground contact: ", touched_ground)
	# 每个部位都有独立碰撞体，骨骼严格跟随求解结果而非额外视觉扭转。
	var visual := monster.get_node("Visual") as Node2D
	var animation := visual.get_node("AnimationPlayer") as AnimationPlayer
	monster._process(0.0)
	var feet_aligned := true
	for part in monster._ragdoll.parts:
		feet_aligned = feet_aligned and part.bone.global_position.distance_to(level.to_global(part.body.position)) < 0.01
		feet_aligned = feet_aligned and absf(wrapf(part.bone.global_rotation - part.body.rotation, -PI, PI)) < 0.001
	valid = valid and feet_aligned
	print("[MonsterPhysics] visible feet/collider aligned: ", feet_aligned)

	# 在真实重力和平地接触下持续站稳，不能仅仅把美术旋转设为零。
	var player := level.get_node("Player")
	player.get_node("PlayerInput").process_mode = Node.PROCESS_MODE_DISABLED
	var player_body = player.body
	_reset_body(player_body, Vector2(-1000, -1000))
	_reset_monster(monster, Vector2(0, -40))
	for _frame in 240:
		await physics_frame
	var standing_valid: bool = absf(monster.body.rotation) < 0.04
	standing_valid = standing_valid and await _wait_for_monster_contact(level.world, monster, ground_body, 20)
	valid = valid and standing_valid
	print("[MonsterPhysics] gravity/ground upright: ", standing_valid,
		"; torso angle: ", monster.body.rotation, "; position: ", monster.body.position)

	# 初始整体倾斜，并给手臂离心冲量。受击窗口松开，之后自动恢复。
	monster.global_position = Vector2(0, -40)
	monster.global_rotation = 0.65
	monster.sync_physics_from_node()
	var arm = monster._ragdoll.parts[0].body
	arm.apply_impulse(Vector2(0, -arm.mass * 120.0), arm.com_world() + Vector2(-20, 0))
	monster.receive_contact_impact(arm.com_world(), Vector2(0, -arm.mass * 120.0))
	arm = null
	monster._ragdoll.update_balance(1.0 / 60.0, false, true, false)
	var relaxed_valid: bool = is_zero_approx(monster.body.control_torque)
	for joint in monster._ragdoll.joints:
		relaxed_valid = relaxed_valid and joint.motor_mode == 0
	for _frame in 300:
		await physics_frame
	var recovered_valid: bool = absf(monster.body.rotation) < 0.15
	for index in monster._ragdoll.parts.size():
		if str(monster._ragdoll.parts[index].bone.name).ends_with("Leg"):
			print("[MonsterPhysics] recovered leg angle: ", monster._ragdoll.joints[index].movement())
			recovered_valid = recovered_valid and absf(monster._ragdoll.joints[index].movement()) < 0.15
	valid = valid and relaxed_valid and recovered_valid
	print("[MonsterPhysics] hit relaxation/physical upright recovery: ", relaxed_valid and recovered_valid,
		"; torso angle: ", monster.body.rotation, "; relaxed: ", relaxed_valid)

	# 玩家主体应能和小兵形成求解接触。
	level.world.gravity = Vector2.ZERO
	# 此处只测玩家主体的碰撞；远处的手臂关节和鼠标马达不能干扰探测轨迹。
	player.get_node("Arm/Hand").set_physics_process(false)
	for joint in level.world.joints_of(player_body).duplicate():
		level.world.remove_joint(joint)
	player_body.control_force = Vector2.ZERO
	player_body.control_torque = 0.0
	# 玩家靠近时停止 walk，远离后恢复，并带有距离滞回。
	monster._hit_recovery = 0.0
	_reset_body(player_body, monster_body.position + Vector2(100, -100))
	monster._update_walk_state()
	var proximity_valid: bool = not monster.walking and not animation.is_playing()
	_reset_body(player_body, monster_body.position + Vector2(1000, -100))
	monster._update_walk_state()
	proximity_valid = proximity_valid and monster.walking and animation.is_playing()
	valid = valid and proximity_valid
	print("[MonsterPhysics] near stop/far resume: ", proximity_valid)
	_reset_monster(monster, Vector2(0, 220))
	monster.last_contact_impulse = Vector2.ZERO
	monster._hit_cooldown = 0.0
	_reset_body(player_body, Vector2(-150, 80), Vector2(420, 0))
	var touched_player := await _wait_for_monster_contact(level.world, monster, player_body, 120)
	valid = valid and touched_player
	print("[MonsterPhysics] player contact: ", touched_player)

	# 普通 PixelBody 与固化/画出的动态道具走同一物理路径，应能撞到并推动小兵。
	_reset_monster(monster, Vector2(0, 220))
	_reset_body(player_body, Vector2(-1000, -1000))
	var prop := PixelBody2D.new()
	prop.name = "MonsterPhysicsProbe"
	prop.position = Vector2(-150, 80)
	prop.rect_size = Vector2i(32, 32)
	prop.internal_render = false
	level.add_child(prop)
	var prop_body = prop.body
	_reset_body(prop_body, prop.position, Vector2(520, 0))
	var monster_start_x: float = monster_body.position.x
	var touched_prop := await _wait_for_monster_contact(level.world, monster, prop_body, 120)
	for _frame in 20:
		await physics_frame
	valid = valid and touched_prop
	valid = valid and monster_body.position.x > monster_start_x + 0.5
	var real_hit_valid: bool = monster.last_contact_impulse.length() > 0.0
	real_hit_valid = real_hit_valid and monster.last_contact_impulse.x > 0.0
	var bone_response := false
	for joint in monster._ragdoll.joints:
		bone_response = bone_response or absf(joint.movement()) > 0.001
	valid = valid and real_hit_valid and bone_response
	print("[MonsterPhysics] real contact impulse/knockback/bone response: ",
		real_hit_valid and bone_response, "; contact: ", touched_prop,
		"; impulse: ", monster.last_contact_impulse, "; bones: ", bone_response)

	# 800px/s 撞 8px 薄墙，逐部位验证没有穿到墙后且关节没有拉散。
	prop.queue_free()
	var wall := PixelBody2D.new()
	wall.position = Vector2(250, -200)
	wall.rect_size = Vector2i(8, 700)
	wall.is_static = true
	wall.internal_render = false
	level.add_child(wall)
	var wall_body = wall.body
	_reset_monster(monster, Vector2(0, 220))
	monster.body.linear_velocity = Vector2(800, 0)
	for part in monster._ragdoll.parts:
		part.body.linear_velocity = Vector2(800, 0)
	var wall_contact := await _wait_for_monster_contact(level.world, monster, wall_body, 120)
	var wall_valid := wall_contact
	for _frame in 45:
		await physics_frame
		wall_valid = wall_valid and monster.body.com_world().x < 254.0
		wall_valid = wall_valid and monster.body.aabb.end.x <= wall_body.aabb.position.x + 2.0
		for part in monster._ragdoll.parts:
			wall_valid = wall_valid and part.body.com_world().x < 254.0
			wall_valid = wall_valid and part.body.aabb.end.x <= wall_body.aabb.position.x + 2.0
		for joint in monster._ragdoll.joints:
			wall_valid = wall_valid and joint.anchor_error_len() < 3.0
	valid = valid and wall_valid
	print("[MonsterPhysics] articulated CCD/thin wall/joint anchors: ", wall_valid)
	if not wall_valid:
		print("[MonsterPhysics] wall contact: ", wall_contact, "; torso bounds: ", monster.body.aabb, "; wall: ", wall_body.aabb)
		for index in monster._ragdoll.parts.size():
			print("[MonsterPhysics] ", monster._ragdoll.parts[index].bone.name, " bounds: ", monster._ragdoll.parts[index].body.aabb, "; anchor error: ", monster._ragdoll.joints[index].anchor_error_len())

	var removed_body_ref: WeakRef = weakref(monster_body)
	monster_body = null
	level.queue_free()
	await process_frame
	valid = valid and removed_body_ref.get_ref() == null
	print("[MonsterPhysics] deletion release: ", removed_body_ref.get_ref() == null)
	if not valid:
		printerr("[MonsterPhysics] registration, ground, player or prop collision: FAIL")
		quit(1)
		return
	print("[MonsterPhysics] registration, ground, player and prop collision: PASS")
	quit()
