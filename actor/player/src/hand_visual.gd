#region 依赖
extends Polygon2D

@onready var control := get_node("../HandControl")
#endregion


#region 视觉同步
func _ready() -> void:
	# 抓取采样点与三角形尖端共用同一个坐标，避免视觉和物理漂移。
	polygon = PackedVector2Array([Vector2(-10, -7), Vector2(-10, 7), control.fingertip_offset])


func _physics_process(_delta: float) -> void:
	if control.body == null:
		return
	# 只同步图形，绝不写回刚体位姿或速度。
	global_position = control.body.com_world()
	global_rotation = control.body.rotation
#endregion
