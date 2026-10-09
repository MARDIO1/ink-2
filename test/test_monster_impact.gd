extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var valid := true
	for scene_path in PackedStringArray([
		"res://actor/monster/shield_side.tscn",
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
		# 小怪仅由 Node2D/骨骼组成，不注册 PixelBody，不会进入墨水碎裂流程。
		valid = valid and monster.get("body") == null
		monster.queue_free()
		await process_frame
	if not valid:
		printerr("[MonsterImpact] skeleton impulse response: FAIL")
		quit(1)
		return
	print("[MonsterImpact] skeleton impulse response without pixel fracture: PASS")
	quit()
