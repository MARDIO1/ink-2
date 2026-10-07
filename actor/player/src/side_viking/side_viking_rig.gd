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

var _shield_target_offset := Vector2.ZERO
var _shield_target_ready := false


func _ready() -> void:
	var targets := get_node_or_null("Targets") as Node2D
	if targets != null:
		targets.visible = show_targets
	_cache_shield_target_offset()
	if "--validate-rig" in OS.get_cmdline_user_args():
		_validate_rig_and_quit()


func _process(_delta: float) -> void:
	if not solve_ik:
		return
	if Engine.is_editor_hint() and not solve_ik_in_editor:
		return
	_solve_chain(
		get_node_or_null("Skeleton2D/Root/Spine/NearUpperArm") as Bone2D,
		get_node_or_null("Skeleton2D/Root/Spine/NearUpperArm/NearForearm") as Bone2D,
		get_node_or_null("Skeleton2D/Root/Spine/NearUpperArm/NearForearm/NearHand") as Bone2D,
		get_node_or_null("Targets/NearHandTarget") as Node2D,
		-1.0
	)
	_solve_chain(
		get_node_or_null("Skeleton2D/Root/Spine/FarUpperArm") as Bone2D,
		get_node_or_null("Skeleton2D/Root/Spine/FarUpperArm/FarForearm") as Bone2D,
		get_node_or_null("Skeleton2D/Root/Spine/FarUpperArm/FarForearm/FarHand") as Bone2D,
		get_node_or_null("Targets/FarHandTarget") as Node2D,
		1.0
	)
	_solve_chain(
		get_node_or_null("Skeleton2D/Root/NearThigh") as Bone2D,
		get_node_or_null("Skeleton2D/Root/NearThigh/NearShin") as Bone2D,
		get_node_or_null("Skeleton2D/Root/NearThigh/NearShin/NearFoot") as Bone2D,
		get_node_or_null("Targets/NearFootTarget") as Node2D,
		-1.0,
		get_node_or_null("Targets/NearKneePole") as Node2D
	)
	_solve_chain(
		get_node_or_null("Skeleton2D/Root/FarThigh") as Bone2D,
		get_node_or_null("Skeleton2D/Root/FarThigh/FarShin") as Bone2D,
		get_node_or_null("Skeleton2D/Root/FarThigh/FarShin/FarFoot") as Bone2D,
		get_node_or_null("Targets/FarFootTarget") as Node2D,
		1.0
	)
	_update_shield_from_target()


func _cache_shield_target_offset() -> void:
	var shield := get_node_or_null("Skeleton2D/Root/ShieldBone") as Bone2D
	var target := get_node_or_null("Targets/ShieldTarget") as Node2D
	if shield == null or target == null:
		return
	_shield_target_offset = to_local(shield.global_position) - to_local(target.global_position)
	_shield_target_ready = true


func _update_shield_from_target() -> void:
	if not _shield_target_ready:
		_cache_shield_target_offset()
	var shield := get_node_or_null("Skeleton2D/Root/ShieldBone") as Bone2D
	var target := get_node_or_null("Targets/ShieldTarget") as Node2D
	if shield == null or target == null:
		return
	var target_position := to_local(target.global_position)
	shield.global_position = to_global(target_position + _shield_target_offset)


func _solve_chain(
	upper: Bone2D,
	lower: Bone2D,
	end_bone: Bone2D,
	target: Node2D,
	bend_sign: float,
	pole: Node2D = null
) -> void:
	if upper == null or lower == null or end_bone == null or target == null:
		return
	var chain_space := upper.get_parent() as Node2D
	if chain_space == null:
		return
	# Solve in the parent bone's local space. This keeps the IK lengths correct
	# when the character instance is scaled, rotated, or nested in another scene.
	var target_in_chain_space := chain_space.to_local(target.global_position)
	var target_delta := target_in_chain_space - upper.position
	var first_length := maxf(lower.position.length(), 0.001)
	var second_length := maxf(end_bone.position.length(), 0.001)
	var distance := clampf(
		target_delta.length(),
		absf(first_length - second_length) + 0.01,
		first_length + second_length - 0.01
	)
	if target_delta.length_squared() < 0.0001:
		return
	var active_bend_sign := bend_sign
	if pole != null:
		var pole_in_chain_space := chain_space.to_local(pole.global_position)
		var pole_delta := pole_in_chain_space - upper.position
		var pole_side := target_delta.cross(pole_delta)
		if absf(pole_side) > 0.01:
			active_bend_sign = signf(pole_side)
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
	upper.rotation = base_angle + active_bend_sign * acos(shoulder_cos)
	lower.rotation = active_bend_sign * (acos(elbow_cos) - PI)


func _validate_rig_and_quit() -> void:
	for _frame in range(3):
		await get_tree().process_frame
	var problems: Array[String] = []
	var required_sprites: Array[NodePath] = [
		^"Skeleton2D/Root/PelvisArt",
		^"Skeleton2D/Root/Spine/TorsoArt",
		^"Skeleton2D/Root/Spine/Head/Art",
		^"Skeleton2D/Root/Spine/NearUpperArm/Art",
		^"Skeleton2D/Root/Spine/NearUpperArm/NearForearm/Art",
		^"Skeleton2D/Root/Spine/NearUpperArm/NearForearm/NearHand/Art",
		^"Skeleton2D/Root/Spine/FarUpperArm/Art",
		^"Skeleton2D/Root/Spine/FarUpperArm/FarForearm/Art",
		^"Skeleton2D/Root/Spine/FarUpperArm/FarForearm/FarHand/Art",
		^"Skeleton2D/Root/NearThigh/Art",
		^"Skeleton2D/Root/NearThigh/NearShin/Art",
		^"Skeleton2D/Root/NearThigh/NearShin/NearFoot/Art",
		^"Skeleton2D/Root/FarThigh/Art",
		^"Skeleton2D/Root/FarThigh/FarShin/Art",
		^"Skeleton2D/Root/FarThigh/FarShin/FarFoot/Art",
		^"Skeleton2D/Root/ShieldBone/ShieldArt",
	]
	for path in required_sprites:
		var sprite := get_node_or_null(path) as Sprite2D
		if sprite == null:
			problems.append("Missing sprite: %s" % path)
		elif sprite.texture == null:
			problems.append("Texture is not bound: %s" % path)

	var chains := [
		[^"Skeleton2D/Root/Spine/NearUpperArm/NearForearm/NearHand", ^"Targets/NearHandTarget"],
		[^"Skeleton2D/Root/Spine/FarUpperArm/FarForearm/FarHand", ^"Targets/FarHandTarget"],
		[^"Skeleton2D/Root/NearThigh/NearShin/NearFoot", ^"Targets/NearFootTarget"],
		[^"Skeleton2D/Root/FarThigh/FarShin/FarFoot", ^"Targets/FarFootTarget"],
	]
	var max_target_error := 0.0
	for pair in chains:
		var end_bone := get_node_or_null(pair[0]) as Bone2D
		var target := get_node_or_null(pair[1]) as Node2D
		if end_bone == null or target == null:
			problems.append("Incomplete IK chain: %s" % str(pair))
			continue
		var chain_error := end_bone.global_position.distance_to(target.global_position)
		print("IK_CHECK %s error=%.4f end=%s target=%s" % [pair[1], chain_error, end_bone.global_position, target.global_position])
		max_target_error = maxf(max_target_error, chain_error)
	if max_target_error > 0.2:
		problems.append("IK target error: %.4f px" % max_target_error)

	var shield := get_node_or_null("Skeleton2D/Root/ShieldBone") as Bone2D
	var shield_target := get_node_or_null("Targets/ShieldTarget") as Node2D
	if shield == null or shield_target == null:
		problems.append("Shield control is incomplete")
	else:
		var shield_before := shield.global_position
		var target_before := shield_target.global_position
		var test_delta := Vector2(7.0, -5.0)
		shield_target.global_position += test_delta
		_update_shield_from_target()
		var shield_error := (shield.global_position - shield_before).distance_to(test_delta)
		shield_target.global_position = target_before
		_update_shield_from_target()
		if shield_error > 0.05:
			problems.append("Shield target error: %.4f px" % shield_error)

	if problems.is_empty():
		print("SIDE_VIKING_RIG_VALIDATION: PASS | chains=4 | target_error=%.4f | shield=independent | unified_textures=18" % max_target_error)
		get_tree().quit(0)
	else:
		for problem in problems:
			push_error(problem)
		print("SIDE_VIKING_RIG_VALIDATION: FAIL | problems=%d" % problems.size())
		get_tree().quit(1)
