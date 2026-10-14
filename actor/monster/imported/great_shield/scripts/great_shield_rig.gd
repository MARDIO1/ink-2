@tool
extends CanvasGroup

# The shared physical rig samples this animation instead of IK targets.
const USE_ANIMATION_TRACKS := true
var solve_ik := false
var LIMB_CONTROLS: Array = []

func _update_limb_rotations() -> void:
	# Keep the imported bone axes; children already compensate for these rotations.
	if not LIMB_CONTROLS.is_empty():
		return
	for part in [&"left_arm", &"right_arm", &"left_leg", &"right_leg"]:
		var bone := get_part_bone(part)
		LIMB_CONTROLS.append({
			"bone": PART_BONES[part],
			"rest_direction": Vector2.DOWN.rotated(-bone.rotation),
		})

const PART_BONES := {
	&"body": NodePath("Skeleton2D/Root/BodyBone"),
	&"left_arm": NodePath("Skeleton2D/Root/BodyBone/LeftArm"),
	&"right_arm": NodePath("Skeleton2D/Root/BodyBone/RightArm"),
	&"left_leg": NodePath("Skeleton2D/Root/LeftLeg"),
	&"right_leg": NodePath("Skeleton2D/Root/RightLeg"),
}

const OCCLUDERS := {
	NodePath("Skeleton2D/Root/BodyBone/BodyArt"): [
		NodePath("Skeleton2D/Root/BodyBone/RightArm/RightArmOcclusionMask"),
	],
	NodePath("Skeleton2D/Root/BodyBone/LeftArm/LeftArmArt"): [
		NodePath("Skeleton2D/Root/BodyBone/RightArm/RightArmOcclusionMask"),
		NodePath("Skeleton2D/Root/BodyBone/BodyOcclusionMask"),
	],
	NodePath("Skeleton2D/Root/LeftLeg/LeftLegArt"): [
		NodePath("Skeleton2D/Root/BodyBone/RightArm/RightArmOcclusionMask"),
		NodePath("Skeleton2D/Root/BodyBone/BodyOcclusionMask"),
		NodePath("Skeleton2D/Root/BodyBone/LeftArm/LeftArmOcclusionMask"),
	],
	NodePath("Skeleton2D/Root/RightLeg/RightLegArt"): [
		NodePath("Skeleton2D/Root/BodyBone/RightArm/RightArmOcclusionMask"),
		NodePath("Skeleton2D/Root/BodyBone/BodyOcclusionMask"),
		NodePath("Skeleton2D/Root/BodyBone/LeftArm/LeftArmOcclusionMask"),
		NodePath("Skeleton2D/Root/LeftLeg/LeftLegOcclusionMask"),
	],
}

const WOBBLE_POSITIONS := [
	Vector2(0.0, 0.0),
	Vector2(0.80, -0.35),
	Vector2(-0.60, 0.30),
	Vector2(0.45, 0.35),
	Vector2(-0.75, -0.20),
	Vector2(0.55, -0.30),
	Vector2(-0.35, 0.20),
]
const WOBBLE_ROTATIONS_DEGREES := [0.0, -0.22, 0.16, -0.12, 0.21, -0.15, 0.10]
const WOBBLE_SCALES := [
	Vector2(1.0, 1.0),
	Vector2(1.004, 0.996),
	Vector2(0.997, 1.003),
	Vector2(1.003, 0.997),
	Vector2(0.996, 1.004),
	Vector2(1.004, 0.997),
	Vector2(0.997, 1.003),
]

@export_group("Hand-drawn Wobble")
@export var hand_drawn_wobble := true
@export_range(2.0, 5.0, 0.05) var wobble_fps := 3.33
@export_range(0.0, 1.0, 0.05) var wobble_strength := 0.85
@export_range(4.0, 24.0, 0.5) var wobble_smoothing := 12.0
@export var preview_wobble_in_editor := false

var _wobble_elapsed := 0.0
var _body_art_rest_position := Vector2.ZERO
var _body_art_rest_rotation := 0.0
var _body_art_rest_scale := Vector2.ONE


func _ready() -> void:
	process_priority = 200
	var body_art := get_node_or_null("Skeleton2D/Root/BodyBone/BodyArt") as Sprite2D
	if body_art != null:
		_body_art_rest_position = body_art.position
		_body_art_rest_rotation = body_art.rotation
		_body_art_rest_scale = body_art.scale
	_update_occlusion_materials()


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint() or preview_wobble_in_editor:
		_update_body_wobble(_delta)
	_update_occlusion_materials()


func _update_body_wobble(delta: float) -> void:
	var body_art := get_node_or_null("Skeleton2D/Root/BodyBone/BodyArt") as Sprite2D
	var body_mask := get_node_or_null("Skeleton2D/Root/BodyBone/BodyOcclusionMask") as Sprite2D
	if body_art == null or body_mask == null:
		return
	_wobble_elapsed += delta
	var pose_index := int(floor(_wobble_elapsed * maxf(wobble_fps, 0.01))) % WOBBLE_POSITIONS.size()
	var active_strength := wobble_strength if hand_drawn_wobble else 0.0
	var desired_position: Vector2 = _body_art_rest_position + WOBBLE_POSITIONS[pose_index] * active_strength
	var desired_rotation: float = _body_art_rest_rotation + deg_to_rad(WOBBLE_ROTATIONS_DEGREES[pose_index]) * active_strength
	var pose_scale: Vector2 = WOBBLE_SCALES[pose_index]
	var desired_scale: Vector2 = Vector2(
		_body_art_rest_scale.x * lerpf(1.0, pose_scale.x, active_strength),
		_body_art_rest_scale.y * lerpf(1.0, pose_scale.y, active_strength)
	)
	var blend: float = 1.0 - exp(-maxf(wobble_smoothing, 0.01) * delta)
	body_art.position = body_art.position.lerp(desired_position, blend)
	body_art.rotation = lerp_angle(body_art.rotation, desired_rotation, blend)
	body_art.scale = body_art.scale.lerp(desired_scale, blend)
	body_mask.position = body_art.position
	body_mask.rotation = body_art.rotation
	body_mask.scale = body_art.scale


func _update_occlusion_materials() -> void:
	# 重绘部件的遮罩与美术同尺寸；使用最终姿势更新，包含物理受击和脚底对齐。
	for part: StringName in PART_BONES:
		var bone := get_part_bone(part)
		if bone == null:
			continue
		var art_name := "BodyArt" if part == &"body" else str(bone.name) + "Art"
		var art := bone.get_node_or_null(art_name) as Sprite2D
		var mask := bone.get_node_or_null(art_name.replace("Art", "OcclusionMask")) as Sprite2D
		if art != null and mask != null:
			mask.transform = art.transform
			mask.centered = art.centered
			mask.offset = art.offset
			mask.flip_h = art.flip_h
			mask.flip_v = art.flip_v
	for art_path: NodePath in OCCLUDERS:
		var art := get_node_or_null(art_path) as Sprite2D
		if art == null or not art.material is ShaderMaterial:
			continue
		var material := art.material as ShaderMaterial
		var masks: Array = OCCLUDERS[art_path]
		material.set_shader_parameter("mask_count", masks.size())
		for index in masks.size():
			var mask := get_node_or_null(masks[index]) as Sprite2D
			if mask == null:
				continue
			var inverse := mask.global_transform.affine_inverse()
			material.set_shader_parameter("mask_%d" % index, mask.texture)
			material.set_shader_parameter("mask_%d_inv_x" % index, inverse.x)
			material.set_shader_parameter("mask_%d_inv_y" % index, inverse.y)
			material.set_shader_parameter("mask_%d_inv_origin" % index, inverse.origin)


func get_part_bone(part: StringName) -> Bone2D:
	var path: NodePath = PART_BONES.get(part, NodePath())
	if path.is_empty():
		return null
	return get_node_or_null(path) as Bone2D


func set_part_rotation(part: StringName, radians: float) -> void:
	var bone := get_part_bone(part)
	if bone != null:
		bone.rotation = radians
