extends RefCounted
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const PJoint := preload("res://addons/pixel_destruction/physics/joint.gd")
const HullFit := preload("res://addons/pixel_destruction/core/hull_fit.gd")
const LIVING_TAG := "living"
const RECOVERY_RAMP_SECONDS := 0.9
const MAX_RECOVERY_ANGULAR_SPEED := 2.8
const MAX_RECOVERY_ANGULAR_ACCELERATION := 120.0
static var _outline_cache: Dictionary = {}

## 五个真实刚体共用 PixelWorld；动画只提供软马达目标，绝不直接移动碰撞体。
var parts: Array = []
var joints: Array = []
var self_contact_filters: Array = []
var world_node: Node2D
var visual: Node2D
var torso_body: PBody
var recovery_strength := 0.0
var _recovery_progress := 0.0
var _recovery_drive_scale := 1.0
var standing_time := 1.0
var foot_height_correction := 0.0
var uses_animation_tracks := false
var body_rest_rotation := 0.0
var body_rest_position := Vector2.ZERO
## 盾兵的可破坏盾牌。null 表示无盾或已破碎脱离。
var shield_body: PBody = null
var shield_joint: PJoint = null
var shield_holder: Dictionary = {}
var shield_initial_pixels := 0
var shield_broken := false
var shield_sole_offset := 0.0
## 握盾时抬起左手；盾牌中心可以偏离掌心，破碎后放下。
const SHIELD_HOLD_ARM_OFFSET := 1.15


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


## 从纹理直接光栅化像素形状：alpha > 阈值的像素填充为指定材质。
## scale 用于匹配怪物 Visual 的缩放；center_origin 使形状原点居中，便于旋转对齐。
static func texture_shape(texture: Texture2D, material: int, alpha_threshold := 128,
		scale := 1.0, center_origin := false, flip_x := false, height_scale := 1.0) -> PixelShape:
	var shape := PixelShape.new()
	if texture == null:
		return shape
	var image := texture.get_image()
	if image == null:
		return shape
	var w := image.get_width()
	var h := image.get_height()
	# 先扫描非透明区域的 bbox，用于居中偏移
	var min_x := INF
	var max_x := -INF
	var min_y := INF
	var max_y := -INF
	for y in h:
		for x in w:
			if image.get_pixel(x, y).a * 255.0 > alpha_threshold:
				min_x = minf(min_x, x)
				max_x = maxf(max_x, x)
				min_y = minf(min_y, y)
				max_y = maxf(max_y, y)
	if min_x == INF:
		return shape
	var offset_x := 0.0
	var offset_y := 0.0
	if center_origin:
		offset_x = (min_x + max_x + 1.0) * 0.5 * scale
		offset_y = (min_y + max_y + 1.0) * 0.5 * scale * height_scale
	for y in h:
		var left := -1
		# 分段填充，保留盾牌纹理中的透明窗口，不把整行包围区间填实。
		for x in range(w + 1):
			if x < w and image.get_pixel(x, y).a * 255.0 > alpha_threshold:
				if left < 0:
					left = x
			elif left >= 0:
				var sx := floori(float(left) * scale - offset_x)
				var sw := maxi(1, ceili(float(x) * scale - offset_x) - sx)
				if flip_x:
					sx = -sx - sw
				var sy := floori(float(y) * scale * height_scale - offset_y)
				var end_y := ceili(float(y + 1) * scale * height_scale - offset_y)
				shape.fill_rect(Rect2i(sx, sy, sw, maxi(1, end_y - sy)), material)
				left = -1
	return shape


## 统计形状中的实心像素总数。PixelShape 内置 pixel_count()，这里做一层空值保护。
static func count_pixels(shape) -> int:
	if shape == null:
		return 0
	return shape.pixel_count()


static func body_bone(visual_node: Node2D) -> Bone2D:
	var path: NodePath = visual_node.BODY_BONE_PATH if "BODY_BONE_PATH" in visual_node else ^"Skeleton2D/Root/BodyBone"
	return visual_node.get_node(path) as Bone2D


static func limb_art(bone: Bone2D) -> Sprite2D:
	var art := bone.get_node_or_null(str(bone.name) + "Art") as Sprite2D
	return art if art != null else bone.get_node("Art") as Sprite2D


static func body_art(visual_node: Node2D) -> Sprite2D:
	var bone := body_bone(visual_node)
	var art := bone.get_node_or_null("BodyArt") as Sprite2D
	return art if art != null else bone.get_node("Art") as Sprite2D


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
		var pixel: Vector2 = point
		if sprite.flip_h:
			pixel.x = sprite.texture.get_width() - pixel.x
		if sprite.flip_v:
			pixel.y = sprite.texture.get_height() - pixel.y
		points.append(transform * (pixel + offset))
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
	body_rest_rotation = body_bone(visual).rotation
	body_rest_position = body_bone(visual).position
	visual.solve_ik = false
	visual.hand_drawn_wobble = false
	# 双手在身体两侧自然下垂，略向外避开二维素材中重叠的大腿。
	# 此姿势同时作为碰撞体的初始朝向和受击后的关节回正零位。
	for control: Dictionary in visual.LIMB_CONTROLS:
		var bone: Bone2D = visual.get_node(control.bone)
		if str(bone.name).ends_with("Arm") and not uses_animation_tracks:
			var outward := 0.26 if str(bone.name) == "LeftArm" else -0.26
			bone.rotation = Vector2.DOWN.angle() + outward - Vector2(control.rest_direction).angle()
		if monster.has_shield and not monster.shield_broken and str(bone.name) == "LeftArm":
			bone.rotation += SHIELD_HOLD_ARM_OFFSET
	_align_standing_feet()
	torso.ccd = true
	torso.additional_solver_iterations = 32 if monster.has_shield else 8
	for control: Dictionary in visual.LIMB_CONTROLS:
		var bone: Bone2D = visual.get_node(control.bone)
		var sprite := limb_art(bone)
		var frame := Transform2D(bone.global_transform.x.angle(), bone.global_position)
		var shape := sprite_shape(sprite, frame, monster.material_id)
		shape.density_scale = monster.physics_density_scale
		var limb := PBody.new()
		limb.position = world_node.to_local(bone.global_position)
		limb.rotation = bone.global_transform.x.angle() - world_node.global_rotation
		limb.tags = torso.tags.duplicate()
		limb.tags["monster_part"] = str(bone.name)
		limb.internal_render = false
		limb.ccd = true
		limb.additional_solver_iterations = 32 if monster.has_shield else 8
		world_node.world.add_body(limb, [shape], Callable(world_node, "_density_of"), true)
		var joint: PJoint = world_node.world.add_hinge(torso, limb, limb.position)
		joint.set_limits(-1.4, 1.4)
		if str(bone.name).ends_with("Leg"):
			joint.set_limits(-0.55, 0.55)
		joint.set_motor_target(0.0, limb.inertia * 200.0, 100.0, 20.0)
		parts.append({"bone": bone, "body": limb, "control": control,
			"rest_angle": bone.rotation, "joint_rest_angle": bone.rotation, "rest_position": bone.position})
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
	_setup_shield(monster)
	world_node.realign_body_nodes()
	animation.play("walk")


## 创建可破坏盾牌并绑定到身体朝向一侧；位置与尺寸使用怪物的导出参数。
## 握盾姿态在创建关节前烘焙，保证视觉与碰撞体使用同一个零位。
func shield_position(monster: Node2D) -> Vector2:
	var palm := visual.get_node_or_null("Skeleton2D/Root/BodyBone/LeftArm/LeftArmArt/PalmGrip") as Node2D
	if palm != null:
		var inward: Vector2 = visual.global_transform.x.normalized() * monster.shield_grip_inset * absf(monster.scale.x)
		return world_node.to_local(palm.global_position + inward) + Vector2(0.0, shield_sole_offset).rotated(torso_body.rotation)
	var offset: Vector2 = monster.shield_offset * monster.scale.abs()
	if monster._current_facing > 0:
		offset.x = -offset.x
	return torso_body.position + offset.rotated(torso_body.rotation)

func _setup_shield(monster: Node2D) -> void:
	if not monster.has_shield or monster.shield_broken:
		return
	var shield_texture := load(monster.shield_texture_path) as Texture2D
	if shield_texture == null:
		push_warning("盾兵盾牌贴图不存在：%s" % monster.shield_texture_path)
		return
	# 保留掌心焊接点，但盾牌中心独立偏移，底缘对齐站立脚底。
	var left_arm: Dictionary = {}
	for part: Dictionary in parts:
		if str(part.bone.name) == "LeftArm":
			left_arm = part
			break
	if left_arm.is_empty():
		return
	# 按怪物的尺寸缩放，同步镜像物理像素。
	var shield_shape := texture_shape(shield_texture, monster.shield_material_id, 128,
		monster.shield_scale * absf(monster.scale.x), true,
		monster._current_facing > 0, monster.shield_height_scale)
	shield_shape.density_scale = monster.physics_density_scale
	shield_sole_offset = 0.0
	var palm_marker := visual.get_node_or_null("Skeleton2D/Root/BodyBone/LeftArm/LeftArmArt/PalmGrip") as Node2D
	if palm_marker != null:
		var palm_position := world_node.to_local(palm_marker.global_position)
		var sole := -INF
		for part: Dictionary in parts:
			if not str(part.bone.name).ends_with("Leg"):
				continue
			var art: Sprite2D = part.bone.get_node(str(part.bone.name) + "Art")
			var bounds := Rect2(art.texture.get_image().get_used_rect())
			bounds.position -= art.texture.get_size() * 0.5
			for corner in [bounds.position, Vector2(bounds.end.x, bounds.position.y), bounds.end, Vector2(bounds.position.x, bounds.end.y)]:
				var point := world_node.to_local(art.to_global(corner))
				sole = maxf(sole, (point - palm_position).rotated(-torso_body.rotation).y)
		if sole != -INF:
			shield_sole_offset = sole - float(shield_shape.local_aabb().end.y)
	shield_initial_pixels = count_pixels(shield_shape)
	var shield_shapes: Array = [shield_shape]
	if not monster._turning_shield_shapes.is_empty():
		shield_shapes = monster._turning_shield_shapes.duplicate()
		shield_initial_pixels = monster._turning_shield_initial_pixels
	if shield_initial_pixels <= 0:
		return
	# 位置相对脚底原点，旋转跟随躯干。
	var shield_pos := shield_position(monster)
	shield_body = PBody.new()
	shield_body.position = shield_pos
	shield_body.rotation = torso_body.rotation
	shield_body.tags = torso_body.tags.duplicate()
	# 盾牌是可破坏物体，不能继承生物的 LIVING_TAG，否则 impact_damage 会跳过像素伤害。
	shield_body.tags.erase(LIVING_TAG)
	shield_body.tags["monster_part"] = "Shield"
	shield_body.internal_render = false
	shield_body.ccd = true
	shield_body.additional_solver_iterations = 32
	world_node.world.add_body(shield_body, shield_shapes, Callable(world_node, "_density_of"), true)
	# 盾牌由画面左侧的手臂握持，受击时与该手臂一起运动。
	var palm := visual.get_node_or_null("Skeleton2D/Root/BodyBone/LeftArm/LeftArmArt/PalmGrip") as Node2D
	var grip_anchor := world_node.to_local(palm.global_position) if palm != null else shield_pos
	shield_joint = world_node.world.add_weld(left_arm.body, shield_body, grip_anchor)
	if shield_joint != null:
		shield_joint.contacts_enabled = false
	var torso_filter: PJoint = world_node.world.add_rope(shield_body, torso_body,
		shield_body.position, torso_body.position, 1000000.0)
	torso_filter.contacts_enabled = false
	self_contact_filters.append(torso_filter)
	# 盾牌与本人的四肢同样排除自碰撞，避免焊接约束和碰撞求解互相顶住。
	for part: Dictionary in parts:
		var exclusion: PJoint = world_node.world.add_rope(shield_body, part.body,
			shield_body.position, part.body.position, 1000000.0)
		exclusion.contacts_enabled = false
		self_contact_filters.append(exclusion)
	shield_holder = left_arm
	shield_broken = false
	monster.shield_broken = false


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
		var sprite := limb_art(bone)
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
		var bone_frame: Transform2D = leg.bone.transform
		if "BODY_BONE_PATH" in visual:
			# 侧身角色的腿挂在预旋转躯干下，脚底偏移需包含该父变换。
			bone_frame = visual.global_transform.affine_inverse() * leg.bone.global_transform
		var offset := bone_frame.basis_xform_inv(Vector2(0.0, -adjustment))
		for child in leg.bone.get_children():
			if child is Sprite2D:
				child.position += offset


## 在固定物理帧更新姿势控制。力矩经过求解器，不直接覆盖真实刚体角度。
func update_balance(delta: float, paused: bool, recovering: bool, walking: bool, monster: Node2D = null) -> void:
	if torso_body == null:
		return
	if paused:
		torso_body.control_torque = 0.0
		if shield_body != null:
			shield_body.control_torque = 0.0
		for part: Dictionary in parts:
			part.body.control_torque = 0.0
		return
	standing_time = maxf(0.0, standing_time - delta)
	if recovering:
		_recovery_progress = 0.0
		recovery_strength = 0.0
	else:
		_recovery_progress = minf(1.0, _recovery_progress + delta / RECOVERY_RAMP_SECONDS)
		# 平滑重新接管，避免受击松开后突然把整套关节拉回零位。
		recovery_strength = smoothstep(0.0, 1.0, _recovery_progress)
	var gravity: Vector2 = world_node.world.gravity
	var upward_speed := 0.0
	if not gravity.is_zero_approx():
		var momentum: Vector2 = torso_body.linear_velocity * torso_body.mass
		var total_mass: float = torso_body.mass
		for part: Dictionary in parts:
			momentum += part.body.linear_velocity * part.body.mass
			total_mass += part.body.mass
		if shield_body != null and not shield_broken:
			momentum += shield_body.linear_velocity * shield_body.mass
			total_mass += shield_body.mass
		upward_speed = maxf(0.0, -(momentum / maxf(total_mass, 0.001)).dot(gravity.normalized()))
	# 已经向上离地时减小主动扶正，阻尼仍保留；不直接钳制受击线速度。
	var desired_drive := lerpf(1.0, 0.15, smoothstep(20.0, 100.0, upward_speed))
	var drive_rate := 20.0 if desired_drive < _recovery_drive_scale else 2.0
	_recovery_drive_scale = move_toward(_recovery_drive_scale, desired_drive, delta * drive_rate)
	var drive_strength := recovery_strength * _recovery_drive_scale
	if shield_body != null:
		shield_body.control_torque = 0.0
	var upright := gravity.angle() - PI * 0.5 if not gravity.is_zero_approx() else 0.0
	var error := wrapf(upright - torso_body.rotation, -PI, PI)
	var target_speed := clampf(error * 8.0, -MAX_RECOVERY_ANGULAR_SPEED, MAX_RECOVERY_ANGULAR_SPEED)
	# 弹簧项渐入；恢复阶段的阻尼不随刚度削弱，先吸收旋转动量再扶正。
	var acceleration := clampf((target_speed * drive_strength - torso_body.angular_velocity) * 50.0,
		-MAX_RECOVERY_ANGULAR_ACCELERATION, MAX_RECOVERY_ANGULAR_ACCELERATION)
	# 大角度倒地时需要克服绕支撑点的惯量，不能只按躯干质心惯量限力。
	# 接近站立后平滑撤去这部分扶起能力，避免以倒地力度顶地回弹。
	var support_inertia: float = torso_body.inertia + torso_body.mass * torso_body.local_com.length_squared()
	var support_blend := 0.0 if gravity.is_zero_approx() else smoothstep(0.5, 1.0, absf(error))
	support_blend *= 1.0 - smoothstep(0.0, 40.0, upward_speed)
	var recovery_inertia: float = lerpf(torso_body.inertia,
		minf(support_inertia, torso_body.inertia * 4.0), support_blend)
	torso_body.control_torque = 0.0 if recovering else recovery_inertia * acceleration
	if absf(torso_body.control_torque) > 0.01:
		torso_body.awake = true
		torso_body.sleep_timer = 0.0
	for index in parts.size():
		var part: Dictionary = parts[index]
		var limb: PBody = part.body
		limb.control_torque = 0.0
		if recovering:
			joints[index].motor_off()
			continue
		var desired := float(part.rest_angle)
		# 没有实际水平移动时保持下垂零位，包括回正过程中；不能原地挥臂。
		var holding_shield: bool = not shield_holder.is_empty() and part == shield_holder and shield_body != null and not shield_broken
		# 滑动、被挤开或受击的速度不是行进驱动，不能触发摆臂再向接触注入能量。
		# 底缘齐地的盾牌也不能随行走摆臂。
		var has_walk_drive := absf(torso_body.control_force.x) > 0.001
		if walking and has_walk_drive and not holding_shield and standing_time <= 0.0 and recovery_strength >= 1.0 and absf(torso_body.linear_velocity.x) > 20.0:
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
		# 腿保留承重能力；增加阻尼比而非削弱支撑，避免半弯状态卡住。
		var leg_stiffness := 180.0 if shield_body != null and not shield_broken else 230.0
		var stiffness := leg_stiffness if str(part.bone.name).ends_with("Leg") else 120.0
		# 回正要承受焊接盾牌的惯量与重力，不能只按手臂本身限力。
		var pivot := limb.position
		var load_inertia: float = limb.inertia
		var motor_damping := 40.0 if str(part.bone.name).ends_with("Leg") else 32.0
		var max_speed := MAX_RECOVERY_ANGULAR_SPEED
		if not shield_holder.is_empty() and part == shield_holder and shield_body != null and not shield_broken:
			load_inertia += limb.mass * limb.com_world().distance_squared_to(pivot)
			load_inertia += shield_body.inertia + shield_body.mass * shield_body.com_world().distance_squared_to(pivot)
			# 盾牌与手臂焊接，只由握盾关节回正；双重伺服在底缘接地时会注入额外能量。
			# 对重载握盾臂使用略过阻尼伺服，避免重力下垂和回正过冲。
			# 保留静态承重刚度，通过更强阻尼放慢重载回正，避免盾牌下垂。
			stiffness = 900.0
			motor_damping = 72.0
			max_speed = 4.0
		var mirror_sign := -1.0 if part.bone.get_parent().global_transform.determinant() < 0.0 else 1.0
		var target := wrapf(desired - part.joint_rest_angle, -PI, PI) * mirror_sign
		# 上抬反馈不能撤掉握盾臂的承重力，否则盾牌落地后会再次顶起角色。
		var motor_strength := recovery_strength if holding_shield else drive_strength
		var effective_stiffness := stiffness * maxf(motor_strength, 0.05)
		var movement: float = joints[index].movement()
		if absf(wrapf(target - movement, -PI, PI)) > 0.06 or recovery_strength < 1.0:
			# 不能把尚未归位的肢体提前休眠，尤其是撑地后卡在半弯状态的腿。
			limb.awake = true
			limb.sleep_timer = 0.0
		# 限制伺服误差对应的目标速度，不篡改受击速度或瞬移刚体。
		var max_error := max_speed * motor_damping / effective_stiffness
		var limited_target := movement + clampf(wrapf(target - movement, -PI, PI), -max_error, max_error)
		joints[index].set_motor_target(limited_target,
			load_inertia * 200.0 * motor_strength, effective_stiffness, motor_damping)
	_check_shield_break(monster)


## 检测盾牌是否破碎：剩余像素低于阈值时断开焊接、左手放下。
func _check_shield_break(monster: Node2D) -> void:
	if monster == null or shield_body == null or shield_broken:
		return
	if shield_initial_pixels <= 0:
		return
	var current_pixels := 0
	var body_alive: bool = world_node.world.bodies.has(shield_body)
	if body_alive:
		for shape in shield_body.shapes:
			current_pixels += count_pixels(shape)
	var ratio := float(current_pixels) / float(shield_initial_pixels)
	if ratio > monster.shield_break_threshold:
		return
	# 盾牌破碎：断开与左手的焊接，盾牌成为自由刚体可被打飞
	shield_broken = true
	monster.shield_broken = true
	shield_body.control_torque = 0.0
	# 脱落后以实际剩余像素绘制，不能隐藏贴图后留下不可见的自由刚体。
	shield_body.internal_render = true
	shield_body.tags.erase("monster_receiver")
	shield_body.tags.erase("map_monster")
	for exclusion in self_contact_filters.duplicate():
		if exclusion.body_a == shield_body or exclusion.body_b == shield_body:
			world_node.world.remove_joint(exclusion)
			exclusion.body_a = null
			exclusion.body_b = null
			self_contact_filters.erase(exclusion)
	if shield_joint != null:
		world_node.world.remove_joint(shield_joint)
		shield_joint.body_a = null
		shield_joint.body_b = null
		shield_joint = null
	# 左手放下：回握盾时抬起的角度
	if not shield_holder.is_empty():
		shield_holder.rest_angle -= SHIELD_HOLD_ARM_OFFSET
	if body_alive:
		world_node.renderer.sync(shield_body)
	else:
		world_node.renderer.forget(shield_body.id)
		for shape in shield_body.shapes:
			shape.owner_body = null
		shield_body = null


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
	# 盾牌冻结
	if shield_body != null:
		shield_body.tags["editor_physics_paused"] = paused
		shield_body.linear_velocity = Vector2.ZERO
		shield_body.angular_velocity = 0.0
		if paused:
			world_node.world.freeze(shield_body)
		else:
			world_node.world.unfreeze(shield_body)


func sync_from_node() -> void:
	_recovery_drive_scale = 1.0
	_recovery_progress = 1.0
	recovery_strength = 1.0
	standing_time = 1.0
	_reset_body_pose()
	for part: Dictionary in parts:
		var bone: Bone2D = part.bone
		bone.position = part.rest_position
		bone.rotation = part.rest_angle
		var limb: PBody = part.body
		limb.position = world_node.to_local(bone.global_position)
		limb.rotation = bone.global_transform.x.angle() - world_node.global_rotation
		limb.update_aabb()
		limb.compute_swept_aabb(0.0)
	# 恢复固定的掌心偏移，不重新计算脚底高度，以免累积漂移。
	if shield_body != null and not shield_broken:
		shield_body.position = shield_position(visual.get_parent())
		shield_body.rotation = torso_body.rotation
		shield_body.linear_velocity = Vector2.ZERO
		shield_body.angular_velocity = 0.0
		shield_body.update_aabb()
		shield_body.compute_swept_aabb(0.0)


func update_pose(paused: bool) -> void:
	_reset_body_pose()
	for index in parts.size():
		var part: Dictionary = parts[index]
		var bone: Bone2D = part.bone
		var limb: PBody = part.body
		if paused:
			bone.position = part.rest_position
			bone.rotation = part.rest_angle
			continue
		bone.global_position = world_node.to_global(limb.position)
		# 负 X 缩放会把 Node2D 的全局旋转分解成额外的 PI 和负 Y 缩放。
		# 在父骨骼局部空间解算 X 轴角度，保留镜像，不把人物上下翻转。
		var parent := bone.get_parent() as Node2D
		var direction := Vector2.from_angle(world_node.global_rotation + limb.rotation)
		bone.rotation = parent.global_transform.basis_xform_inv(direction).angle()
	# 遮罩也读取实际骨骼变换，不使用上一帧的 IK 变换。
	visual._update_occlusion_materials()


func _reset_body_pose() -> void:
	var root_bone := visual.get_node_or_null("Skeleton2D/Root") as Node2D
	if root_bone != null:
		root_bone.position = Vector2.ZERO
	var bone := body_bone(visual)
	bone.position = body_rest_position
	bone.rotation = body_rest_rotation


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
		# 清理盾牌
		if shield_joint != null:
			world_node.world.remove_joint(shield_joint)
			shield_joint.body_a = null
			shield_joint.body_b = null
			shield_joint = null
		if shield_body != null:
			world_node.world.remove_body(shield_body)
			for shape in shield_body.shapes:
				shape.owner_body = null
			shield_body = null
		world_node.realign_body_nodes()
	joints.clear()
	self_contact_filters.clear()
	parts.clear()
	shield_holder = {}
	shield_initial_pixels = 0
	shield_broken = false
	torso_body = null
