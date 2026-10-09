extends Node2D

const BONE_COLOR := Color(0.1, 0.85, 1.0, 0.9)
const JOINT_COLOR := Color(1.0, 0.78, 0.12, 0.95)

@onready var bones: Array[Bone2D] = [
	$"../Skeleton2D/BodyHead",
	$"../Skeleton2D/BodyHead/LeftArm",
	$"../Skeleton2D/BodyHead/RightArm",
	$"../Skeleton2D/BodyHead/LeftLeg",
	$"../Skeleton2D/BodyHead/RightLeg",
]


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	for bone in bones:
		var start := to_local(bone.global_position)
		var finish := to_local(bone.to_global(Vector2(bone.length, 0.0)))
		draw_line(start, finish, BONE_COLOR, 3.0, true)
		draw_circle(start, 5.0, JOINT_COLOR)
