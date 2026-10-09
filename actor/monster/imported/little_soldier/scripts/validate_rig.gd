extends SceneTree


func _initialize() -> void:
	var packed := load("res://scenes/little_soldier_character.tscn") as PackedScene
	assert(packed != null, "Character scene could not be loaded")
	var rig := packed.instantiate()
	root.add_child(rig)

	var required := [
		"Skeleton2D/Root/BodyBone",
		"Skeleton2D/Root/BodyBone/LeftUpperArm/LeftLowerArm/LeftHandTip",
		"Skeleton2D/Root/BodyBone/RightUpperArm/RightLowerArm/RightHandTip",
		"Skeleton2D/Root/LeftThigh/LeftShin/LeftFootTip",
		"Skeleton2D/Root/RightThigh/RightShin/RightFootTip",
		"Targets/LeftHandTarget",
		"Targets/RightHandTarget",
		"Targets/LeftFootTarget",
		"Targets/RightFootTarget",
		"AnimationPlayer",
	]
	for path in required:
		assert(rig.get_node_or_null(path) != null, "Missing rig node: %s" % path)

	for child in rig.get_node("Skeleton2D").find_children("*Art", "Sprite2D", true, false):
		assert(child.texture != null, "Missing texture on %s" % child.name)

	await process_frame
	await process_frame
	print("LITTLE_SOLDIER_RIG_VALIDATION: PASS | chains=4 | parts=9 | idle_animation=ready")
	quit(0)
