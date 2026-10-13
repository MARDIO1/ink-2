extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _shield_above_feet(monster: Node2D) -> bool:
	var sole := -INF
	for part in monster._ragdoll.parts:
		if not str(part.bone.name).ends_with("Leg"):
			continue
		var art: Sprite2D = part.bone.get_node(str(part.bone.name) + "Art")
		var local := Rect2(art.texture.get_image().get_used_rect())
		local.position -= art.texture.get_size() * 0.5
		var visible_bounds: Rect2 = art.global_transform * local
		sole = maxf(sole, visible_bounds.end.y)
	var shield = monster._ragdoll.shield_body
	shield.update_aabb()
	var shield_bottom: float = monster._find_physics_world().to_global(shield.aabb.end).y
	print("[ShieldFacing] shield bottom / sole: ", shield_bottom, " / ", sole)
	return absf(shield_bottom - sole) < 0.1

func _run() -> void:
	var level := (load("res://map/main.tscn") as PackedScene).instantiate()
	root.add_child(level)
	await process_frame
	await physics_frame
	level.world.gravity = Vector2.ZERO
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.set_active(true)
	var monster = creative.place_monster(3, Vector2(0, 100), false)
	await process_frame
	monster.set_physics_process(false)
	monster._editor_physics_paused = false
	var player = level.get_node("Player")
	player.set_physics_process(false)
	player.body.position = Vector2(-220, 0)
	player.body.refresh_com()
	monster._update_walk_state()
	monster._process(0.0)
	var valid: bool = monster._current_facing == -1
	var transforms: Dictionary = {}
	for part in monster._ragdoll.parts:
		var art: Sprite2D = part.bone.get_node(str(part.bone.name) + "Art")
		transforms[part.bone.name] = art.global_transform
	var head: Sprite2D = monster.get_node("Visual/Skeleton2D/Root/BodyBone/BodyArt")
	var head_left := head.global_transform
	var shield_left: Vector2 = monster._ragdoll.shield_body.position
	var palm: Node2D = monster.get_node("Visual/Skeleton2D/Root/BodyBone/LeftArm/LeftArmArt/PalmGrip")
	var inward: Vector2 = monster.get_node("Visual").global_transform.x.normalized() * monster.shield_grip_inset * absf(monster.scale.x)
	valid = valid and absf(level.to_global(shield_left).x - (palm.global_position + inward).x) < 0.01
	valid = valid and is_equal_approx(monster.shield_grip_inset, 8.0)
	valid = valid and is_equal_approx(monster.shield_scale, 0.45 * 1.5)
	valid = valid and is_equal_approx(monster.shield_scale * monster.shield_height_scale, 0.9)
	valid = valid and _shield_above_feet(monster)
	var initial_rotation: float = monster.global_rotation
	var initial_count: int = monster._ragdoll.shield_initial_pixels
	var shield_bounds: Rect2i = monster._ragdoll.shield_body.shapes[0].local_aabb()
	var texture_bounds: Rect2i = monster.get_node("ShieldArt").texture.get_image().get_used_rect()
	var expected_width: float = texture_bounds.size.x * monster.shield_scale * absf(monster.scale.x)
	var expected_height: float = texture_bounds.size.y * monster.shield_scale * monster.shield_height_scale * absf(monster.scale.x)
	valid = valid and absf(shield_bounds.size.x - expected_width) < 2.0
	valid = valid and absf(shield_bounds.size.y - expected_height) < 2.0
	valid = valid and monster._ragdoll.shield_joint.body_a == monster._ragdoll.shield_holder.body
	# 切换前制造实际像素缺口，转向不能恢复完整盾牌。
	var shield_shape = monster._ragdoll.shield_body.shapes[0]
	var bounds: Rect2i = shield_shape.local_aabb()
	for y in range(bounds.position.y, bounds.position.y + 12):
		for x in range(bounds.position.x, bounds.end.x):
			shield_shape.clear_pixel(x, y)
	var damaged_count: int = shield_shape.pixel_count()
	player.body.position = Vector2(220, 0)
	player.body.refresh_com()
	monster._update_walk_state()
	monster._process(0.0)
	valid = valid and monster._current_facing == 1
	print("[ShieldFacing] direction: ", monster._current_facing)
	valid = valid and is_equal_approx(monster.global_rotation, initial_rotation)
	valid = valid and monster.get_node("Visual").scale.y > 0.0
	var mirrored := Transform2D(Vector2(-1, 0), Vector2(0, 1), Vector2.ZERO)
	var origin: Vector2 = monster.global_position
	for part in monster._ragdoll.parts:
		var art: Sprite2D = part.bone.get_node(str(part.bone.name) + "Art")
		var before: Transform2D = transforms[part.bone.name]
		print("[ShieldFacing] ", part.bone.name, " mirror error: ", art.global_transform.x.distance_to(mirrored.basis_xform(before.x)), ", ", art.global_transform.y.distance_to(mirrored.basis_xform(before.y)), ", ", (art.global_position - origin).distance_to(mirrored.basis_xform(before.origin - origin)))
		valid = valid and art.global_transform.x.distance_to(mirrored.basis_xform(before.x)) < 0.01
		valid = valid and art.global_transform.y.distance_to(mirrored.basis_xform(before.y)) < 0.01
		valid = valid and (art.global_position - origin).distance_to(mirrored.basis_xform(before.origin - origin)) < 0.01
		valid = valid and part.bone.global_position.distance_to(level.to_global(part.body.position)) < 0.01
	valid = valid and head.global_transform.y.distance_to(mirrored.basis_xform(head_left.y)) < 0.01
	valid = valid and monster._ragdoll.shield_body.position.x > monster.body.position.x
	inward = monster.get_node("Visual").global_transform.x.normalized() * monster.shield_grip_inset * absf(monster.scale.x)
	valid = valid and absf(level.to_global(monster._ragdoll.shield_body.position).x - (palm.global_position + inward).x) < 0.01
	valid = valid and _shield_above_feet(monster)
	valid = valid and is_equal_approx(shield_left.y, monster._ragdoll.shield_body.position.y)
	valid = valid and monster._ragdoll.shield_body.shapes[0].pixel_count() == damaged_count
	valid = valid and monster._ragdoll.shield_initial_pixels == initial_count
	print("[ShieldFacing] shield: ", shield_left, " -> ", monster._ragdoll.shield_body.position, "; damage: ", damaged_count, " -> ", monster._ragdoll.shield_body.shapes[0].pixel_count(), "; head error: ", head.global_transform.y.distance_to(mirrored.basis_xform(head_left.y)))
	# 同侧重复调用保持原碰撞体；跨越时一次刷新。
	var current = monster.body
	monster._update_walk_state()
	valid = valid and current == monster.body
	player.body.position = Vector2(-220, 0)
	player.body.refresh_com()
	monster._update_walk_state()
	monster._process(0.0)
	valid = valid and monster._current_facing == -1 and current != monster.body
	# 接触回调不能重建原生刚体；下一物理帧起点才刷新。
	current = monster.body
	player.body.position = Vector2(220, 0)
	player.body.refresh_com()
	monster._hit_cooldown = 0.0
	monster.receive_contact_impact(Vector2.ZERO, Vector2(200, 0))
	valid = valid and current == monster.body
	monster._update_walk_state()
	valid = valid and current != monster.body and monster._current_facing == 1
	print("[ShieldFacing] instant horizontal mirror, matching colliders, shield position and damage: ", valid)
	current = null
	level.queue_free()
	await process_frame
	quit(0 if valid else 1)
