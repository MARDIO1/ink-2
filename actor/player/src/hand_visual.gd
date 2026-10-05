#region 依赖
extends Polygon2D

@onready var control := get_node("../HandControl")
#endregion


#region 视觉同步
func _physics_process(_delta: float) -> void:
	if control.body == null:
		return
	# 场景物理优先级 20：世界求解后同步图形，绝不写回刚体位姿或速度。
	global_position = control.body.com_world()
	global_rotation = control.body.rotation
#endregion
