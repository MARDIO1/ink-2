#固化：把 CanvasSurface 的黑色像素按连通分量拆成多个动态刚体
#运行时用 PixelWorld.add_body_node 加进世界（类比 add_child）

#region 依赖
extends Node

const MATERIAL_ID := 1
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")
const PixelBody2D := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
const CanvasShape := preload("res://actor/canvas/canvas_shape.gd")
#endregion


#region 固化
#把画布表面固化成动态刚体节点，并把结果打印到控制台
func solidify(surface, world) -> void:
	if world == null:
		push_error("CanvasSolid.solidify: world 为空")
		return
	if surface == null or surface.black_image == null:
		push_error("CanvasSolid.solidify: surface 无效")
		return

	var pos: Vector2 = surface.global_position
	var size: Vector2i = surface.canvas_size

	#收集全部实心像素，再用引擎的连通性工具拆成分量
	var shape = PixelShape.new()
	for y in range(size.y):
		for x in range(size.x):
			if surface.is_solid(x, y):
				shape.set_pixel(x, y, MATERIAL_ID)

	var parts: Array = Destruction.split(shape, 1)
	if parts.is_empty():
		push_error("CanvasSolid.solidify: 没有可固化的黑色像素")
		return

	#每个连通分量做成一个刚体节点，add_body_node 进世界（类比 add_child）
	var spawned := 0
	var total_pixels := 0
	for part in parts:
		if _spawn_component(world, pos, part):
			spawned += 1
			total_pixels += part.pixel_count()

	#固化成功后清空画布上的蓝图墨水
	if spawned > 0:
		surface.clear()
	print("SOLID bodies=%d pixels=%d" % [spawned, total_pixels])
#endregion


#region 生成
#把一个连通分量做成 PixelBody2D 节点并加进世界
func _spawn_component(world, pos, part) -> bool:
	var body_node = PixelBody2D.new()
	body_node.position = pos
	var shape_node = CanvasShape.new()
	shape_node.shape = part
	body_node.add_child(shape_node)
	return world.add_body_node(body_node) != null
#endregion
