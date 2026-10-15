#固化：把 CanvasSurface 的黑色像素按连通分量拆成多个动态刚体
#运行时用 PixelWorld.add_body_node 加进世界（类比 add_child）

#region 依赖
extends Node

const InkPalette := preload("res://ink/src/ink_palette.gd")
const SelectionMask := preload("res://actor/canvas/src/selection_mask.gd")
const GearBearing := preload("res://actor/canvas/src/gear_bearing.gd")
const ANCHOR_TAG := "static_anchor_points"
## 墨水物品所在的组；存关卡时用它区分"画出来的东西"和地形/生物。
const INK_GROUP := "ink_item"
## 生物实体标记；玩家、手、NPC 都带它，反向栅格化时跳过。
const LIVING_TAG := "living"
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const PixelChunk := preload("res://addons/pixel_destruction/core/pixel_chunk.gd")
const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")
const PixelShape2D := preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
## 世界里真正的刚体节点类型；只认它，别靠"有没有 body 属性"认刚体。
const PixelBody2D := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
const InkItem := preload("res://actor/ink_item/src/ink_item.gd")
const Nail := preload("res://actor/nail/src/nail.gd")
#endregion


#region 分块常量
## 固化分块边长（px）：静态的连通分量按它切块，每个非空块（内再按连通分量拆）出一个刚体。
##
## 破坏的代价是 O(命中刚体)：fracture 要重分解整块 + 全量连通标注 + 渲染同步，
## 打一个像素的洞也付这一块的账。整张地形做成一个刚体时这笔账没有上限
## （peak.tscn：565,857 px / 9,475 chunk / 1 形状），块大小就是它的上限。
## 同时它还是一次切断能掉下来的碎片上限（commit 走 dynamic_fragments=true）。
## 不要再调大：块的 AABB 越大，单次命中的最坏耗时越长、掉下来的碎片越夸张。
## 也不要为了块数调小：矩形数够多时引擎改用凸多边形拟合，碰撞体反而更少。
const BLOCK_SIZE := 256
#endregion


#region 固化
#把画布表面固化成动态刚体节点，并把结果打印到控制台
func solidify(surface, world, editor_placed_nails := false) -> void:
	if world == null:
		push_error("CanvasSolid.solidify: world 为空")
		return
	if surface == null or surface.black_image == null:
		push_error("CanvasSolid.solidify: surface 无效")
		return

	var pos: Vector2 = surface.global_position
	var size: Vector2i = surface.canvas_size

	# 先按块收集墨水（块级拷贝，见 _scan_block），再只扫描实体与画布相交的局部区域。
	var shape = PixelShape.new()
	var white = PixelShape.new()
	var anchors: Dictionary = {}
	# 颜色 -> 材质缓存；认色本身仍走色表，见 _scan_block。
	var color_table: Dictionary = {}
	for block in _block_rects(surface, size):
		_scan_block(surface, block, shape, white, anchors, color_table)
	var blue = surface.blue_rule()
	var blue_pixels: Dictionary = surface.blue_layer.mask.duplicate()
	if blue != null:
		blue.merge_shape(surface, shape)
	var previous: Array = world.world.bodies.duplicate()
	var ink_pixels: int = shape.pixel_count()
	var overlap_bodies: Array = world.world.bodies.duplicate()
	# 齿轮通过轴承与支座分层重叠；墨化后再固化不能把支座的轴心挖掉。
	for child in world.get_children():
		if child is GearBearing and not child.is_queued_for_deletion() and not child.yellow_anchor.is_empty():
			overlap_bodies.erase(child.yellow_anchor.body)
	var rejected_pixels: int = _remove_overlaps(shape, surface, overlap_bodies)

	# 连通分量 -> 刚体。静态岛再按 BLOCK_SIZE 切块：破坏代价于是以块封顶。
	# 岛的静态判据与原来一致（岛内有没有钉子像素），不能改成按块判：
	# 一块远离钉子的地形不该因为自己没钉子就掉下来。
	var spawned := 0
	var total_pixels := 0
	for island in Destruction.split(shape, 1, true):
		var island_anchors: Dictionary = {}
		for point: Vector2i in anchors:
			if island.get_pixel(point.x, point.y) == InkPalette.nail_material_id():
				island_anchors[point] = true
		var is_static := not island_anchors.is_empty()
		if not is_static:
			# 没有钉子的墨是"会掉下来的一整张网"：按块切会让它自己散架，保持整块。
			if _spawn_component(world, pos, island, island_anchors, editor_placed_nails, false):
				spawned += 1
				total_pixels += island.pixel_count()
			continue
		for piece in _block_pieces(island):
			# 块内再拆一次连通分量：多岛屿的 shape 会让 add_body_node 再造一批
			# 没有节点的刚体（存关卡时整块丢掉），所以这里自己先拆干净。
			# piece 用完即丢，允许 adopt 直接搬 chunk 对象。
			for part in Destruction.split(piece, 1, true):
				if _spawn_component(world, pos, part, island_anchors, editor_placed_nails, true):
					spawned += 1
					total_pixels += part.pixel_count()
	# 白墨独立载体允许覆盖现有实体；断开的笔迹也共用一个速度。
	if not white.is_empty():
		if _spawn_component(world, pos, white, {}, editor_placed_nails, false):
			spawned += 1
			total_pixels += white.pixel_count()

	if spawned == 0:
		if ink_pixels > 0:
			surface.clear()
		print("SOLID bodies=0 pixels=0 rejected=%d" % rejected_pixels)
		return

	#固化成功后清空画布上的蓝图墨水
	if blue != null:
		var created: Array = []
		for body in world.world.bodies:
			if not previous.has(body):
				created.append(body)
		blue.attach_wires(surface, created, blue_pixels)
	surface.clear(false)      # 这些墨水已经变成刚体带走了，不能还回瓶子
	print("SOLID bodies=%d pixels=%d rejected=%d" % [spawned, total_pixels, rejected_pixels])


## 画布按 BLOCK_SIZE 切出来的块（画布坐标，已裁到画布与 black_image 内）。
## 只返回与画布有内容的范围相交的块：空白块连扫描都不用做。
func _block_rects(surface, size: Vector2i) -> Array[Rect2i]:
	var out: Array[Rect2i] = []
	var full: Rect2i = Rect2i(Vector2i.ZERO, size).intersection(
		Rect2i(Vector2i.ZERO, surface.black_image.get_size()))
	var used: Rect2i = surface.black_image.get_used_rect().intersection(full)
	if not used.has_area():
		return out
	var first := used.position / BLOCK_SIZE
	var last := (used.end - Vector2i.ONE) / BLOCK_SIZE
	for by in range(first.y, last.y + 1):
		for bx in range(first.x, last.x + 1):
			var block := Rect2i(bx * BLOCK_SIZE, by * BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
			block = block.intersection(full)
			if block.has_area():
				out.append(block)
	return out


## 把一个岛按 BLOCK_SIZE 切成块形状。
## 块边界与 chunk 边界对齐（256 = 32 x 8），所以每个 chunk 整块属于一个块 ——
## 搬的是 PixelChunk 对象本身，不复制像素，也不重建位图。
func _block_pieces(island) -> Array:
	var pieces: Dictionary = {}
	for key: int in island.chunks:
		var block_key: int = ((PixelShape.key_x(key) >> 5) << 32) \
			| (PixelShape.key_y(key) >> 5 & 0xFFFFFFFF)
		var piece = pieces.get(block_key)
		if piece == null:
			piece = PixelShape.new()
			pieces[block_key] = piece
		piece.chunks[key] = island.chunks[key]
	var keys: Array = pieces.keys()
	keys.sort()
	var out: Array = []
	for key: int in keys:
		out.append(pieces[key])
	return out


## 扫一个块：非白墨写进 "ink"，白墨写进共享的 "white"，钉子像素登记到 "anchors"。
## 块只是扫描的单位：形状的 chunk 键用画布坐标，所以按块扫出来的内容与整张画布一次扫完
## 完全等价（白墨本来就跨块共用一张形状）。
##
## 像素按块级拷贝，不能逐像素 surface.material_at() + shape.set_pixel()：
## 后者每个像素过一次 Image.get_pixel 和三次字典操作，4352x1328 的画布实测 2.0 s；
## 这里一次 get_region 拿到整块 RGBA 缓冲，逐像素只读一个 alpha 字节、直接写目标
## PixelChunk，同一张画布实测 0.7 s。
##
## 形状的 chunk 键用画布坐标：固化出的形状局部坐标必须等于画布坐标 ——
## _spawn_component 的 local_aabb()、PixelShape2D.position、回收与破坏路径都按这个约定。
func _scan_block(surface, block: Rect2i, ink, white, anchors: Dictionary,
		color_table: Dictionary) -> void:
	var data: PackedByteArray = surface.black_image.get_region(block).get_data()
	var width: int = block.size.x
	var origin_x: int = block.position.x
	var origin_y: int = block.position.y
	var white_id: int = InkPalette.WHITE.id
	var nail_id: int = InkPalette.nail_material_id()
	var last_key := -1
	var last_target = null
	var chunk = null
	for ly in range(block.size.y):
		var y: int = origin_y + ly
		var bit_y: int = (y & 7) << 3
		var row: int = ly * width * 4
		for lx in range(width):
			var offset: int = row + lx * 4
			var alpha: int = data[offset + 3]
			if alpha <= 127:
				continue
			# 认色仍走色表（缓存只是省掉重复比对），否则"什么算墨水"会和画布分叉。
			var color_key: int = (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | alpha
			var material: int = color_table.get(color_key, -1)
			if material < 0:
				material = InkPalette.material_id_at_color(
					Color8(data[offset], data[offset + 1], data[offset + 2], alpha))
				color_table[color_key] = material
			if material == 0:
				continue
			var x: int = origin_x + lx
			var target = white if material == white_id else ink
			var key: int = PixelShape.make_key(x >> 3, y >> 3)
			if key != last_key or target != last_target:
				last_key = key
				last_target = target
				chunk = target.chunks.get(key)
				if chunk == null:
					chunk = PixelChunk.new()
					target.chunks[key] = chunk
			var bit: int = (x & 7) + bit_y
			chunk.occ |= 1 << bit
			chunk.mat[bit] = material
			if material == nail_id:
				anchors[Vector2i(x, y)] = true
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
## is_static 由**岛**决定（岛里有钉子像素），不是由这一个分块决定：
## 一块远离钉子的地形也必须钉住，否则分块会把它切成会掉下来的碎块。
func _spawn_component(world, pos, part, anchors: Dictionary, editor_placed_nails := false,
		is_static := false) -> bool:
	var local_anchors: Dictionary = {}
	for point: Vector2i in anchors:
		if part.get_pixel(point.x, point.y) == InkPalette.nail_material_id():
			local_anchors[point] = true
	var body_node := InkItem.new()
	body_node.name = "Ink%d" % world.get_child_count()
	body_node.is_static = is_static
	body_node.hide_nails_in_play = editor_placed_nails
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
		_spawn_nails(world, body, local_anchors, editor_placed_nails)
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
func _spawn_nails(world, body, anchors: Dictionary, editor_placed_nails := false) -> void:
	for point: Vector2i in anchors:
		var nail := Nail.new()
		world.add_child(nail)
		nail.setup(body, point, editor_placed_nails)
#endregion


#region 反向：实体重采样回画布
## 把**落在画布里的那部分**实体像素按材质颜色重采样回墨水，再把这些像素从刚体上摘掉。
## 只算画布内的部分：画布外的那半留在世界里继续当刚体，不再跟着一起消失。
## 跳过带 LIVING_TAG 的生物实体（玩家、手、NPC）。
## 钉子随实体返回画布，保留锚点位置，供再次固化使用。
## `keep_bodies = true` 只采样、不摘像素 —— 存保底 PNG 用（存图不能顺手删关卡）。
func rasterize(surface, world, keep_bodies := false) -> void:
	if world == null or surface == null:
		push_error("CanvasSolid.rasterize: 参数无效")
		return
	var canvas_rect := Rect2(surface.global_position, Vector2(surface.canvas_size))
	var targets: Array = []
	# 齿轮保持独立部件，避免墨化时与背后的支座焊成一个静态岛。
	var gears := {}
	if not keep_bodies:
		for child in world.get_children():
			if child is GearBearing and not child.is_queued_for_deletion() and not child.yellow_anchor.is_empty():
				gears[child.yellow_anchor.body] = true
	for child in world.get_children():
		#⚠️ 只认刚体节点本身：Nail 这种外观节点也带 body 属性，
		#   按 body 过滤会把它当刚体收走 —— remove_body_node 参数类型不符，直接报错/崩溃。
		if not child is PixelBody2D:
			continue
		var body = child.get("body")
		if body == null or body.tags.has(LIVING_TAG) or gears.has(body):
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
		var fully_inside := canvas_rect.encloses(body.aabb)
		var needs_plan := not keep_bodies and not fully_inside
		if needs_plan:
			_collect_nail_anchors(world, body, anchors)
		pixels += _sample_body(surface, body, plan, needs_plan, not keep_bodies)
		if keep_bodies:
			continue
		# 完整落在画布内的刚体无需走昂贵的 fracture/split；采样后整体移除即可。
		if fully_inside:
			_remove_all_nails(world, body)
			world.remove_body_node(node)
			if is_instance_valid(node):
				world.remove_child(node)
				node.queue_free()
			continue
		if plan.is_empty():
			continue
		var result: Dictionary = _fracture_preserving_remainders(world, body, plan, anchors)
		fragments += result.fragments.size()
		_free_nails(world, body)
		#整个刚体都在画布里 -> 引擎已经把它删了，节点跟着走；还剩像素的刚体留在世界里。
		if not result.body_alive and is_instance_valid(node):
			world.remove_child(node)
			node.queue_free()
	surface.refresh()
	print("RESTORE bodies=%d pixels=%d fragments=%d kept=%s" % [
		targets.size(), pixels, fragments, str(keep_bodies)])


## 把框内的固化像素采样回画布并从世界实体中摘除。
## 与完整“返回画布”不同，这里保留钉子材质，供框删撤销时精确恢复到画布。
func rasterize_rect(surface, world, local_rect: Rect2i, moved_pixels: Dictionary = {},
		mask: Dictionary = {}) -> int:
	if world == null or surface == null or local_rect.size.x <= 0 or local_rect.size.y <= 0:
		return 0
	var clipped := local_rect.intersection(Rect2i(Vector2i.ZERO, surface.canvas_size))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return 0
	if surface.blue_rule() != null:
		surface.blue_rule().reclaim(surface, clipped)
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
		_collect_nail_anchors(world, body, anchors)
		removed += _sample_body_rect(surface, body, clipped, plan, moved_pixels, mask)
		if plan.is_empty():
			continue
		var result: Dictionary = _fracture_preserving_remainders(world, body, plan, anchors)
		_free_nails(world, body)
		if not result.body_alive and is_instance_valid(node):
			world.remove_child(node)
			node.queue_free()
	return removed


## 把框选时从实体中摘下的像素在新位置重新生成实体，保持移动前的碰撞状态。
func spawn_moved_pixels(surface, world, moved_pixels: Dictionary, offset: Vector2i,
		editor_placed_nails := false) -> void:
	if moved_pixels.is_empty():
		return
	var shape := PixelShape.new()
	var white := PixelShape.new()
	var anchors: Dictionary = {}
	var yellow_refund := 0
	for point: Vector2i in moved_pixels:
		var destination: Vector2i = point + offset
		var material: int = moved_pixels[point]
		if material == InkPalette.WHITE.id:
			white.set_pixel(destination.x, destination.y, material)
		else:
			shape.set_pixel(destination.x, destination.y, material)
		if material == InkPalette.nail_material_id():
			anchors[destination] = true
		if material == InkPalette.YELLOW.id and not surface.ink_free:
			yellow_refund += 1
		# 采样只是临时的：新位置仍属于实体，不能再留一层蓝图像素。
		if material == InkPalette.YELLOW.id and surface.ink_free:
			surface.rod_layer.pixels.set_pixelv(destination, Color.TRANSPARENT)
		elif material != InkPalette.YELLOW.id:
			surface.write_pixel(destination, Color.TRANSPARENT)
	var parts: Array = Destruction.split(shape, 1)
	if not white.is_empty():
		parts.append(white)
	for part in parts:
		_spawn_component(world, surface.global_position, part, anchors, editor_placed_nails)
	if yellow_refund > 0:
		var health = surface._health_node()
		if health != null:
			health.reduce(InkPalette.YELLOW.id, yellow_refund)
	surface.refresh()


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
		# 怪物由 Monsters 场景保存。持有中的可破坏盾牌不带 living，
		# 但仍是角色附属刚体，不能另存成无美术的 InkSaved 隐形障碍。
		if body == null or body.tags.has(LIVING_TAG) or body.tags.has("map_monster"):
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
	for child in world.get_children():
		if child is GearBearing and not child.is_queued_for_deletion():
			child._process(0.0)


## 画布回收属于编辑操作，留在画布外的像素必须继续作为可编辑实体存在。
## 战斗运行时会把过薄或过小的碎片降级成短命灰尘；这里若沿用该策略，
## 回收一条细线的中段会让线的一端直接消失。仅在同步碎裂期间关闭降级，
## 随后恢复运行时参数，避免改变正常碰撞/破坏策略。
func _fracture_preserving_remainders(world, body, plan: Dictionary,
		anchors: Dictionary) -> Dictionary:
	var physics = world.get("world")
	if physics == null:
		return world.fracture_pixels_and_sync(body, plan, 0.0, false, anchors)
	var old_min_thickness: float = physics.min_fragment_thickness
	var old_min_pixels: int = physics.min_fragment_pixels_downgrade
	physics.min_fragment_thickness = 0.0
	physics.min_fragment_pixels_downgrade = 0
	var result: Dictionary = world.fracture_pixels_and_sync(body, plan, 0.0, false, anchors)
	var runtime = world.get_node_or_null("SimulationRuntime/PhysicsStep")
	if runtime != null:
		var pieces: Array = result.fragments.duplicate()
		if result.body_alive:
			pieces.append(body)
		runtime.body_fractured.emit(physics, body, pieces)
	if not result.body_alive:
		for shape in body.shapes:
			shape.owner_body = null
		body.shapes.clear()
	physics.min_fragment_thickness = old_min_thickness
	physics.min_fragment_pixels_downgrade = old_min_pixels
	return result


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
		moved_pixels: Dictionary = {}, mask: Dictionary = {}) -> int:
	var sampled := 0
	var selection_bounds := _selection_bounds_in_body(surface, body, local_rect)
	for shape in body.shapes:
		# 只检查框选区域映射到刚体局部坐标后的范围；大型地面不再因一个小框而整块扫描。
		var rect: Rect2i = shape.local_aabb().intersection(selection_bounds)
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var material: int = shape.get_pixel(x, y)
				if material == 0:
					continue
				var shape_pixel := Vector2i(x, y)
				var world_point: Vector2 = body.to_world(Vector2(x + 0.5, y + 0.5))
				var local: Vector2 = surface.to_local(world_point)
				var target := Vector2i((local - Vector2(0.5, 0.5)).round())
				if not local_rect.has_point(target):
					continue
				if not SelectionMask.contains(mask, target):
					continue
				if not plan.has(shape):
					plan[shape] = {}
				plan[shape][shape_pixel] = true
				moved_pixels[target] = material
				if material == InkPalette.BLUE.id:
					sampled += 1
					continue
				var color: Color = surface.nail_color() if material == InkPalette.nail_material_id() \
					else InkPalette.color_for_material_id(material)
				if color.a > 0.0:
					surface.write_pixel(target, color)
				sampled += 1
	return sampled


func _selection_bounds_in_body(surface, body, local_rect: Rect2i) -> Rect2i:
	var corners := [
		Vector2(local_rect.position),
		Vector2(local_rect.end.x, local_rect.position.y),
		Vector2(local_rect.position.x, local_rect.end.y),
		Vector2(local_rect.end),
	]
	var first: Vector2 = body.to_local(surface.to_global(corners[0]))
	var minimum := first
	var maximum := first
	for i in range(1, corners.size()):
		var point: Vector2 = body.to_local(surface.to_global(corners[i]))
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	var from := Vector2i(floori(minimum.x), floori(minimum.y)) - Vector2i.ONE
	var to := Vector2i(ceili(maximum.x), ceili(maximum.y)) + Vector2i.ONE
	return Rect2i(from, to - from)


## 删掉挂在这个刚体上、锚点像素已经被摘掉的钉子外观。
## Nail 是世界的子节点而不是刚体的子节点，刚体没了它不会跟着没。
func _free_nails(world, body) -> void:
	for child in world.get_children():
		if not child is Nail or child.get("body") != body:
			continue
		var point: Vector2i = child.get("pixel")
		var alive := false
		for shape in body.shapes:
			if shape.get_pixel(point.x, point.y) == InkPalette.nail_material_id():
				alive = true
				break
		if not alive:
			child.queue_free()


func _remove_all_nails(world, body) -> void:
	for child in world.get_children():
		if child is Nail and child.get("body") == body:
			child.queue_free()


func _collect_nail_anchors(world, body, anchors: Dictionary) -> void:
	for child in world.get_children():
		if not child is Nail or child.get("body") != body:
			continue
		var point: Vector2i = child.get("pixel")
		for shape in body.shapes:
			if shape.get_pixel(point.x, point.y) != InkPalette.nail_material_id():
				continue
			if not anchors.has(shape):
				anchors[shape] = {}
			anchors[shape][point] = true
			break


## 把一个刚体**落在画布里的**像素按材质颜色写回画布，返回写进画布的像素数。
## `plan`（{shape: {Vector2i: true}}）收下画布内的全部像素（含钉子），调用方据此把它们从刚体上摘掉；
## `anchors`（同上分组）收下刚体上的全部钉子像素，供摘除后的分片判定静态。
func _sample_body(surface, body, plan: Dictionary, collect_plan := true, refund_yellow := true) -> int:
	var written := 0
	for shape in body.shapes:
		# 按占用 chunk 遍历真实像素，跳过 AABB 内的大量空白。
		for key in shape.chunks:
			var chunk = shape.chunks[key]
			var occupied: int = chunk.occ
			var base_x: int = PixelShape.key_x(key) * Bits.SIZE
			var base_y: int = PixelShape.key_y(key) * Bits.SIZE
			while occupied != 0:
				var index: int = Bits.first_bit_index(occupied)
				occupied &= occupied - 1
				var x: int = base_x + index % Bits.SIZE
				var y: int = base_y + (index >> 3)
				var material: int = chunk.mat[index]
				if material == InkPalette.YELLOW.id and not refund_yellow:
					continue
				var world_point: Vector2 = body.to_world(Vector2(x + 0.5, y + 0.5))
				var local: Vector2 = surface.to_local(world_point)
				var target := Vector2i((local - Vector2(0.5, 0.5)).round())
				#画布外的像素不算：留在世界里继续当刚体，不从这块刚体上摘。
				if not _inside_canvas(surface, target):
					continue
				if collect_plan:
					if not plan.has(shape):
						plan[shape] = {}
					plan[shape][Vector2i(x, y)] = true
				if material == InkPalette.BLUE.id:
					continue
				# 钉子和墨水一起返回蓝图，再次固化时仍作为锚点。
				var color = _canvas_color(surface, material)
				if color == null:
					continue
				# 多个实体落在同一画布像素时，先写入的红/黄不能被后来的普通墨盖掉。
				var prior: int = surface.material_at(target.x, target.y)
				if (prior == InkPalette.RED.id or prior == InkPalette.YELLOW.id) \
				and material != InkPalette.RED.id and material != InkPalette.YELLOW.id:
					continue
				surface.write_pixel(target, color)
				written += 1
	return written


## 画布像素坐标是否在画布范围内（与 CanvasSurface.write_pixel 的收边一致）。
func _inside_canvas(surface, pixel: Vector2i) -> bool:
	return (pixel.x >= 0 and pixel.y >= 0
		and pixel.x < surface.canvas_size.x and pixel.y < surface.canvas_size.y)


## 材质到画布颜色的映射；钉子保留，未知材质返回 null。
func _canvas_color(surface, material: int):
	if material == InkPalette.nail_material_id():
		return surface.nail_color()
	var color: Color = InkPalette.color_for_material_id(material)
	return color if color.a > 0.0 else null
#endregion
