extends Node
## 独立于可撤销轴承的被动限位；撤销重建普通黄轴后重新绑定，不施力。
const Axle := preload("res://ink/yellow/src/axle.gd")
const Motor := preload("res://ink/blue/src/motor.gd")
@export var moving_path: NodePath
@export var support_path: NodePath
@export var start_angle := 0.0
@export var swing_angle := -0.54
var unlocked := false
var joint = null
var _base := 0.0

func _physics_process(_delta: float) -> void:
	var moving = get_node_or_null(moving_path)
	if moving == null or moving.body == null: return
	var current = null
	for child in get_parent().get_children():
		if child is Axle and child.wheel_path == moving_path and child.support_path == support_path:
			current = child.joint
			break
	if current == null: return
	if current != joint:
		joint = current
		_base = joint.movement()+moving.body.rotation
	if not unlocked:
		for child in get_parent().get_children():
			if child is Motor and child.active and child.body == moving.body and child.applied_force > 1:
				unlocked = true
				break
	var closed := _base-start_angle
	var opened := closed-swing_angle if unlocked else closed
	joint.set_limits(minf(closed,opened),maxf(closed,opened))
