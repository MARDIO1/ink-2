extends Node2D
## 原生滑轨约束和可见滑块；不供能、不施力、不改写活动体位置。
const Motor := preload("res://ink/blue/src/motor.gd")
@export var moving_path: NodePath
@export var guide_path: NodePath
@export var axis := Vector2.UP
@export var pin_position := Vector2.ZERO
@export var travel := 228.0
@export var power_lock := false
var unlocked := false
var joint = null
var moving: Node
var guide: Node
var origin := Vector2.ZERO
var pin_local := Vector2.ZERO
var _host: Node

func _ready() -> void:
	z_index = 10
	_setup.call_deferred()

func _setup() -> void:
	_host = get_parent()
	if _host.get("body_bake_pending") == true:
		await Signal(_host,&"body_bake_completed")
	moving = get_node_or_null(moving_path)
	guide = get_node_or_null(guide_path)
	if moving == null or guide == null or moving.body == null or guide.body == null: return
	origin = moving.body.position
	pin_local = moving.body.to_local(pin_position)
	joint = _host.world.add_slider(guide.body,moving.body,pin_position,axis.normalized())
	joint.contacts_enabled = false
	joint.limits_enabled = true
	unlocked = not power_lock
	joint.min_limit = 0.0
	joint.max_limit = travel if unlocked else 0.0
	queue_redraw()

func displacement() -> float:
	return (moving.body.position-origin).dot(axis.normalized()) if is_instance_valid(moving) and moving.body != null else 0.0

func _physics_process(_delta: float) -> void:
	if joint != null and not unlocked:
		for child in get_parent().get_children():
			if child is Motor and child.active and child.body == moving.body and child.applied_force > 1:
				unlocked = true
				joint.min_limit = 0.0
				joint.max_limit = travel
				break
	queue_redraw()

func _draw() -> void:
	if not is_instance_valid(moving) or moving.body == null: return
	var point: Vector2 = moving.body.to_world(pin_local)
	draw_rect(Rect2(point-Vector2(5,5),Vector2(10,10)),Color(0.12,0.10,0.03))
	draw_rect(Rect2(point-Vector2(3,3),Vector2(6,6)),Color("f7be13"))

func _exit_tree() -> void:
	if joint != null and is_instance_valid(_host) and _host.world != null and _host.world.joints.has(joint):
		_host.world.remove_joint(joint)
