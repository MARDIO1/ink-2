#固化：把 CanvasSurface 的黑色像素按连通分量拆成多个动态刚体
#引擎集成暂时用门面（main2 的根），后续确定节点/门面架构后再迁

#region 依赖
extends Node

const MATERIAL_ID := 1
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")
#endregion


#region 固化
#把画布表面固化成动态刚体：先按 4 邻域连通性拆分量，每个分量单独一个刚体
func solidify(surface, physics) -> void:
	if physics == null:
		push_error("CanvasSolid.solidify: physics 为空")
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

	#每个连通分量单独 spawn，避免不连通区域被刚性焊死成一块
	var spawned := 0
	var total_pixels := 0
	for part in parts:
		var body = physics.spawn_shape(pos, part)
		if body != null:
			spawned += 1
			total_pixels += part.pixel_count()

	print("SOLID bodies=%d pixels=%d" % [spawned, total_pixels])
#endregion
