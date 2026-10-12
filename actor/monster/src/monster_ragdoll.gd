extends RefCounted
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const PJoint := preload("res://addons/pixel_destruction/physics/joint.gd")
const HullFit := preload("res://addons/pixel_destruction/core/hull_fit.gd")
const LIVING_TAG := "living"
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
## 盾兵的可破坏盾牌。null 表示无盾或已破碎脱离。
var shield_body: PBody = null
var shield_joint: PJoint = null
var shield_holder: Dictionary = {}
var shield_initial_pixels := 0
var shield_broken := false
## 握盾时左手抬起的额外旋转（弧度），破碎后回零。
const SHIELD_HOLD_ARM_OFFSET := 0.55


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
		if monster.has_shield and not monster.shield_broken and str(bone.name) == "LeftArm":
			bone.rotation += SHIELD_HOLD_ARM_OFFSET
	_align_standing_feet()
	torso.ccd = true
	torso.additional_solver_iterations = 32 if monster.has_shield else 8
	for control: Dictionary in visual.LIMB_CONTROLS:
		var bone: Bone2D = visual.get_node(control.bone)
		var sprite: Sprite2D = bone.get_node(str(bone.name) + "Art")
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
	_setup_shield(monster)
	world_node.realign_body_nodes()
	animation.play("walk")


## 创建可破坏盾牌并绑定到身体朝向一侧；位置与尺寸使用怪物的导出参数。
## 握盾姿态在创建关节前烘焙，保证视觉与碰撞体使用同一个零位。
func shield_position(monster: Node2D) -> Vector2:
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
	# 找到左手肢体（仅用于握盾姿态，不绑定盾牌）
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
	shield_joint = world_node.world.add_weld(left_arm.body, shield_body, shield_pos)
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
func update_balance(delta: float, paused: bool, recovering: bool, walking: bool, monster: Node2D = null) -> void:
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
		var mirror_sign := -1.0 if visual.global_transform.determinant() < 0.0 else 1.0
		joints[index].set_motor_target(wrapf(desired - part.rest_angle, -PI, PI) * mirror_sign,
			limb.inertia * 200.0 * recovery_strength, stiffness * maxf(recovery_strength, 0.05), 25.0)
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
		limb.rotation = bone.global_transform.x.angle() - world_node.global_rotation
		limb.update_aabb()
		limb.compute_swept_aabb(0.0)
	# 未破碎时跟随躯干的朝向一侧。
	if shield_body != null and not shield_broken:
		shield_body.position = shield_position(visual.get_parent())
		shield_body.rotation = torso_body.rotation
		shield_body.linear_velocity = Vector2.ZERO
		shield_body.angular_velocity = 0.0
		shield_body.update_aabb()
		shield_body.compute_swept_aabb(0.0)


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
		# 负 X 缩放会把 Node2D 的全局旋转分解成额外的 PI 和负 Y 缩放。
		# 在父骨骼局部空间解算 X 轴角度，保留镜像，不把人物上下翻转。
		var parent := bone.get_parent() as Node2D
		var direction := Vector2.from_angle(world_node.global_rotation + limb.rotation)
		bone.rotation = parent.global_transform.basis_xform_inv(direction).angle()
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
