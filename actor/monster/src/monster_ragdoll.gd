extends RefCounted
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const PJoint := preload("res://addons/pixel_destruction/physics/joint.gd")
const HullFit := preload("res://addons/pixel_destruction/core/hull_fit.gd")
static var _outline_cache: Dictionary = {}

## 五个真实刚体共用 PixelWorld；动画只提供软马达目标，绝不直接移动碰撞体。
var parts: Array = []
var joints: Array = []
var self_contact_filters: Array = []
var world_node: Node2D
var visual: Node2D
var torso_body: PBody
var recovery_strength := 1.0
var standing_time := 1.0
var foot_height_correction := 0.0
var uses_animation_tracks := false
var body_rest_rotation := 0.0


static func sprite_shape(sprite: Sprite2D, frame: Transform2D, material: int) -> PixelShape:
	var polygon := sprite_polygon(sprite, frame)
	var shape := PixelShape.new()
	# 引擎仍使用像素形状。把拟合多边形按行光栅化，而不是填满外接矩形。
	if polygon.size() < 3:
		return shape
	var min_y := INF
	var max_y := -INF
	for point in polygon:
		min_y = minf(min_y, point.y)
		max_y = maxf(max_y, point.y)
	for y in range(floori(min_y), ceili(max_y)):
		var left := INF
		var right := -INF
		for index in polygon.size():
			var a := polygon[index]
			var b := polygon[(index + 1) % polygon.size()]
			if maxf(a.y, b.y) < y or minf(a.y, b.y) > y + 1:
				continue
			for height in [clampf(float(y), minf(a.y, b.y), maxf(a.y, b.y)),
					clampf(float(y + 1), minf(a.y, b.y), maxf(a.y, b.y))]:
				var x: float = a.x if is_equal_approx(a.y, b.y) else lerpf(a.x, b.x, (height - a.y) / (b.y - a.y))
				left = minf(left, minf(a.x, b.x) if is_equal_approx(a.y, b.y) else x)
				right = maxf(right, maxf(a.x, b.x) if is_equal_approx(a.y, b.y) else x)
		if left < right:
			shape.fill_rect(Rect2i(floori(left), y, ceili(right) - floori(left), 1), material)
	return shape


## 十二方向支持平面：最多十二边，包住所有不透明像素，不随动画重新拟合。
static func sprite_polygon(sprite: Sprite2D, frame: Transform2D) -> PackedVector2Array:
	var key := sprite.texture.get_instance_id()
	if not _outline_cache.has(key):
		var image := sprite.texture.get_image()
		var points := PackedVector2Array()
		for y in image.get_height():
			var left := -1
			var right := -1
			for x in image.get_width():
				if image.get_pixel(x, y).a > 0.1:
					if left < 0:
						left = x
					right = x
			if left >= 0:
				points.append_array(PackedVector2Array([Vector2(left, y), Vector2(right + 1, y),
					Vector2(right + 1, y + 1), Vector2(left, y + 1)]))
		_outline_cache[key] = HullFit.of_points(points)
	var offset := sprite.offset
	if sprite.centered:
		offset -= sprite.texture.get_size() * 0.5
	var transform := frame.affine_inverse() * sprite.global_transform
	var points := PackedVector2Array()
	for point in _outline_cache[key]:
		points.append(transform * (point + offset))
	if points.size() < 3:
		return points
	var normals := PackedVector2Array()
	var supports := PackedFloat32Array()
	# 拟合方向对齐素材自身的轴线。大盾的腿骨与精灵有相反的预旋转，
	# 按骨骼轴拟合会把鞋底向下扩张；精灵轴确保平直脚底保留精确支撑面。
	var outline_rotation := transform.get_rotation()
	for index in 12:
		var normal := Vector2.from_angle(outline_rotation + TAU * float(index) / 12.0)
		var support := -INF
		for point in points:
			support = maxf(support, point.dot(normal))
		normals.append(normal)
		supports.append(support)
	var corners := PackedVector2Array()
	for index in 12:
		var next := (index + 1) % 12
		var a := normals[index]
		var b := normals[next]
		corners.append(Vector2(supports[index] * b.y - a.y * supports[next],
			a.x * supports[next] - supports[index] * b.x) / a.cross(b))
	return HullFit.of_points(corners)


func setup(monster: Node2D, pixel_world: Node2D, torso: PBody) -> void:
	world_node = pixel_world
	torso_body = torso
	visual = monster.get_node("Visual")
	var animation: AnimationPlayer = visual.get_node("AnimationPlayer")
	animation.play("RESET")
	animation.advance(0.0)
	animation.stop()
	visual._update_limb_rotations()
	uses_animation_tracks = bool(visual.get("USE_ANIMATION_TRACKS")) if "USE_ANIMATION_TRACKS" in visual else false
	body_rest_rotation = visual.get_node("Skeleton2D/Root/BodyBone").rotation
	visual.solve_ik = false
	visual.hand_drawn_wobble = false
	# 双手在身体两侧自然下垂，略向外避开二维素材中重叠的大腿。
	# 此姿势同时作为碰撞体的初始朝向和受击后的关节回正零位。
	for control: Dictionary in visual.LIMB_CONTROLS:
		var bone: Bone2D = visual.get_node(control.bone)
		if str(bone.name).ends_with("Arm") and not uses_animation_tracks:
			var outward := 0.26 if str(bone.name) == "LeftArm" else -0.26
			bone.rotation = Vector2.DOWN.angle() + outward - Vector2(control.rest_direction).angle()
	_align_standing_feet()
	torso.ccd = true
	torso.additional_solver_iterations = 8
	for control: Dictionary in visual.LIMB_CONTROLS:
		var bone: Bone2D = visual.get_node(control.bone)
		var sprite: Sprite2D = bone.get_node(str(bone.name) + "Art")
		var frame := Transform2D(bone.global_rotation, bone.global_position)
		var shape := sprite_shape(sprite, frame, monster.material_id)
		shape.density_scale = monster.physics_density_scale
		var limb := PBody.new()
		limb.position = world_node.to_local(bone.global_position)
		limb.rotation = bone.global_rotation - world_node.global_rotation
		limb.tags = torso.tags.duplicate()
		limb.tags["monster_part"] = str(bone.name)
		limb.internal_render = false
		limb.ccd = true
		limb.additional_solver_iterations = 8
		world_node.world.add_body(limb, [shape], Callable(world_node, "_density_of"), true)
		var joint: PJoint = world_node.world.add_hinge(torso, limb, limb.position)
		joint.set_limits(-1.4, 1.4)
		if str(bone.name).ends_with("Leg"):
			joint.set_limits(-0.55, 0.55)
		joint.set_motor_target(0.0, limb.inertia * 200.0, 100.0, 20.0)
		parts.append({"bone": bone, "body": limb, "control": control,
			"rest_angle": bone.rotation, "rest_position": bone.position})
		joints.append(joint)
	# 二维美术的前后四肢会投影重叠，不能当作同一平面的实体互相顶住。
	# 当前桥接层通过关节 contacts_enabled 排除一对刚体的接触：使用远超
	# 肢体可达距离的松绳，只做逐对过滤，不施加姿势、拉力或额外运动限制。
	# 不改碰撞层，因此不同怪物、玩家、墙面和道具仍与每条四肢碰撞。
	for first in parts.size():
		for second in range(first + 1, parts.size()):
			var a: PBody = parts[first].body
			var b: PBody = parts[second].body
			var exclusion: PJoint = world_node.world.add_rope(a, b, a.position, b.position, 1000000.0)
			exclusion.contacts_enabled = false
			self_contact_filters.append(exclusion)
	world_node.realign_body_nodes()
	animation.play("walk")


## 只抬高较低的一侧美术和遮罩，不改变髋关节位置；重复重建不累积偏移。
func _align_standing_feet() -> void:
	var legs: Array = []
	var common_bottom := INF
	for control: Dictionary in visual.LIMB_CONTROLS:
		var bone: Bone2D = visual.get_node(control.bone)
		if not str(bone.name).ends_with("Leg"):
			continue
		if not uses_animation_tracks:
			bone.rotation = 0.0
		for child in bone.get_children():
			if child is Sprite2D:
				if not child.has_meta("standing_original_position"):
					child.set_meta("standing_original_position", child.position)
				child.position = child.get_meta("standing_original_position")
		var sprite: Sprite2D = bone.get_node(str(bone.name) + "Art")
		var polygon := sprite_polygon(sprite, visual.global_transform)
		var bottom := -INF
		for point in polygon:
			bottom = maxf(bottom, point.y)
		legs.append({"bone": bone, "bottom": bottom})
		common_bottom = minf(common_bottom, bottom)
	foot_height_correction = 0.0
	for leg: Dictionary in legs:
		var adjustment: float = leg.bottom - common_bottom
		foot_height_correction = maxf(foot_height_correction, adjustment)
		var offset: Vector2 = leg.bone.transform.basis_xform_inv(Vector2(0.0, -adjustment))
		for child in leg.bone.get_children():
			if child is Sprite2D:
				child.position += offset


## 在固定物理帧更新姿势控制。力矩经过求解器，不直接覆盖真实刚体角度。
func update_balance(delta: float, paused: bool, recovering: bool, walking: bool) -> void:
	if torso_body == null:
		return
	if paused:
		torso_body.control_torque = 0.0
		return
	standing_time = maxf(0.0, standing_time - delta)
	if recovering:
		recovery_strength = 0.0
	else:
		recovery_strength = minf(1.0, recovery_strength + delta / 0.65)
	var gravity: Vector2 = world_node.world.gravity
	var upright := gravity.angle() - PI * 0.5 if not gravity.is_zero_approx() else 0.0
	var error := wrapf(upright - torso_body.rotation, -PI, PI)
	var acceleration := clampf(error * 500.0 - torso_body.angular_velocity * 44.0, -160.0, 160.0)
	torso_body.control_torque = torso_body.inertia * acceleration * recovery_strength
	if absf(torso_body.control_torque) > 0.01:
		torso_body.awake = true
		torso_body.sleep_timer = 0.0
	for index in parts.size():
		var part: Dictionary = parts[index]
		var limb: PBody = part.body
		if recovering:
			joints[index].motor_off()
			continue
		var desired := float(part.rest_angle)
		# 没有实际水平移动时保持下垂零位，包括回正过程中；不能原地挥臂。
		if walking and standing_time <= 0.0 and recovery_strength >= 1.0 and absf(torso_body.linear_velocity.x) > 20.0:
			var bone: Bone2D = part.bone
			if uses_animation_tracks:
				var animation: AnimationPlayer = visual.get_node("AnimationPlayer")
				var walk := animation.get_animation("walk")
				var track := walk.find_track(NodePath(str(part.control.bone) + ":rotation"), Animation.TYPE_VALUE)
				if track >= 0:
					desired = float(walk.value_track_interpolate(track, animation.current_animation_position))
			else:
				var target: Node2D = visual.get_node(part.control.target)
				var pivot: Vector2 = bone.get_parent().to_global(part.rest_position)
				var direction: Vector2 = bone.get_parent().global_transform.basis_xform_inv(target.global_position - pivot)
				desired = direction.angle() - Vector2(part.control.rest_direction).angle()
			if str(bone.name).ends_with("Arm"):
				# 行走时围绕下垂姿势轻摆，动画切换不会把手臂突然抬高。
				desired = float(part.rest_angle) + clampf(wrapf(desired - part.rest_angle, -PI, PI), -0.12, 0.12)
			if str(bone.name).ends_with("Leg"):
				# 没有实际行进驱动时不让动画交替抬脚，保持双脚承重。
				desired = float(part.rest_angle)
		var stiffness := 180.0 if str(part.bone.name).ends_with("Leg") else 120.0
		joints[index].set_motor_target(wrapf(desired - part.rest_angle, -PI, PI),
			limb.inertia * 200.0 * recovery_strength, stiffness * maxf(recovery_strength, 0.05), 25.0)


func pause(paused: bool) -> void:
	torso_body.control_torque = 0.0
	for part: Dictionary in parts:
		var limb: PBody = part.body
		limb.tags["editor_physics_paused"] = paused
		limb.linear_velocity = Vector2.ZERO
		limb.angular_velocity = 0.0
		if paused:
			world_node.world.freeze(limb)
		else:
			world_node.world.unfreeze(limb)


func sync_from_node() -> void:
	recovery_strength = 1.0
	standing_time = 1.0
	visual.get_node("Skeleton2D/Root").position = Vector2.ZERO
	visual.get_node("Skeleton2D/Root/BodyBone").rotation = body_rest_rotation
	for part: Dictionary in parts:
		var bone: Bone2D = part.bone
		bone.position = part.rest_position
		bone.rotation = part.rest_angle
		var limb: PBody = part.body
		limb.position = world_node.to_local(bone.global_position)
		limb.rotation = bone.global_rotation - world_node.global_rotation
		limb.update_aabb()
		limb.compute_swept_aabb(0.0)


func update_pose(paused: bool) -> void:
	visual.get_node("Skeleton2D/Root").position = Vector2.ZERO
	visual.get_node("Skeleton2D/Root/BodyBone").rotation = body_rest_rotation
	for index in parts.size():
		var part: Dictionary = parts[index]
		var bone: Bone2D = part.bone
		var limb: PBody = part.body
		if paused:
			bone.position = part.rest_position
			bone.rotation = part.rest_angle
			continue
		bone.global_position = world_node.to_global(limb.position)
		bone.global_rotation = world_node.global_rotation + limb.rotation
	# 遮罩也读取实际骨骼变换，不使用上一帧的 IK 变换。
	visual._update_occlusion_materials()


func release() -> void:
	if is_instance_valid(world_node):
		for joint in joints + self_contact_filters:
			world_node.world.remove_joint(joint)
			joint.body_a = null
			joint.body_b = null
		for part: Dictionary in parts:
			world_node.world.remove_body(part.body)
			for shape in part.body.shapes:
				shape.owner_body = null
		world_node.realign_body_nodes()
	joints.clear()
	self_contact_filters.clear()
	parts.clear()
	torso_body = null
