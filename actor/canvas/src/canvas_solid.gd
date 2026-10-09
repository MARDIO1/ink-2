#固化：把 CanvasSurface 的黑色像素按连通分量拆成多个动态刚体
#运行时用 PixelWorld.add_body_node 加进世界（类比 add_child）

#region 依赖
extends Node

const InkPalette := preload("res://Ink/src/ink_palette.gd")
const ANCHOR_TAG := "static_anchor_points"
## 墨水物品所在的组；存关卡时用它区分"画出来的东西"和地形/生物。
const INK_GROUP := "ink_item"
## 生物实体标记；玩家、手、NPC 都带它，反向栅格化时跳过。
const LIVING_TAG := "living"
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")
const PixelShape2D := preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
## 世界里真正的刚体节点类型；只认它，别靠"有没有 body 属性"认刚体。
const PixelBody2D := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
const InkItem := preload("res://actor/ink_item/src/ink_item.gd")
const Nail := preload("res://actor/nail/src/nail.gd")
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
	var anchors: Dictionary = {}
	for y in range(size.y):
		for x in range(size.x):
			var material: int = surface.material_at(x, y)
			if material != 0:
				shape.set_pixel(x, y, material)
				if material == InkPalette.nail_material_id():
					anchors[Vector2i(x, y)] = true
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
		if _spawn_component(world, pos, part, anchors):
			spawned += 1
			total_pixels += part.pixel_count()

	#固化成功后清空画布上的蓝图墨水
	if spawned > 0:
		surface.clear(false)      # 这些墨水已经变成刚体带走了，不能还回瓶子
	print("SOLID bodies=%d pixels=%d rejected=%d" % [spawned, total_pixels, rejected_pixels])
#endregion


#region 重叠
func _remove_overlaps(shape, surface, bodies: Array) -> int:
	var removed: int = 0
	var canvas_rect: Rect2 = Rect2(surface.global_position, Vector2(surface.canvas_size))
	for body in bodies:
		# 玩家、手和小怪只是暂时站在画布上，不是关卡固体的一部分。
		# 若在这里按重叠挖洞，固化时会把整块墨水切成碎片。
		if body == null or body.tags.has(LIVING_TAG):
			continue
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
#把一个连通分量做成墨水物品节点并加进世界。
#⚠️ 形状用 `PixelShape2D(source = PAINT)` + 内嵌 Image，而**不是**自造的 CanvasShape：
#   后者装的是 RefCounted 的 PixelShape，PackedScene 存不下来 ——
#   而 F5 是直接 pack 整个关卡，所以运行时就必须是"能存"的形态。
func _spawn_component(world, pos, part, anchors: Dictionary) -> bool:
	var local_anchors: Dictionary = {}
	for point: Vector2i in anchors:
		if part.get_pixel(point.x, point.y) == InkPalette.nail_material_id():
			local_anchors[point] = true
	var body_node := InkItem.new()
	body_node.name = "Ink%d" % world.get_child_count()
	body_node.is_static = not local_anchors.is_empty()
	body_node.add_to_group(INK_GROUP, true)
	var rect: Rect2i = part.local_aabb()
	var shape_node := PixelShape2D.new()
	shape_node.position = Vector2(rect.position)
	shape_node.source = PixelShape2D.Source.PAINT
	shape_node.paint = _material_image(part, rect)
	body_node.add_child(shape_node)
	# add_body_node 只烘焙物理体；节点仍需由场景管理生命周期。
	world.add_child(body_node)
	body_node.position = pos
	# owner 决定 pack 整个关卡时谁会被带上；运行时新建的节点默认是 null，会**被漏掉**。
	body_node.owner = world
	shape_node.owner = world
	var body = world.add_body_node(body_node)
	if body != null and not local_anchors.is_empty():
		body.tags[ANCHOR_TAG] = local_anchors
		_spawn_nails(world, body, local_anchors)
	return body != null


#把形状抽成 R8 材质图（R 通道 = 材质 id，0 = 空）；存关卡时靠它把像素写进 .tscn。
func _material_image(shape, rect: Rect2i) -> Image:
	var image := Image.create_empty(rect.size.x, rect.size.y, false, Image.FORMAT_R8)
	for y in range(rect.size.y):
		for x in range(rect.size.x):
			var material: int = shape.get_pixel(rect.position.x + x, rect.position.y + y)
			if material != 0:
				image.set_pixel(x, y, Color8(material, 0, 0, 255))
	return image
#endregion


#region 钉子外观
#给每个钉子像素配一枚可见钉子，贴在刚体上；像素被破坏后它会自毁。
func _spawn_nails(world, body, anchors: Dictionary) -> void:
	for point: Vector2i in anchors:
		var nail := Nail.new()
		world.add_child(nail)
		nail.setup(body, point)
#endregion


#region 反向：实体重采样回画布
## 把**落在画布里的那部分**实体像素按材质颜色重采样回墨水，再把这些像素从刚体上摘掉。
## 只算画布内的部分：画布外的那半留在世界里继续当刚体，不再跟着一起消失。
## 跳过带 LIVING_TAG 的生物实体（玩家、手、NPC）。
## ⚠️ 钉子不回收：材质 4 的像素不回画布；锚点像素被摘掉的钉子外观跟着丢，留下来的还钉在刚体上。
## `keep_bodies = true` 只采样、不摘像素 —— 存保底 PNG 用（存图不能顺手删关卡）。
func rasterize(surface, world, keep_bodies := false) -> void:
	if world == null or surface == null:
		push_error("CanvasSolid.rasterize: 参数无效")
		return
	var canvas_rect := Rect2(surface.global_position, Vector2(surface.canvas_size))
	var targets: Array = []
	for child in world.get_children():
		#⚠️ 只认刚体节点本身：Nail 这种外观节点也带 body 属性，
		#   按 body 过滤会把它当刚体收走 —— remove_body_node 参数类型不符，直接报错/崩溃。
		if not child is PixelBody2D:
			continue
		var body = child.get("body")
		if body == null or body.tags.has(LIVING_TAG):
			continue
		if body.aabb.intersects(canvas_rect):
			targets.append(child)
	var pixels := 0
	var fragments := 0
	for node in targets:
		var body = node.get("body")
		#plan 收下落在画布里的那些像素（{shape: {Vector2i: true}}，含写不回画布的钉子）；
		#anchors 收下刚体上的钉子像素，摘完由引擎决定残留分片还算不算静态。
		var plan: Dictionary = {}
		var anchors: Dictionary = {}
		pixels += _sample_body(surface, body, plan, anchors)
		if keep_bodies or plan.is_empty():
			continue
		var result: Dictionary = world.fracture_pixels_and_sync(body, plan, 0.0, false, anchors)
		fragments += result.fragments.size()
		_free_nails(world, body)
		#整个刚体都在画布里 -> 引擎已经把它删了，节点跟着走；还剩像素的刚体留在世界里。
		if not result.body_alive and is_instance_valid(node):
			node.queue_free()
	surface.refresh()
	print("RESTORE bodies=%d pixels=%d fragments=%d kept=%s" % [
		targets.size(), pixels, fragments, str(keep_bodies)])


## 把框内的固化像素采样回画布并从世界实体中摘除。
## 与完整“返回画布”不同，这里保留钉子材质，供框删撤销时精确恢复到画布。
func rasterize_rect(surface, world, local_rect: Rect2i) -> int:
	if world == null or surface == null or local_rect.size.x <= 0 or local_rect.size.y <= 0:
		return 0
	var clipped := local_rect.intersection(Rect2i(Vector2i.ZERO, surface.canvas_size))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return 0
	var world_rect := Rect2(surface.to_global(Vector2(clipped.position)), Vector2(clipped.size))
	var targets: Array = []
	for child in world.get_children():
		if not child is PixelBody2D:
			continue
		var body = child.get("body")
		if body == null or body.tags.has(LIVING_TAG):
			continue
		if body.aabb.intersects(world_rect):
			targets.append(child)
	var removed := 0
	for node in targets:
		var body = node.get("body")
		var plan: Dictionary = {}
		var anchors: Dictionary = {}
		removed += _sample_body_rect(surface, body, clipped, plan, anchors)
		if plan.is_empty():
			continue
		var result: Dictionary = world.fracture_pixels_and_sync(body, plan, 0.0, false, anchors)
		_free_nails(world, body)
		if not result.body_alive and is_instance_valid(node):
			node.queue_free()
	return removed


## 把运行时 PBody 的当前像素形状写回可被 PackedScene 保存的节点。
## 破坏/框删只会修改 RefCounted 物理体；若不做这一步，重载场景时仍会从
## PixelShape2D 的旧 paint 图烘焙，已删除的像素便会重新出现。
func sync_serializable_bodies(world) -> void:
	if world == null or world.world == null:
		return
	world.realign_body_nodes()
	var live_bodies: Dictionary = {}
	for body in world.world.bodies:
		live_bodies[body] = true

	# 已被物理世界完全删除的旧描述节点不能留给 PackedScene。
	for child in world.get_children().duplicate():
		if not child is PixelBody2D:
			continue
		var old_body = child.get("body")
		if old_body != null and not old_body.tags.has(LIVING_TAG) and not live_bodies.has(old_body):
			child.free()

	world.realign_body_nodes()
	for index in world.world.bodies.size():
		var body = world.world.bodies[index]
		if body == null or body.tags.has(LIVING_TAG):
			continue
		var body_node = world._body_nodes[index] if index < world._body_nodes.size() else null
		if body_node == null or not is_instance_valid(body_node):
			body_node = InkItem.new()
			body_node.name = "InkSaved%d" % index
			body_node.body = body
			body_node.add_to_group(INK_GROUP, true)
			world.add_child(body_node)
			body_node.owner = world
			world._body_nodes[index] = body_node
		_write_body_node(body_node, body, world)
	world.realign_body_nodes()


func _write_body_node(body_node, body, owner: Node) -> void:
	body_node.position = body.position
	body_node.rotation = body.rotation
	body_node.scale = Vector2.ONE
	body_node.is_static = body.is_static
	body_node.gravity_scale = body.gravity_scale
	body_node.collision_layer = body.collision_layer
	body_node.collision_mask = body.collision_mask
	body_node.internal_render = body.internal_render
	body_node.initial_velocity = Vector2.ZERO
	body_node.initial_angular_velocity = 0.0
	for child in body_node.get_children().duplicate():
		if child is PixelShape2D:
			child.free()
	for shape in body.shapes:
		var rect: Rect2i = shape.local_aabb()
		if rect.size.x <= 0 or rect.size.y <= 0:
			continue
		var shape_node := PixelShape2D.new()
		shape_node.position = Vector2(rect.position)
		shape_node.source = PixelShape2D.Source.PAINT
		shape_node.paint = _material_image(shape, rect)
		body_node.add_child(shape_node)
		shape_node.owner = owner


func _sample_body_rect(surface, body, local_rect: Rect2i, plan: Dictionary,
		anchors: Dictionary) -> int:
	var sampled := 0
	for shape in body.shapes:
		var rect: Rect2i = shape.local_aabb()
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var material: int = shape.get_pixel(x, y)
				if material == 0:
					continue
				var shape_pixel := Vector2i(x, y)
				if material == InkPalette.nail_material_id():
					if not anchors.has(shape):
						anchors[shape] = {}
					anchors[shape][shape_pixel] = true
				var world_point: Vector2 = body.to_world(Vector2(x + 0.5, y + 0.5))
				var local: Vector2 = surface.to_local(world_point)
				var target := Vector2i((local - Vector2(0.5, 0.5)).round())
				if not local_rect.has_point(target):
					continue
				if not plan.has(shape):
					plan[shape] = {}
				plan[shape][shape_pixel] = true
				var color: Color = surface.nail_color() if material == InkPalette.nail_material_id() \
					else InkPalette.color_for_material_id(material)
				if color.a > 0.0:
					surface.write_pixel(target, color)
				sampled += 1
	return sampled


## 删掉挂在这个刚体上、锚点像素已经被摘掉的钉子外观。
## Nail 是世界的子节点而不是刚体的子节点，刚体没了它不会跟着没。
func _free_nails(world, body) -> void:
	var alive: Dictionary = {}
	for shape in body.shapes:
		var rect: Rect2i = shape.local_aabb()
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				if shape.get_pixel(x, y) == InkPalette.nail_material_id():
					alive[Vector2i(x, y)] = true
	for child in world.get_children():
		if child is Nail and child.get("body") == body and not alive.has(child.get("pixel")):
			child.queue_free()


## 把一个刚体**落在画布里的**像素按材质颜色写回画布，返回写进画布的像素数。
## `plan`（{shape: {Vector2i: true}}）收下画布内的全部像素（含钉子），调用方据此把它们从刚体上摘掉；
## `anchors`（同上分组）收下刚体上的全部钉子像素，供摘除后的分片判定静态。
func _sample_body(surface, body, plan: Dictionary, anchors: Dictionary) -> int:
	var written := 0
	for shape in body.shapes:
		var rect: Rect2i = shape.local_aabb()
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var material: int = shape.get_pixel(x, y)
				if material == 0:
					continue
				if material == InkPalette.nail_material_id():
					if not anchors.has(shape):
						anchors[shape] = {}
					anchors[shape][Vector2i(x, y)] = true
				var world_point: Vector2 = body.to_world(Vector2(x + 0.5, y + 0.5))
				var local: Vector2 = surface.to_local(world_point)
				var target := Vector2i((local - Vector2(0.5, 0.5)).round())
				#画布外的像素不算：留在世界里继续当刚体，不从这块刚体上摘。
				if not _inside_canvas(surface, target):
					continue
				if not plan.has(shape):
					plan[shape] = {}
				plan[shape][Vector2i(x, y)] = true
				#钉子不回收进画布（color = null），但画布内的那部分一样从刚体上摘走。
				var color = _canvas_color(surface, material)
				if color == null:
					continue
				surface.write_pixel(target, color)
				written += 1
	return written


## 画布像素坐标是否在画布范围内（与 CanvasSurface.write_pixel 的收边一致）。
func _inside_canvas(surface, pixel: Vector2i) -> bool:
	return (pixel.x >= 0 and pixel.y >= 0
		and pixel.x < surface.canvas_size.x and pixel.y < surface.canvas_size.y)


## 材质到画布颜色的映射；null 表示该材质不回到画布（钉子不回收）。
func _canvas_color(surface, material: int):
	var color: Color = InkPalette.color_for_material_id(material)
	return color if color.a > 0.0 else null
#endregion
