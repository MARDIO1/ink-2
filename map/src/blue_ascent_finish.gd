extends "res://actor/portal/src/map_portal.gd"
## 教学地图的终点确认，沿用纸洞两秒重合反馈，不跳转到无关地图。
func _activate() -> void:
	get_parent().set_meta("blue_ascent_completed",true)
	_status = "蓝墨机关教学完成"
	queue_redraw()
