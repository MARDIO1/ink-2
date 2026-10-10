extends Node2D
## 手拉弹弓靶场：黄墨连接黑色滑动弹兜，弹兜碰撞发射独立弹丸。
## 松手只解除正常抓握，不删弹簧，不赋发射速度。
const BodyNode = preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
const ShapeNode = preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
const Stroke = preload("res://actor/yellow/src/yellow_stroke.gd")
const Query = preload("res://addons/pixel_destruction/physics/query.gd")
const BASE = Vector2(5000, 5000)
const CUP_HOME_X = 159.5
const CUP_INNER_RIGHT_X = 162.5
const PROJECTILE_LEFT_X = 162.5
var level
var hand
var cup
var projectile
var springs: Array = []
var ready_for_test: bool = false
var label: Label
var was_gripping: bool = false
var shots: int = 0
var max_draw: float = 0.0
var launch_speed: float = 0.0
var launch_horizontal_speed: float = 0.0
var flight_distance: float = 0.0
var released: bool = false
var release_x: float = 0.0
var initial_player_position: Vector2
var current_draw: float = 0.0
var left_screen: bool = false
var camera: Camera2D
var peak_hand_force: float = 0.0
var peak_power_percent: float = 0.0
var max_player_displacement: float = 0.0
var release_energy: float = 0.0
var peak_projectile_energy: float = 0.0
var energy_efficiency: float = 0.0
var launch_measurement_open: bool = false
@export_range(1.0, 8.0, 0.25) var hand_power_scale: float = 3.0
@export_range(160.0, 320.0, 10.0) var hand_reach: float = 260.0
@export_range(1.0, 6.0, 0.25) var hand_position_stiffness_scale: float = 4.0
@export_range(0.0, 1.0, 0.05) var launch_restitution: float = 1.0

func _ready() -> void:
	level = get_parent()
	await get_tree().process_frame
	await get_tree().process_frame
	level.auto_step = false
	level.get_node("SmallCanvas").active = false
	level.get_node("SmallCanvas").visible = false
	level.get_node("MapCanvas").active = false
	level.get_node("Gym").visible = false
	camera = level.get_node("Camera2D")
	camera.set_script(null)
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.position = BASE + Vector2(280, 15)
	camera.zoom = Vector2(1.1, 1.1)
	camera.make_current()
	# 玩家脚下保留地面，发射方向留空，让弹丸能真正飞出视口。
	make_body("PlayerFloor", BASE + Vector2(-250, 140), [Rect2i(0, 0, 380, 24)], true)
	# 脚前挡块承受真实拉弓反作用力，手从挡块上方伸出。
	make_body("FootBrace", BASE + Vector2(68, 105), [Rect2i(0, 0, 12, 35)], true)
	var upper = make_body("UpperAnchor", BASE + Vector2(175, -5), [Rect2i(0, 0, 16, 16)], true)
	make_body("LowerAnchor", BASE + Vector2(175, 110), [Rect2i(0, 0, 16, 16)], true)
	# 之后新建的弹兜、弹丸和靶子不使用世界线性阻尼；重力仍保留。
	level.world.rp_linear_damping = 0.0
	# 朝右开口的半圆弧弹兜；内弧与圆形弹丸相切，不靠隐藏导轨限制运动。
	cup = make_arc_body("SlingPouch", BASE + Vector2(CUP_HOME_X, 48.0), 24, 9.0)
	cup.restitution = launch_restitution
	cup.friction = 0.0
	cup.gravity_scale = 0.0
	# 弹丸只放在普通黑色托台上；拉弓和装填均不使用关节。
	var projectile_rest = make_body("ProjectileRest", BASE + Vector2(160.5, 69.0), [Rect2i(0, 0, 60, 24)], true)
	projectile_rest.friction = 0.0
	# 圆形弹丸左边缘与弹兜内弧右边缘同为 x=162.5，初始零缝隙接触。
	projectile = make_circle_body("Projectile", BASE + Vector2(PROJECTILE_LEFT_X, 51.0), 8.5)
	projectile.restitution = launch_restitution
	projectile.friction = 0.0
	for index in 2:
		var stroke = Stroke.new()
		stroke.path = PackedVector2Array([BASE + Vector2(183.5, 3.5 if index == 0 else 117.5), BASE + Vector2(161.0, 61.0)])
		stroke.brush_width = 7
		level.add_child(stroke)
		stroke.anchors = [Stroke.find_anchor(level.world, stroke.path[0]), Stroke.find_anchor(level.world, stroke.path[-1])]
		stroke.rest_length = stroke.path[0].distance_to(stroke.path[-1])
		stroke.state = Stroke.State.ACTIVE
		level.get_node("SimulationRuntime/YellowInk").strokes.append(stroke)
		level.get_node("SimulationRuntime/YellowInk").connect_stroke(stroke, level.world)
		springs.append(stroke)
	for index in 3:
		make_body("Target%d" % index, BASE + Vector2(300 + index * 70, 108 - index * 12), [Rect2i(0, 0, 20, 32 + index * 12)], false)
	hand = level.get_node("Player/Arm/Hand/HandControl")
	hand.set_enabled(true)
	hand.max_power *= hand_power_scale
	hand.max_reach = hand_reach
	hand.position_stiffness *= hand_position_stiffness_scale
	# HandControl 的滑轨是玩家场景本来就有的约束；同步它的导出范围，不创建新关节。
	var reach_offset: float = hand.body.com_world().distance_to(hand.player_body.com_world())
	hand.arm_joint.set_limits(hand.min_target_radius - reach_offset,
		hand.max_reach - hand.reach_solver_margin - reach_offset)
	# 整体平移主体与连杆，保持原有身体/手关节的相对姿态。
	var player = level.get_node("Player").body
	var shift: Vector2 = BASE + Vector2(0, 54) - player.position
	for body in [player, level.get_node("Player/Arm").body, hand.body]:
		body.position += shift
		body.refresh_com()
		body.update_aabb()
	initial_player_position = player.position
	var hud = CanvasLayer.new()
	add_child(hud)
	label = Label.new()
	label.position = Vector2(20, 20)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(label)
	await get_tree().process_frame
	camera.force_update_scroll()
	ready_for_test = true
	level.auto_step = true

func make_body(title: String, point: Vector2, rects: Array, fixed: bool):
	var node = BodyNode.new()
	node.name = title
	node.position = point
	node.is_static = fixed
	for rect: Rect2i in rects:
		var shape = ShapeNode.new()
		shape.position = Vector2(rect.position)
		shape.rect_size = rect.size
		node.add_child(shape)
	level.add_child(node)
	return level.add_body_node(node)

func make_circle_body(title: String, point: Vector2, radius: float):
	var node = BodyNode.new()
	node.name = title
	node.position = point
	var shape = ShapeNode.new()
	shape.source = ShapeNode.Source.CIRCLE
	shape.radius = radius
	node.add_child(shape)
	level.add_child(node)
	return level.add_body_node(node)

func make_arc_body(title: String, point: Vector2, diameter: int, inner_radius: float):
	var node = BodyNode.new()
	node.name = title
	node.position = point
	var shape = ShapeNode.new()
	shape.source = ShapeNode.Source.PAINT
	shape.paint = Image.create(diameter, diameter, false, Image.FORMAT_R8)
	shape.paint.fill(Color.BLACK)
	var center := Vector2(diameter, diameter) * 0.5
	var outer_radius: float = diameter * 0.5
	for y in diameter:
		for x in diameter:
			var offset := Vector2(x + 0.5, y + 0.5) - center
			if offset.x <= 0.0 and offset.length() >= inner_radius and offset.length() <= outer_radius:
				shape.paint.set_pixel(x, y, Color8(1, 0, 0))
	node.add_child(shape)
	level.add_child(node)
	return level.add_body_node(node)

func _physics_process(_delta: float) -> void:
	if ready_for_test:
		assist_grab()
		observe()

func assist_grab() -> void:
	var pressed: bool = hand._grip_override if hand._grip_override != null else Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if not pressed or hand.grip_joint != null:
		return
	# 拉柄处 3 px 抓取容错；仍建立原有物理 Weld，不直接移动弹兜。
	var tip: Vector2 = hand.body.com_world() + hand.FINGERTIP.rotated(hand.body.rotation)
	var hit = Query.closest_point(tip, 3.0, [hand.body, hand.player_body, hand.arm_body])
	if hit.hit and hit.body == cup:
		hand._begin_grab(cup, cup.to_world(cup.local_com))

func observe() -> void:
	var gripping: bool = hand.grabbed_body == cup
	current_draw = maxf(0.0, BASE.x + CUP_HOME_X - cup.position.x)
	if gripping:
		max_draw = maxf(max_draw, current_draw)
	if was_gripping and not gripping:
		release_energy = spring_energy()
		shots += 1
		released = true
		release_x = projectile.position.x
		launch_speed = 0.0
		launch_horizontal_speed = 0.0
		flight_distance = 0.0
		peak_projectile_energy = 0.0
		energy_efficiency = 0.0
		launch_measurement_open = true
	if released:
		# 只在首个靶子之前量发射性能，避免重力下落或撞靶把数字刷高。
		launch_measurement_open = launch_measurement_open and projectile.position.x < BASE.x + 285.0
		if launch_measurement_open:
			launch_speed = maxf(launch_speed, projectile.linear_velocity.length())
			launch_horizontal_speed = maxf(launch_horizontal_speed, projectile.linear_velocity.x)
			peak_projectile_energy = maxf(peak_projectile_energy, 0.5 * projectile.mass * launch_horizontal_speed * launch_horizontal_speed)
			energy_efficiency = 100.0 * peak_projectile_energy / maxf(release_energy, 1.0)
		flight_distance = maxf(flight_distance, projectile.position.x - release_x)
		left_screen = left_screen or projectile.position.x > screen_right()
	was_gripping = gripping
	var player = level.get_node("Player").body
	var extension: float = spring_extension()
	var stored_energy: float = spring_energy()
	var fingertip: Vector2 = hand.body.com_world() + hand.FINGERTIP.rotated(hand.body.rotation)
	var pouch_center: Vector2 = cup.to_world(cup.local_com)
	var hand_to_pouch: float = fingertip.distance_to(pouch_center)
	var mouse_target: Vector2 = hand._get_mouse_world_position()
	var power_percent: float = 100.0 * hand.debug_active_power / maxf(hand.max_power, 1.0)
	peak_hand_force = maxf(peak_hand_force, hand.debug_force_vector.length())
	peak_power_percent = maxf(peak_power_percent, power_percent)
	max_player_displacement = maxf(max_player_displacement, player.position.distance_to(initial_player_position))
	label.text = "手拉弹弓 / 7 px 黄墨 / 零弹簧阻尼\n手靠近黑色弹兜背面，按住左键向左拖，松开发射；R 重置\n拉程 %.0f / %.0f px  弹簧伸长 %.1f px  储能 %.1f MJ\n手力 %.2f MN（峰值 %.2f） 功率 %.0f%%（峰值 %.0f%%）\n主角质量 %.0f  位移 %.1f px（最大 %.1f）\n弹丸 %.0f px/s  飞行 %.0f px  %s" % [current_draw, max_draw, extension, stored_energy / 1000000.0, hand.debug_force_vector.length() / 1000000.0, peak_hand_force / 1000000.0, power_percent, peak_power_percent, player.mass, player.position.distance_to(initial_player_position), max_player_displacement, launch_speed, flight_distance, "已飞出画面" if left_screen else "仍在画面内"]

	label.text += "\n峰值速度 %.0f px/s（水平 %.0f）  弹丸能量 %.1f MJ  转换效率 %.0f%%" % [launch_speed, launch_horizontal_speed, peak_projectile_energy / 1000000.0, energy_efficiency]
	label.text += "\n抓取：%s  指尖距撞子 %.1f px  鼠标目标距主角 %.0f px" % ["已抓住" if gripping else "未抓住", hand_to_pouch, mouse_target.distance_to(player.com_world())]

func spring_extension() -> float:
	var total: float = 0.0
	for stroke in springs:
		total += maxf(0.0, Stroke.anchor_world(stroke.anchors[0]).distance_to(Stroke.anchor_world(stroke.anchors[1])) - stroke.rest_length)
	return total / maxf(1.0, springs.size())

func spring_energy() -> float:
	var total: float = 0.0
	for stroke in springs:
		var extension: float = maxf(0.0, Stroke.anchor_world(stroke.anchors[0]).distance_to(Stroke.anchor_world(stroke.anchors[1])) - stroke.rest_length)
		total += 0.5 * stroke.joint.stiffness * extension * extension if stroke.joint != null else 0.0
	return total

func screen_right() -> float:
	return camera.get_screen_center_position().x + camera.get_viewport_rect().size.x * 0.5 / camera.zoom.x

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		var root_scene = get_tree().current_scene
		if root_scene != level and root_scene != null and root_scene.has_method("load_level"):
			root_scene.load_level(load("res://map/yellow_hand_slingshot.tscn"))
		else:
			get_tree().reload_current_scene()
