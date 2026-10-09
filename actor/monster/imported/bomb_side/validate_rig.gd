extends SceneTree

const EXPECTED_BONES := [
	^"Bomber/Skeleton2D/BodyHead",
	^"Bomber/Skeleton2D/BodyHead/LeftArm",
	^"Bomber/Skeleton2D/BodyHead/RightArm",
	^"Bomber/Skeleton2D/BodyHead/LeftLeg",
	^"Bomber/Skeleton2D/BodyHead/RightLeg",
]

const EXPECTED_ART := [
	^"Bomber/Skeleton2D/BodyHead/Art",
	^"Bomber/Skeleton2D/BodyHead/LeftArm/Art",
	^"Bomber/Skeleton2D/BodyHead/RightArm/Art",
	^"Bomber/Skeleton2D/BodyHead/LeftLeg/Art",
	^"Bomber/Skeleton2D/BodyHead/RightLeg/Art",
]

const EXPECTED_ART_ORIGINS := {
	^"Bomber/Skeleton2D/BodyHead/Art": Vector2(-204, -334),
	^"Bomber/Skeleton2D/BodyHead/LeftArm/Art": Vector2(-133.75, -155),
	^"Bomber/Skeleton2D/BodyHead/RightArm/Art": Vector2(-15, -108.75),
	^"Bomber/Skeleton2D/BodyHead/LeftLeg/Art": Vector2(-120, -10),
	^"Bomber/Skeleton2D/BodyHead/RightLeg/Art": Vector2(-8, -10),
}

const EXPECTED_TEXTURE_SIZES := {
	^"Bomber/Skeleton2D/BodyHead/Art": Vector2i(600, 600),
	^"Bomber/Skeleton2D/BodyHead/LeftArm/Art": Vector2i(108, 200),
	^"Bomber/Skeleton2D/BodyHead/RightArm/Art": Vector2i(100, 180),
	^"Bomber/Skeleton2D/BodyHead/LeftLeg/Art": Vector2i(116, 220),
	^"Bomber/Skeleton2D/BodyHead/RightLeg/Art": Vector2i(124, 204),
}


func _initialize() -> void:
	var packed_scene := load("res://main.tscn") as PackedScene
	if packed_scene == null:
		push_error("无法加载 main.tscn")
		quit(1)
		return
	var scene := packed_scene.instantiate()
	root.add_child(scene)
	call_deferred("_validate", scene)


func _validate(scene: Node) -> void:
	var problems: Array[String] = []
	var character := scene.get_node_or_null(^"Bomber") as Node2D
	if character == null:
		problems.append("缺少角色根节点 Bomber")
	elif character.z_index < 4:
		problems.append("角色渲染层过低，负层级的左手或左腿会被背景遮挡")
	var skeleton := scene.get_node_or_null(^"Bomber/Skeleton2D") as Skeleton2D
	if skeleton == null:
		problems.append("缺少 Skeleton2D")
	else:
		var bones: Array[Bone2D] = []
		_collect_bones(skeleton, bones)
		if bones.size() != 5:
			problems.append("Bone2D 数量应为 5，实际为 %d" % bones.size())

	for path in EXPECTED_BONES:
		if not scene.get_node_or_null(path) is Bone2D:
			problems.append("缺少骨骼：%s" % path)

	for path in EXPECTED_ART:
		var sprite := scene.get_node_or_null(path) as Sprite2D
		if sprite == null or sprite.texture == null:
			problems.append("缺少角色贴图绑定：%s" % path)
		elif Vector2i(sprite.texture.get_size()) != EXPECTED_TEXTURE_SIZES[path]:
			problems.append("贴图尺寸与缩略图拆件不符：%s" % path)

	var player := scene.get_node_or_null(^"Bomber/AnimationPlayer") as AnimationPlayer
	if player == null:
		problems.append("缺少 AnimationPlayer")
	else:
		player.play(&"RESET")
		player.advance(0.0)
		for path in EXPECTED_ART:
			var sprite := scene.get_node(path) as Sprite2D
			var actual_origin := character.to_local(sprite.to_global(Vector2.ZERO))
			if actual_origin.distance_to(EXPECTED_ART_ORIGINS[path]) > 0.02:
				problems.append("素材位置与缩略图不符：%s = %s" % [path, actual_origin])

		for animation_name in [&"idle", &"walk", &"throw"]:
			if not player.has_animation(animation_name):
				problems.append("缺少动画：%s" % animation_name)
			else:
				player.play(animation_name)
				player.advance(0.25)

	if problems.is_empty():
		print("FIVE_PART_RIG_VALIDATION: PASS | bones=5 | art=5 | placement=user_adjusted | animations=3")
		quit(0)
	else:
		for problem in problems:
			push_error(problem)
		print("FIVE_PART_RIG_VALIDATION: FAIL | problems=%d" % problems.size())
		quit(1)


func _collect_bones(node: Node, output: Array[Bone2D]) -> void:
	for child in node.get_children():
		if child is Bone2D:
			output.append(child)
		_collect_bones(child, output)
