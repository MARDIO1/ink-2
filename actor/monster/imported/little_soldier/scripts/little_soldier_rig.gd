@tool
extends CanvasGroup

const ART_FRONT_TO_BACK: Array[NodePath] = [
	NodePath("Skeleton2D/Root/BodyBone/RightArm/RightArmArt"),
	NodePath("Skeleton2D/Root/BodyBone/BodyArt"),
	NodePath("Skeleton2D/Root/BodyBone/LeftArm/LeftArmArt"),
	NodePath("Skeleton2D/Root/RightLeg/RightLegArt"),
	NodePath("Skeleton2D/Root/LeftLeg/LeftLegArt"),
]

const MASK_FRONT_TO_BACK: Array[NodePath] = [
	NodePath("Skeleton2D/Root/BodyBone/RightArm/RightArmOcclusionMask"),
	NodePath("Skeleton2D/Root/BodyBone/BodyOcclusionMask"),
	NodePath("Skeleton2D/Root/BodyBone/LeftArm/LeftArmOcclusionMask"),
	NodePath("Skeleton2D/Root/RightLeg/RightLegOcclusionMask"),
	NodePath("Skeleton2D/Root/LeftLeg/LeftLegOcclusionMask"),
]

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

const LIMB_CONTROLS := [
	{
		"bone": NodePath("Skeleton2D/Root/BodyBone/LeftArm"),
		"target": NodePath("Targets/LeftHandTarget"),
		"rest_direction": Vector2(-60.8, 124.8),
	},
	{
		"bone": NodePath("Skeleton2D/Root/BodyBone/RightArm"),
		"target": NodePath("Targets/RightHandTarget"),
		"rest_direction": Vector2(67.2, 134.4),
	},
	{
		"bone": NodePath("Skeleton2D/Root/LeftLeg"),
		"target": NodePath("Targets/LeftFootTarget"),
		"rest_direction": Vector2(-41.6, 118.4),
	},
	{
		"bone": NodePath("Skeleton2D/Root/RightLeg"),
		"target": NodePath("Targets/RightFootTarget"),
		"rest_direction": Vector2(38.4, 124.8),
	},
]

@export var solve_ik := true
@export var solve_ik_in_editor := true
@export_group("Hand-drawn Wobble")
@export var hand_drawn_wobble := true
@export_range(2.0, 5.0, 0.05) var wobble_fps := 3.33
@export_range(0.0, 1.0, 0.05) var wobble_strength := 0.85
@export_range(4.0, 24.0, 0.5) var wobble_smoothing := 12.0
@export var preview_wobble_in_editor := false
@export var show_targets := true:
	set(value):
		show_targets = value
		var targets := get_node_or_null("Targets") as Node2D
		if targets != null:
			targets.visible = value

var _wobble_elapsed := 0.0
var _body_art_rest_position := Vector2.ZERO
var _body_art_rest_rotation := 0.0
var _body_art_rest_scale := Vector2.ONE


func _ready() -> void:
	var body_art := get_node_or_null("Skeleton2D/Root/BodyBone/BodyArt") as Sprite2D
	if body_art != null:
		_body_art_rest_position = body_art.position
		_body_art_rest_rotation = body_art.rotation
		_body_art_rest_scale = body_art.scale
	var targets := get_node_or_null("Targets") as Node2D
	if targets != null:
		targets.visible = show_targets
	_update_occlusion_materials()


func _process(_delta: float) -> void:
	if solve_ik and (not Engine.is_editor_hint() or solve_ik_in_editor):
		_update_limb_rotations()
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


func _update_limb_rotations() -> void:
	for control in LIMB_CONTROLS:
		var bone := get_node_or_null(control["bone"]) as Bone2D
		var target := get_node_or_null(control["target"]) as Node2D
		if bone == null or target == null:
			continue
		var parent := bone.get_parent() as Node2D
		if parent == null:
			continue
		var direction := parent.to_local(target.global_position) - bone.position
		if direction.length_squared() <= 0.0001:
			continue
		var rest_direction: Vector2 = control["rest_direction"]
		bone.rotation = direction.angle() - rest_direction.angle()


func _update_occlusion_materials() -> void:
	for art_index in range(1, ART_FRONT_TO_BACK.size()):
		var art := get_node_or_null(ART_FRONT_TO_BACK[art_index]) as Sprite2D
		if art == null or not art.material is ShaderMaterial:
			continue
		var material := art.material as ShaderMaterial
		material.set_shader_parameter("mask_count", art_index)
		for mask_index in art_index:
			var mask := get_node_or_null(MASK_FRONT_TO_BACK[mask_index]) as Sprite2D
			if mask == null:
				continue
			var inverse := mask.global_transform.affine_inverse()
			material.set_shader_parameter("mask_%d" % mask_index, mask.texture)
			material.set_shader_parameter("mask_%d_inv_x" % mask_index, inverse.x)
			material.set_shader_parameter("mask_%d_inv_y" % mask_index, inverse.y)
			material.set_shader_parameter("mask_%d_inv_origin" % mask_index, inverse.origin)
