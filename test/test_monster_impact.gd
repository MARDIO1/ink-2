extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var valid := true
	for scene_path in PackedStringArray([
		"res://actor/monster/little_soldier.tscn",
		"res://actor/monster/bomb_side.tscn",
	]):
		var monster := (load(scene_path) as PackedScene).instantiate() as Node2D
		root.add_child(monster)
		await process_frame
		var visual := monster.get_node_or_null("Visual") as Node2D
		var bones := visual.find_children("*", "Bone2D", true, false) if visual != null else []
		var before_position := visual.position if visual != null else Vector2.ZERO
		var before_rotations: Array[float] = []
		for bone in bones:
			before_rotations.append(bone.rotation)
		monster.call("receive_impact", monster.global_position + Vector2(-24, 10), Vector2(1200, -280))
		await process_frame
		await process_frame
		valid = valid and visual != null and visual.position.distance_to(before_position) > 0.001
		var bone_moved := false
		for index in bones.size():
			bone_moved = bone_moved or absf(bones[index].rotation - before_rotations[index]) > 0.0001
		valid = valid and bone_moved
		# 第一阶段只有小兵注册不可碎裂的 PixelBody；旧怪物继续保持纯视觉兼容。
		var has_physics := scene_path.ends_with("little_soldier.tscn")
		valid = valid and (monster.get("body") != null) == has_physics
		if has_physics:
			valid = valid and monster.get("body").tags.has("living")
			valid = valid and not monster.get("body").internal_render
		monster.queue_free()
		await process_frame
	if not valid:
		printerr("[MonsterImpact] skeleton impulse response: FAIL")
		quit(1)
		return
	print("[MonsterImpact] skeleton impulse response without pixel fracture: PASS")
	quit()
