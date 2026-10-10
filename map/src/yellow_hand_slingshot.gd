extends Node2D
## 手拉弹弓靶场：黄墨连接黑色滑动弹兜，弹兜碰撞发射独立弹丸。
## 松手只解除正常抓握，不删弹簧，不赋发射速度。
const BodyNode = preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
const ShapeNode = preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
const Stroke = preload("res://actor/yellow/src/yellow_stroke.gd")
const Query = preload("res://addons/pixel_destruction/physics/query.gd")
const BASE = Vector2(5000, 5000)
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
var flight_distance: float = 0.0
var released: bool = false
var release_x: float = 0.0

func _ready() -> void:
	level = get_parent()
	await get_tree().process_frame
	await get_tree().process_frame
	level.auto_step = false
	level.get_node("SmallCanvas").active = false
	level.get_node("SmallCanvas").visible = false
	level.get_node("MapCanvas").active = false
	level.get_node("Gym").visible = false
	var camera = level.get_node("Camera2D")
	camera.set_script(null)
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.position = BASE + Vector2(280, 15)
	camera.zoom = Vector2(1.1, 1.1)
	camera.make_current()
	make_body("RangeFloor", BASE + Vector2(-250, 140), [Rect2i(0, 0, 1150, 24)], true)
	# 脚前挡块承受真实拉弓反作用力，手从挡块上方伸出。
	make_body("FootBrace", BASE + Vector2(68, 105), [Rect2i(0, 0, 12, 35)], true)
	var upper = make_body("UpperAnchor", BASE + Vector2(175, -5), [Rect2i(0, 0, 16, 16)], true)
	make_body("LowerAnchor", BASE + Vector2(175, 103), [Rect2i(0, 0, 16, 16)], true)
	cup = make_body("SlingPouch", BASE + Vector2(150, 40), [Rect2i(0, 0, 8, 40), Rect2i(0, 32, 48, 8)], false)
	# 水平导轨约束只固定方向和转角，沿发射方向的运动仍由手和黄墨决定。
	var guide = level.world.add_slider(upper, cup, cup.to_world(Vector2(4, 20)), Vector2.RIGHT)
	guide.contacts_enabled = true
	projectile = make_body("Projectile", BASE + Vector2(162, 52), [Rect2i(0, 0, 18, 18)], false)
	for index in 2:
		var stroke = Stroke.new()
		stroke.path = PackedVector2Array([BASE + Vector2(183.5, 3.5 if index == 0 else 111.5), BASE + Vector2(154.5, 44.5 if index == 0 else 76.5)])
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
	# 整体平移主体与连杆，保持原有身体/手关节的相对姿态。
	var player = level.get_node("Player").body
	var shift: Vector2 = BASE + Vector2(0, 54) - player.position
	for body in [player, level.get_node("Player/Arm").body, hand.body]:
		body.position += shift
		body.refresh_com()
		body.update_aabb()
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
		hand._begin_grab(cup, hit.point)

func observe() -> void:
	var gripping: bool = hand.grabbed_body == cup
	if gripping:
		max_draw = maxf(max_draw, BASE.x + 150 - cup.position.x)
	if was_gripping and not gripping:
		shots += 1
		released = true
		release_x = projectile.position.x
		launch_speed = 0.0
		flight_distance = 0.0
	if released:
		launch_speed = maxf(launch_speed, projectile.linear_velocity.x)
		flight_distance = maxf(flight_distance, projectile.position.x - release_x)
	was_gripping = gripping
	label.text = "手拉弹弓 / 默认 7 px 黄墨\n手靠近黑色弹兜背面，按住左键向左拖，松开发射\nA/D 移动身体；R 重置靶场\n拉长 %.0f px  发射 %d 次  弹丸 %.0f px/s  飞行 %.0f px" % [max_draw, shots, launch_speed, flight_distance]

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		var root_scene = get_tree().current_scene
		if root_scene != level and root_scene != null and root_scene.has_method("load_level"):
			root_scene.load_level(load("res://map/yellow_hand_slingshot.tscn"))
		else:
			get_tree().reload_current_scene()
