extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _visible_bottom(sprite: Sprite2D) -> float:
	var image := sprite.texture.get_image()
	var bottom := -INF
	var offset := sprite.offset - sprite.texture.get_size() * 0.5
	for y in image.get_height():
		for x in image.get_width():
			if image.get_pixel(x, y).a > 0.1:
				for corner in [Vector2(x, y), Vector2(x + 1, y), Vector2(x, y + 1), Vector2(x + 1, y + 1)]:
					bottom = maxf(bottom, (sprite.global_transform * (corner + offset)).y)
	return bottom

func _run() -> void:
	var level := (load("res://test/fixtures/maps/base_level.tscn") as PackedScene).instantiate()
	# 在平地上隔离支撑测试，避免加宽后的盾牌搭在训练装置或箱子上。
	for obstacle in ["Box", "Gym"]:
		var node := level.get_node_or_null(obstacle)
		if node != null:
			node.free()
	level.get_node("Player").position = Vector2(-1000, 0)
	# 扩展平地，重绘盾兵的左腿和加宽盾牌不能悬在原测试平台边缘外。
	level.get_node("Ground").position.x = -800.0
	level.get_node("Ground/Shape").rect_size.x = 1600
	root.add_child(level)
	await process_frame
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.set_active(true)
	var monster = creative.place_monster(3, Vector2(0, -40), false, "shield-feet-test")
	# 此测试只测量支撑几何，避免新的接触扣血机制在落地期间删除被测对象。
	monster.contact_damage_scale = 0.0
	await process_frame
	await physics_frame
	var valid := true
	for part in monster._ragdoll.parts:
		if not str(part.bone.name).ends_with("Leg"):
			continue
		var sprite: Sprite2D = part.bone.get_node(str(part.bone.name) + "Art")
		var visible_bottom := _visible_bottom(sprite)
		part.body.update_aabb()
		var collision_bottom: float = part.body.aabb.end.y
		var gap: float = collision_bottom - visible_bottom
		print("[GreatShieldFeet] ", part.bone.name, ": collision/art gap = ", gap)
		valid = valid and gap >= -0.1 and gap <= 2.0
	creative.set_active(false)
	var grounded := false
	var ground = level.get_node("Ground").body
	for _frame in 480:
		await physics_frame
		# 接触列表只报告活动接触；休眠前最近一秒出现的支撑同样有效。
		if _frame >= 420:
			for index in level.world.contact_pair_count():
				var contact: Dictionary = level.world.contact_info(index)
				for part: Dictionary in monster._ragdoll.parts:
					if str(part.bone.name).ends_with("Leg"):
						grounded = grounded or (contact.id_a == ground.rapier_id and contact.id_b == part.body.rapier_id) \
							or (contact.id_b == ground.rapier_id and contact.id_a == part.body.rapier_id)
	monster._process(0.0)
	var nearest_sole_gap := INF
	for part in monster._ragdoll.parts:
		if str(part.bone.name).ends_with("Leg"):
			var sprite: Sprite2D = part.bone.get_node(str(part.bone.name) + "Art")
			nearest_sole_gap = minf(nearest_sole_gap, ground.aabb.position.y - _visible_bottom(sprite))
			part.body.update_aabb()
			print("[GreatShieldFeet] final ", part.bone.name, " angle=", part.body.rotation,
				" collision_bottom=", part.body.aabb.end.y, " visible_bottom=", _visible_bottom(sprite))
	for index in level.world.contact_pair_count():
		var contact: Dictionary = level.world.contact_info(index)
		for part in monster._ragdoll.parts:
			if not str(part.bone.name).ends_with("Leg"):
				continue
			grounded = grounded or (contact.id_a == ground.rapier_id and contact.id_b == part.body.rapier_id) \
				or (contact.id_b == ground.rapier_id and contact.id_a == part.body.rapier_id)
	print("[GreatShieldFeet] real ground contact = ", grounded, "; nearest sole gap = ", nearest_sole_gap)
	valid = valid and grounded and nearest_sole_gap >= -2.0 and nearest_sole_gap <= 3.0
	level.queue_free()
	await process_frame
	print("[GreatShieldFeet] visible sole/collision alignment: ", "PASS" if valid else "FAIL")
	quit(0 if valid else 1)
