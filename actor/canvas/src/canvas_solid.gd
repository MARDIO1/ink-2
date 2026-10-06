#固化：把 CanvasSurface 的黑色像素按连通分量拆成多个动态刚体
#运行时用 PixelWorld.add_body_node 加进世界（类比 add_child）

#region 依赖
extends Node

const MATERIAL_ID := 1
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")
const PixelBody2D := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
const CanvasShape := preload("res://actor/canvas/src/canvas_shape.gd")
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

	#先收集墨水，再只扫描实体与画布相交的局部区域。
	var shape = PixelShape.new()
	for y in range(size.y):
		for x in range(size.x):
			if surface.is_solid(x, y):
				shape.set_pixel(x, y, MATERIAL_ID)
	var ink_pixels: int = shape.pixel_count()
	var rejected_pixels: int = _remove_overlaps(shape, surface, world.world.bodies)

	var parts: Array = Destruction.split(shape, 1)
	if parts.is_empty():
		if ink_pixels > 0:
			surface.clear()
		print("SOLID bodies=0 pixels=0 rejected=%d" % rejected_pixels)
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
	print("SOLID bodies=%d pixels=%d rejected=%d" % [spawned, total_pixels, rejected_pixels])
#endregion


#region 重叠
func _remove_overlaps(shape, surface, bodies: Array) -> int:
	var removed: int = 0
	var canvas_rect: Rect2 = Rect2(surface.global_position, Vector2(surface.canvas_size))
	for body in bodies:
		var overlap: Rect2 = body.aabb.intersection(canvas_rect)
		if overlap.size.x <= 0.0 or overlap.size.y <= 0.0:
			continue
		var from: Vector2i = Vector2i(surface.to_local(overlap.position).floor()).max(Vector2i.ZERO)
		var to: Vector2i = Vector2i(surface.to_local(overlap.end).ceil()).min(surface.canvas_size)
		var world_start: Vector2 = surface.to_global(Vector2(from) + Vector2.ONE * 0.5)
		var row_start: Vector2 = body.to_local(world_start)
		var step_x: Vector2 = body.to_local(surface.to_global(Vector2(from) + Vector2(1.5, 0.5))) - row_start
		var step_y: Vector2 = body.to_local(surface.to_global(Vector2(from) + Vector2(0.5, 1.5))) - row_start
		for y in range(from.y, to.y):
			var local: Vector2 = row_start
			for x in range(from.x, to.x):
				if shape.get_pixel(x, y) == 0:
					local += step_x
					continue
				for body_shape in body.shapes:
					if body_shape.get_pixel(floori(local.x), floori(local.y)) != 0:
						shape.clear_pixel(x, y)
						removed += 1
						break
				local += step_x
			row_start += step_y
	return removed
#endregion


#region 生成
#把一个连通分量做成 PixelBody2D 节点并加进世界
func _spawn_component(world, pos, part) -> bool:
	var body_node = PixelBody2D.new()
	body_node.position = pos
	var shape_node = CanvasShape.new()
	shape_node.shape = part
	body_node.add_child(shape_node)
	# add_body_node 只烘焙物理体；节点仍需由场景管理生命周期。
	world.add_child(body_node)
	body_node.global_position = pos
	return world.add_body_node(body_node) != null
#endregion
