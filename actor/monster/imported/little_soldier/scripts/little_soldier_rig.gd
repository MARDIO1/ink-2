@tool
extends Node2D

@export var solve_ik := true
@export var solve_ik_in_editor := true
@export var show_targets := true:
	set(value):
		show_targets = value
		var targets := get_node_or_null("Targets") as Node2D
		if targets != null:
			targets.visible = value


func _ready() -> void:
	var targets := get_node_or_null("Targets") as Node2D
	if targets != null:
		targets.visible = show_targets


func _process(_delta: float) -> void:
	if not solve_ik:
		return
	if Engine.is_editor_hint() and not solve_ik_in_editor:
		return

	_solve_chain(
		get_node_or_null("Skeleton2D/Root/BodyBone/LeftUpperArm") as Bone2D,
		get_node_or_null("Skeleton2D/Root/BodyBone/LeftUpperArm/LeftLowerArm") as Bone2D,
		get_node_or_null("Skeleton2D/Root/BodyBone/LeftUpperArm/LeftLowerArm/LeftHandTip") as Node2D,
		get_node_or_null("Targets/LeftHandTarget") as Node2D,
		-1.0
	)
	_solve_chain(
		get_node_or_null("Skeleton2D/Root/BodyBone/RightUpperArm") as Bone2D,
		get_node_or_null("Skeleton2D/Root/BodyBone/RightUpperArm/RightLowerArm") as Bone2D,
		get_node_or_null("Skeleton2D/Root/BodyBone/RightUpperArm/RightLowerArm/RightHandTip") as Node2D,
		get_node_or_null("Targets/RightHandTarget") as Node2D,
		1.0
	)
	_solve_chain(
		get_node_or_null("Skeleton2D/Root/LeftThigh") as Bone2D,
		get_node_or_null("Skeleton2D/Root/LeftThigh/LeftShin") as Bone2D,
		get_node_or_null("Skeleton2D/Root/LeftThigh/LeftShin/LeftFootTip") as Node2D,
		get_node_or_null("Targets/LeftFootTarget") as Node2D,
		-1.0
	)
	_solve_chain(
		get_node_or_null("Skeleton2D/Root/RightThigh") as Bone2D,
		get_node_or_null("Skeleton2D/Root/RightThigh/RightShin") as Bone2D,
		get_node_or_null("Skeleton2D/Root/RightThigh/RightShin/RightFootTip") as Node2D,
		get_node_or_null("Targets/RightFootTarget") as Node2D,
		1.0
	)


func _solve_chain(
	upper: Bone2D,
	lower: Bone2D,
	end_bone: Node2D,
	target: Node2D,
	bend_sign: float
) -> void:
	if upper == null or lower == null or end_bone == null or target == null:
		return
	var chain_space := upper.get_parent() as Node2D
	if chain_space == null:
		return

	var target_in_chain_space := chain_space.to_local(target.global_position)
	var target_delta := target_in_chain_space - upper.position
	if target_delta.length_squared() < 0.0001:
		return

	var first_length := maxf(lower.position.length(), 0.001)
	var second_length := maxf(end_bone.position.length(), 0.001)
	var distance := clampf(
		target_delta.length(),
		absf(first_length - second_length) + 0.01,
		first_length + second_length - 0.01
	)
	var base_angle := target_delta.angle()
	var shoulder_cos := clampf(
		(first_length * first_length + distance * distance - second_length * second_length)
		/ (2.0 * first_length * distance),
		-1.0,
		1.0
	)
	var elbow_cos := clampf(
		(first_length * first_length + second_length * second_length - distance * distance)
		/ (2.0 * first_length * second_length),
		-1.0,
		1.0
	)
	upper.rotation = base_angle + bend_sign * acos(shoulder_cos)
	lower.rotation = bend_sign * (acos(elbow_cos) - PI)
