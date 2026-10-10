extends Node2D
## 独立黄墨验收场：默认 7 px 双弹簧、黑色托板、真实主角碰撞。
## 蓄力阶段锁住托板，释放只解锁；不向主角或托板注入发射速度。
const BodyNode = preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
const Stroke = preload("res://actor/yellow/src/yellow_stroke.gd")
var level
var rule
var player
var platform
var springs: Array = []
var ready_for_test: bool = false
var phase: String = "suspension"
var timer: float = 0.0
var shots: Array[Dictionary] = []
var peak_speed: float = 0.0
var peak_rise: float = 0.0
var launch_y: float = 0.0
var suspension_sag: float = 0.0
var label: Label
var arm_poses: Array = []
const BASE = Vector2(5000, 5000)

func _ready() -> void:
	level = preload("res://map/main.tscn").instantiate()
	level.auto_step = false
	add_child(level)
	await get_tree().process_frame
	await get_tree().process_frame
	rule = level.get_node("SimulationRuntime/YellowInk")
	player = level.get_node("Player").body
	level.get_node("SmallCanvas").visible = false
	level.get_node("Gym").visible = false
	var camera = level.get_node("Camera2D")
	camera.set_script(null)
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.position = BASE + Vector2(0, -70)
	camera.limit_left = -100000
	camera.limit_right = 100000
	camera.limit_top = -100000
	camera.limit_bottom = 100000
	camera.position_smoothing_enabled = false
	camera.make_current()
	camera.zoom = Vector2(0.6, 0.6)
	camera.reset_smoothing()
	camera.force_update_scroll()
	make_body("LeftPost", BASE + Vector2(-170, 100), Vector2i(20, 20), true)
	make_body("RightPost", BASE + Vector2(150, 100), Vector2i(20, 20), true)
	platform = make_body("SlingCup", BASE + Vector2(-130, 200), Vector2i(260, 16), false)
	for side in [-1, 1]:
		var stroke = Stroke.new()
		stroke.path = PackedVector2Array([BASE + Vector2(side * 160 + 0.5, 110.5), BASE + Vector2(side * 115 + 0.5, 208.5)])
		stroke.brush_width = 7
		level.add_child(stroke)
		stroke.anchors = [Stroke.find_anchor(level.world, stroke.path[0]), Stroke.find_anchor(level.world, stroke.path[-1])]
		stroke.rest_length = stroke.path[0].distance_to(stroke.path[-1])
		stroke.state = Stroke.State.ACTIVE
		rule.strokes.append(stroke)
		rule.connect_stroke(stroke, level.world)
		springs.append(stroke)
	for node_path in ["Player/Arm", "Player/Arm/Hand"]:
		var body = level.get_node(node_path).body
		arm_poses.append({"body": body, "offset": body.position - player.position, "angle": body.rotation})
	level.get_node("Player/Arm/Hand/HandControl").set_enabled(false)
	place_player()
	var hud = CanvasLayer.new()
	add_child(hud)
	label = Label.new()
	label.position = Vector2(20, 20)
	hud.add_child(label)
	await get_tree().process_frame
	camera.force_update_scroll()
	ready_for_test = true
	level.auto_step = true

func make_body(title: String, point: Vector2, size: Vector2i, fixed: bool):
	var node = BodyNode.new()
	node.name = title
	node.position = point
	node.rect_size = size
	node.is_static = fixed
	level.add_child(node)
	return level.add_body_node(node)

func place_player() -> void:
	player.rotation = 0.0
	player.angular_velocity = 0.0
	player.position = Vector2(BASE.x - player.local_com.x, platform.position.y - 1.0)
	# 根据真实主体形状的最下沿放置，不依赖美术图片的空白边界。
	var bottom: float = -INF
	for shape in player.shapes:
		bottom = maxf(bottom, shape.local_aabb().end.y)
	player.position.y = platform.position.y - bottom - 0.5
	player.linear_velocity = Vector2.ZERO
	player.awake = true
	player.sleep_timer = 0.0
	for pose in arm_poses:
		var body = pose.body
		body.position = player.position + pose.offset
		body.rotation = pose.angle
		body.angular_velocity = 0.0
		body.linear_velocity = Vector2.ZERO
		body.control_force = Vector2.ZERO
		body.control_torque = 0.0
		body.refresh_com()
		body.update_aabb()
	player.control_force = Vector2.ZERO
	player.control_torque = 0.0
	player.refresh_com()
	player.update_aabb()

func _physics_process(delta: float) -> void:
	if ready_for_test and level.auto_step:
		advance(delta)

func advance(delta: float) -> void:
	timer += delta
	if phase == "suspension":
		suspension_sag = maxf(suspension_sag, platform.position.y - BASE.y - 200)
		if timer >= 5.0:
			charge()
	elif phase == "hold" and timer >= 1.0:
		platform.is_static = false
		platform.awake = true
		platform.sleep_timer = 0.0
		phase = "flight"
		timer = 0.0
		launch_y = player.position.y
		peak_rise = 0.0
		peak_speed = 0.0
	elif phase == "flight":
		peak_speed = maxf(peak_speed, -player.linear_velocity.y)
		peak_rise = maxf(peak_rise, launch_y - player.position.y)
		if timer >= 3.0:
			shots.append({"speed": peak_speed, "rise": peak_rise, "remaining": remaining()})
			print("SLING shot=", shots.size(), " speed=", peak_speed, " rise=", peak_rise, " remaining=", remaining())
			if shots.size() < 2:
				charge()
			else:
				phase = "done"
	label.text = "Yellow sling / 7 px\nAutomatic shots: %d / 2\nSpeed: %.0f px/s   Rise: %.0f px\nSPACE: recharge + fire" % [shots.size(), peak_speed, peak_rise]

func charge() -> void:
	platform.is_static = true
	platform.rotation = 0.0
	platform.angular_velocity = 0.0
	platform.linear_velocity = Vector2.ZERO
	platform.position = BASE + Vector2(-130, 340)
	platform.refresh_com()
	platform.update_aabb()
	place_player()
	# 弹簧阻尼仍按发射时的动态托板质量配置，不重建为双静态约束。
	phase = "hold"
	timer = 0.0

func remaining() -> int:
	var result: int = 0
	for stroke in springs:
		result += stroke.cells.size()
	return result

func _unhandled_key_input(event: InputEvent) -> void:
	if ready_for_test and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE and phase == "done":
		charge()
