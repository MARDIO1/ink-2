#region 依赖
extends Polygon2D

@onready var control := get_node("../HandControl")
#endregion


#region 视觉同步
func _process(_delta: float) -> void:
	if control.body == null:
		return
	# 只同步图形，绝不写回刚体位姿或速度。
	global_position = control.body.com_world()
	global_rotation = control.body.rotation
#endregion
