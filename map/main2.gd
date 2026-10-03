#main2 物理世界：暂时用门面 PixelPhysics 承接固化，后续确定架构后再迁

#region 依赖
extends "res://addons/pixel_destruction/pixel_physics.gd"
#endregion


#region 初始化
func _ready() -> void:
	super._ready()
	#黑色墨水：对应 res://materials/black.tres
	define_material(1, Color(0, 0, 0, 1), 1.0)
	renderer()
	add_ground(Rect2(-400, 400, 1200, 40), 1)
#endregion
