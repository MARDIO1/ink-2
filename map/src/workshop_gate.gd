extends Node
## 第一关机关：可破坏触发物驱动真实 PixelWorld 滑轨门；不移动玩家、不用隐形墙。

const Joint := preload("res://addons/pixel_destruction/physics/joint.gd")
@export var mode := 0 # 0：支撑断裂；1：杠杆托盘配重。
@export var door_path: NodePath
@export var support_path: NodePath
@export var lever_path: NodePath
@export var lever_pivot := Vector2.ZERO
@export var load_zone := Rect2()
@export var minimum_load_mass := 550.0
@export var opening_height := 180.0
@export var opened := false
var _host: Node
var _door: Node
var _support: Node
var _lever: Node
var _slider = null
var _hinge = null
var _initial_support_pixels := 0
var _lift := 0.0
var _initialized := false

func _ready() -> void:
	process_physics_priority = 5
	_host = get_parent()
	_setup.call_deferred()

func _setup() -> void:
	_door = get_node_or_null(door_path)
	_support = get_node_or_null(support_path)
	_lever = get_node_or_null(lever_path)
	if _door == null or _door.body == null:
		return
	_slider = _host.world.add_slider(_door.body, null, _door.body.com_world(), Vector2.UP)
	_slider.limits_enabled = true
	_slider.min_limit = 0.0
	_slider.max_limit = opening_height
	_slider.set_motor_target(0.0, 80000000.0, 60000.0, 12000.0)
	if _support != null:
		_initial_support_pixels = _pixels(_support)
	if _lever != null and _lever.body != null:
		_hinge = _host.world.add_hinge(_lever.body, null, lever_pivot)
		_hinge.limits_enabled = true
		_hinge.min_limit = -0.32
		_hinge.max_limit = 0.16
	_initialized = true

func _physics_process(delta: float) -> void:
	if not _initialized or _slider == null or not is_instance_valid(_host):
		return
	var creative := _host.get_node_or_null("Creative")
	if creative != null and creative.get("active") == true:
		return
	if not is_instance_valid(_door) or _door.body == null or not _host.world.bodies.has(_door.body):
		return # 门本身也能直接打碎。
	if not opened:
		if mode == 0:
			if _initial_support_pixels > 0 and _pixels(_support) < _initial_support_pixels * 0.95:
				opened = true
		else:
			var load := load_mass()
			if load >= minimum_load_mass and is_instance_valid(_lever) and _lever.body != null \
			and (_lever.body.rotation < -0.04 or load >= minimum_load_mass * 2.0):
				opened = true
	if opened:
		_lift = minf(_lift + delta * 90.0, opening_height)
	_slider.set_motor_target(_lift, 80000000.0, 60000.0, 12000.0)

func load_mass() -> float:
	var total := 0.0
	for body in _host.world.bodies:
		if body.is_static or body == _door.body or (is_instance_valid(_lever) and body == _lever.body) \
		or body.tags.has("living") or body.tags.has("white_ink"):
			continue
		if body.aabb.intersects(load_zone):
			total += body.mass
	return total

func _pixels(node) -> int:
	if not is_instance_valid(node) or node.body == null or not _host.world.bodies.has(node.body):
		return 0
	var count := 0
	for shape in node.body.shapes:
		count += shape.pixel_count()
	return count

func _exit_tree() -> void:
	if is_instance_valid(_host) and _host.get("world") != null:
		for joint in [_slider, _hinge]:
			if joint != null and _host.world.joints.has(joint):
				_host.world.remove_joint(joint)
	_slider = null
	_hinge = null
