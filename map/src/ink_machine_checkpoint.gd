extends Node2D
## 只观察真实供能/运动，不向蓝墨注入能量。完成后锁存，避免燃料耗尽软锁。
@export_enum("齿轮传动", "配重杠杆", "动力升降") var kind := 0
@export var moving_path: NodePath
@export var motor_path: NodePath
@export var gate_path: NodePath
@export var travel := 300.0
var completed := false
var joint = null
var _moving: Node
var _gate: Node
var _origin := Vector2.ZERO
var _rotation_total := 0.0
var _powered := false
var _powered_start_angle := 0.0
var _lift := 0.0

func _ready() -> void:
	_setup.call_deferred()

func _setup() -> void:
	var level := get_parent()
	if level != null and level.get("body_bake_pending") == true:
		await Signal(level, &"body_bake_completed")
	_moving = get_node_or_null(moving_path)
	if _moving == null or _moving.body == null:
		return
	_origin = _moving.body.position
	if kind == 2:
		# 本项目桥接层中，此轴的平台上升对应负滑轨位移。
		joint = get_parent().world.add_slider(_moving.body,null,_moving.body.com_world(),Vector2.DOWN)
		joint.limits_enabled = true
		joint.min_limit = 0
		joint.max_limit = 0 # 蓝墨脉冲释放预紧弹簧的锁销。
	elif not gate_path.is_empty():
		_gate = get_node_or_null(gate_path)
		if _gate == null or _gate.body == null:
			return
		joint = get_parent().world.add_slider(_gate.body,null,_gate.body.com_world(),Vector2.DOWN)
		joint.limits_enabled = true
		joint.min_limit = -travel
		joint.max_limit = 0
		joint.set_motor_target(0,80000000,60000,12000)

func _physics_process(delta: float) -> void:
	if not is_instance_valid(_moving) or _moving.body == null:
		return
	var creative := get_parent().get_node_or_null("Creative")
	if creative != null and creative.active:
		return
	var motor := get_node_or_null(motor_path) if not motor_path.is_empty() else null
	if not _powered and motor != null and motor.used_power > 0:
		_powered_start_angle = _moving.body.rotation
	_powered = _powered or (motor != null and motor.used_power > 0)
	if kind == 0:
		_rotation_total = absf(wrapf(_moving.body.rotation-_powered_start_angle,-PI,PI)) if _powered else 0.0
		completed = completed or (_powered and _rotation_total > 0.01)
	elif kind == 1:
		# 负角对应左端下压；允许推来的怪物当配重，但不算主角本体。
		var loaded := false
		for body in get_parent().world.bodies:
			if body == _moving.body or body.is_static:
				continue
			if body.tags.has("living") and not body.tags.has("map_monster"):
				continue
			if body.mass > 350 and body.aabb.intersects(Rect2(_origin+Vector2(-20,-100),Vector2(130,130))):
				loaded = true
		completed = completed or (loaded and _moving.body.rotation < -0.09)
	else:
		if _powered and joint != null and joint.is_active():
			joint.min_limit = -travel
			joint.max_limit = -_lift
		completed = completed or (_powered and _origin.y-_moving.body.position.y > travel*0.8)
		if completed and joint != null and joint.is_active():
			# 到位后机械止回，不靠持续燃烧红墨悬空。
			_lift = minf(travel,maxf(_lift,_origin.y-_moving.body.position.y))
			joint.max_limit = -_lift
	if completed and kind != 2 and joint != null and joint.is_active():
		_lift = minf(travel,_lift+90*delta)
		joint.set_motor_target(-_lift,80000000,60000,12000)
	queue_redraw()

func _draw() -> void:
	draw_circle(Vector2.ZERO,9,Color(0.1,0.65,0.25) if completed else Color(0.25,0.25,0.25))
	draw_arc(Vector2.ZERO,11,0,TAU,32,Color.BLACK,2)

func _exit_tree() -> void:
	if joint != null and joint.is_active():
		joint.remove()
