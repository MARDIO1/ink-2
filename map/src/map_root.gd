#地图场景的根：一个口袋，装着一堆墨水物品（InkItem）。
#⚠️ 引擎的 PixelWorld 只烘焙**直接子节点**，所以运行时必须把物品从口袋里搬到世界上；
#   编辑器里保持原样，方便你直接打开 map.tscn 摆位。

#region 依赖
@tool
extends Node2D
#endregion


#region 装载
func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var world := get_parent()
	if world == null or not world.has_method("add_body_node"):
		return
	for child in get_children():
		var keep_position: Vector2 = child.global_position
		var keep_rotation: float = child.global_rotation
		remove_child(child)
		world.add_child(child)
		child.global_position = keep_position
		child.global_rotation = keep_rotation
		#⚠️ 必须读 .body 而不是调 add_body_node：add_body_node 走 bake()，
		#   不会经过 PixelBody2D 的按需烘焙钩子 _bake_lazily，
		#   而 InkItem 正是在那个钩子里补钉子锚点的。
		if child.has_method("bake"):
			child.get("body")
#endregion
