#固化：把 CanvasSurface 的黑色像素按连通分量拆成多个动态刚体
#运行时用 PixelWorld.add_body_node 加进世界（类比 add_child）

#region 依赖
extends Node

const InkPalette := preload("res://ink/general/src/ink_palette.gd")
const SelectionMask := preload("res://actor/canvas/src/selection_mask.gd")
const GearCenters := preload("res://actor/canvas/src/gear_centers.gd")
const GearBearings := preload("res://actor/canvas/src/gear_bearings.gd")
const YellowAxle := preload("res://ink/yellow/src/axle.gd")
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
const Stroke := preload("res://ink/yellow/src/stroke.gd")
const Rail := preload("res://ink/yellow/src/rail.gd")
const SliderPin := preload("res://ink/yellow/src/slider_pin.gd")
const SolidSnapshots := preload("res://actor/canvas/src/solid_snapshot_cache.gd")
const Traits := preload("res://ink/general/src/ink_traits.gd")
const BACKGROUND_TAG := "background_anchor_points"
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
	# 中心只是定位信息：固化时既不建轴承，也不再借中心搬动黄墨。
	# 先按块收集墨水（块级拷贝，见 _scan_block），再只扫描实体与画布相交的局部区域。
	var shape = PixelShape.new()
	var white = PixelShape.new()
	var legacy_anchors: Dictionary = {}
	# 颜色 -> 材质缓存；认色本身仍走色表，见 _scan_block。
	var color_table: Dictionary = {}
	for block in _block_rects(surface, size):
		_scan_block(surface, block, shape, white, legacy_anchors, color_table)
	var fixed_anchors: Dictionary = surface.nail_layer.nails.duplicate()
	var background_anchors: Dictionary = surface.nail_layer.background_nails.duplicate()
	var infinite_anchors: Dictionary = surface.nail_layer.infinite_nails.duplicate()
	# 黄墨在独立层中固化；落在黄墨上的钉子交给 RodLayer，避免同时钉住下方实体。
	for point: Vector2i in fixed_anchors.keys():
		if surface.rod_layer.pixels.get_pixelv(point).a > 0.5:
			fixed_anchors.erase(point)
	for point: Vector2i in background_anchors.keys():
		if surface.rod_layer.pixels.get_pixelv(point).a > 0.5:
			background_anchors.erase(point)
	for point: Vector2i in infinite_anchors.keys():
		if surface.rod_layer.pixels.get_pixelv(point).a > 0.5:
			infinite_anchors.erase(point)
	for point in legacy_anchors:
		fixed_anchors[point] = true
	var blue = surface.blue_rule()
	var blue_pixels: Dictionary = surface.blue_layer.mask.duplicate()
	if blue != null:
		blue.merge_shape(surface, shape)
	var ink_pixels: int = shape.pixel_count()
	var overlap_bodies: Array = world.world.bodies.duplicate()
	var blockers: Array = overlap_bodies.duplicate()
	# 明确安装到现有支座的草稿轮体可以覆盖该支座；不能先挖掉轴心再绑定到支座自己。
	for bearing in surface.draft_bearings:
		var path: NodePath = bearing.get("support_path", NodePath())
		if not bool(bearing.get("fixed_to_world", true)) and not path.is_empty():
			var support: Node = world.get_node_or_null(path)
			if support != null and support.get("body") != null:
				blockers.erase(support.body)
	var rejected_pixels: int = _remove_overlaps(shape, surface, blockers)

	# 连通分量 -> 刚体。静态岛再按 BLOCK_SIZE 切块：破坏代价于是以块封顶。
	# 岛的静态判据与原来一致（岛内有没有钉子像素），不能改成按块判：
	# 一块远离钉子的地形不该因为自己没钉子就掉下来。
	var spawned := 0
	var total_pixels := 0
	for island in Destruction.split(shape, 1, true):
		var island_fixed := _anchors_in_shape(island, fixed_anchors)
		var island_background := _anchors_in_shape(island, background_anchors)
		var island_infinite := _anchors_in_shape(island, infinite_anchors)
		var island_infinite_fuel := _infinite_fuel_for(surface, island_infinite)
		var is_static := not island_fixed.is_empty()
		if not is_static:
			# 没有钉子的墨是"会掉下来的一整张网"：按块切会让它自己散架，保持整块。
			if _spawn_component(world, pos, island, island_fixed, island_background,
					editor_placed_nails, false, island_infinite, not island_infinite.is_empty(),
					island_infinite_fuel):
				spawned += 1
				total_pixels += island.pixel_count()
			continue
		# 滑块安装在整个黑色连通体上。按 256px 拆开会只豁免销钉所在的一块，
		# 其余块随即裁断导轨，且仍会与导轨碰撞；机构支座必须保持一个刚体。
		var slider_support: bool = surface.rod_layer.slider_pins.any(func(pin):
			return island.get_pixel(floori(pin.source.x), floori(pin.source.y)) != 0)
		var pieces: Array = [island] if not island_background.is_empty() or slider_support else _block_pieces(island)
		for piece in pieces:
			# 块内再拆一次连通分量：多岛屿的 shape 会让 add_body_node 再造一批
			# 没有节点的刚体（存关卡时整块丢掉），所以这里自己先拆干净。
			# piece 用完即丢，允许 adopt 直接搬 chunk 对象。
			for part in Destruction.split(piece, 1, true):
				if _spawn_component(world, pos, part, island_fixed, island_background,
						editor_placed_nails, true, island_infinite, not island_infinite.is_empty(),
						island_infinite_fuel):
					spawned += 1
					total_pixels += part.pixel_count()
	# 白墨独立载体允许覆盖现有实体；断开的笔迹也共用一个速度。
	if not white.is_empty():
		var white_infinite := _anchors_in_shape(white, infinite_anchors)
		if _spawn_component(world, pos, white, _anchors_in_shape(white, fixed_anchors),
				_anchors_in_shape(white, background_anchors), editor_placed_nails, false,
				white_infinite, not white_infinite.is_empty(), false):
			spawned += 1
			total_pixels += white.pixel_count()

	if spawned == 0:
		if blue != null:
			blue.attach_wires(surface, world.world.bodies, blue_pixels)
		if ink_pixels > 0 or not blue_pixels.is_empty():
			surface.clear(false)
		print("SOLID bodies=0 pixels=0 rejected=%d" % rejected_pixels)
		return

	#固化成功后清空画布上的蓝图墨水
	if blue != null:
		var created: Array = []
		for body in world.world.bodies:
			if not overlap_bodies.has(body):
				created.append(body)
		blue.attach_wires(surface, created, blue_pixels)
	surface.clear(false, true) # 黄墨随后由 RodLayer 固化；其余墨水已经被刚体带走
	print("SOLID bodies=%d pixels=%d rejected=%d ink=%d" % [spawned, total_pixels, rejected_pixels, ink_pixels])


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


func _anchors_in_shape(shape, anchors: Dictionary) -> Dictionary:
	var result := {}
	for point: Vector2i in anchors:
		if shape.get_pixel(point.x, point.y) != 0:
			result[point] = true
	return result


func _infinite_fuel_for(surface, anchors: Dictionary) -> bool:
	for point: Vector2i in anchors:
		if surface.material_at(point.x, point.y) == InkPalette.RED.id:
			return true
	return false


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
	var cache_key := "scan:" + str(block) + SolidSnapshots.digest_of(data)
	var snapshot = SolidSnapshots.lookup(cache_key)
	var block_ink = PixelShape.new()
	var block_white = PixelShape.new()
	var block_anchors: Dictionary = {}
	if snapshot == null:
		_scan_block_pixels(data, block, block_ink, block_white, block_anchors, color_table)
		SolidSnapshots.store(cache_key, [SolidSnapshots.clone_shape(block_ink),
			SolidSnapshots.clone_shape(block_white), block_anchors.duplicate()],
			(block_ink.chunks.size() + block_white.chunks.size()) * 256 + 128)
	else:
		block_ink = SolidSnapshots.clone_shape(snapshot[0])
		block_white = SolidSnapshots.clone_shape(snapshot[1])
		block_anchors = snapshot[2]
	# 256px 块边界与 8px chunk 对齐，不会覆盖相邻块的数据。
	ink.chunks.merge(block_ink.chunks)
	white.chunks.merge(block_white.chunks)
	anchors.merge(block_anchors)


func _scan_block_pixels(data: PackedByteArray, block: Rect2i, ink, white,
		anchors: Dictionary, color_table: Dictionary) -> void:
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
	var shape_bounds: Rect2i = shape.local_aabb()
	canvas_rect = canvas_rect.intersection(Rect2(
		surface.to_global(Vector2(shape_bounds.position)), Vector2(shape_bounds.size)))
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
func _spawn_component(world, pos, part, fixed_anchors: Dictionary,
		background_anchors: Dictionary = {}, editor_placed_nails := false,
		is_static := false, infinite_anchors: Dictionary = {},
		infinite_body := false, infinite_fuel := false) -> bool:
	var local_fixed := _anchors_in_shape(part, fixed_anchors)
	var local_background := _anchors_in_shape(part, background_anchors)
	var local_infinite := _anchors_in_shape(part, infinite_anchors)
	var body_node := InkItem.new()
	body_node.name = "Ink%d" % world.get_child_count()
	body_node.is_static = is_static
	body_node.hide_nails_in_play = editor_placed_nails
	body_node.fixed_nails = PackedVector2Array(local_fixed.keys())
	body_node.background_nails = PackedVector2Array(local_background.keys())
	body_node.infinite_nails = PackedVector2Array(local_infinite.keys())
	body_node.infinite_nail_body = infinite_body or not local_infinite.is_empty()
	body_node.infinite_fuel_body = infinite_fuel
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
	if body != null:
		body_node.apply_nails(body, true)
	return body != null


#把形状抽成 R8 材质图（R 通道 = 材质 id，0 = 空）；存关卡时靠它把像素写进 .tscn。
func _material_image(shape, rect: Rect2i) -> Image:
	return SolidSnapshots.material_image(shape, rect)
#endregion


#region 钉子外观
#给每个钉子像素配一枚可见钉子，贴在刚体上；像素被破坏后它会自毁。
func _spawn_nails(world, body, anchors: Dictionary, editor_placed_nails := false,
		kind: Nail.Kind = Nail.Kind.FIXED) -> void:
	for point: Vector2i in anchors:
		var nail := Nail.new()
		world.add_child(nail)
		nail.setup(body, point, editor_placed_nails, kind)
#endregion


#region 反向：实体重采样回画布
## 只读生成参考图；绝不借用真实画布做临时采样缓冲。
func preview_image(surface, world) -> Image:
	var image := Image.create_empty(surface.canvas_size.x, surface.canvas_size.y, false, Image.FORMAT_RGBA8)
	for body in world.world.bodies:
		if body.tags.has(LIVING_TAG):
			continue
		var samples := _project_body(surface, body, Rect2i(Vector2i.ZERO, surface.canvas_size))
		for at: Vector2i in samples:
			var color = _canvas_color(surface, samples[at])
			if color != null:
				image.set_pixelv(at, color)
	image.blend_rect(surface.black_image, Rect2i(Vector2i.ZERO, surface.canvas_size), Vector2i.ZERO)
	image.blend_rect(surface.rod_layer.pixels, Rect2i(Vector2i.ZERO, surface.canvas_size), Vector2i.ZERO)
	for at in surface.blue_layer.mask:
		if _inside_canvas(surface, at):
			image.set_pixelv(at, InkPalette.BLUE.color)
	return image


## 把**落在画布里的那部分**实体像素按材质颜色重采样回墨水，再把这些像素从刚体上摘掉。
## 只算画布内的部分：画布外的那半留在世界里继续当刚体，不再跟着一起消失。
## 跳过带 LIVING_TAG 的生物实体（玩家、手、NPC）。
## 钉子随实体返回画布，保留锚点位置，供再次固化使用。
## `preserved` 中的刚体保持实体形态（齿轮/机构），其余全部墨化。
func rasterize(surface, world, preserved: Dictionary = {}) -> void:
	if world == null or surface == null:
		push_error("CanvasSolid.rasterize: 参数无效")
		return
	var canvas_rect := Rect2(surface.global_position, Vector2(surface.canvas_size))
	_restore_rail_devices_to_surface(surface, world, canvas_rect, preserved)
	GearBearings.reclaim(surface, world, Rect2i(Vector2i.ZERO, surface.canvas_size), {}, preserved)
	var targets: Array = []
	for child in world.get_children():
		#⚠️ 只认刚体节点本身：Nail 这种外观节点也带 body 属性，
		#   按 body 过滤会把它当刚体收走 —— remove_body_node 参数类型不符，直接报错/崩溃。
		if not child is PixelBody2D:
			continue
		var body = child.get("body")
		if body == null or body.tags.has(LIVING_TAG) or preserved.has(body):
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
		var needs_plan := not fully_inside
		if needs_plan:
			_collect_nail_anchors(world, body, anchors)
		_restore_body_nails_to_surface(surface, body)
		GearCenters.reclaim_body(surface, body)
		pixels += _sample_body(surface, body, plan, needs_plan, true)
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
	print("RESTORE bodies=%d pixels=%d fragments=%d preserved=%s" % [
		targets.size(), pixels, fragments, preserved.size()])


## 导轨和滑块销的功能不在黄色像素里，而在独立节点中。实体回收到画布前先把
## 这些节点的当前世界姿态转回草稿元数据，否则 F2 后只剩普通黄墨。
func _restore_rail_devices_to_surface(surface, world, canvas_rect: Rect2,
		preserved: Dictionary = {}) -> void:
	for child in world.get_children():
		if child.is_queued_for_deletion():
			continue
		if child is Rail:
			if preserved.has(child.body):
				continue
			var endpoints: PackedVector2Array = child.endpoints_world()
			if endpoints.size() != 2 or not canvas_rect.has_point(endpoints[0]) \
			or not canvas_rect.has_point(endpoints[1]):
				continue
			var a: Vector2 = surface.to_local(endpoints[0])
			var b: Vector2 = surface.to_local(endpoints[1])
			var duplicate: bool = surface.rod_layer.rails.any(func(saved):
				return Vector2(saved.a).is_equal_approx(a) and Vector2(saved.b).is_equal_approx(b))
			if not duplicate:
				surface.rod_layer.rails.append({"a": a, "b": b, "width": child.rail_width})
		elif child is SliderPin and not child.black_anchor.is_empty():
			if preserved.has(child.black_anchor.body):
				continue
			var source_world: Vector2 = Stroke.anchor_world(child.black_anchor)
			var pin_world: Vector2 = child.pin_world()
			if not canvas_rect.has_point(source_world) or not canvas_rect.has_point(pin_world):
				continue
			var source: Vector2 = surface.to_local(source_world)
			var position: Vector2 = surface.to_local(pin_world)
			var duplicate: bool = surface.rod_layer.slider_pins.any(func(saved):
				return Vector2(saved.source).is_equal_approx(source) \
					and Vector2(saved.position).is_equal_approx(position))
			if not duplicate:
				surface.rod_layer.slider_pins.append({"source": source, "position": position})


## 把框内的固化像素采样回画布并从世界实体中摘除。
## 与完整“返回画布”不同，这里保留钉子材质，供框删撤销时精确恢复到画布。
func rasterize_rect(surface, world, local_rect: Rect2i, moved_pixels: Dictionary = {},
		mask: Dictionary = {}, skip_bodies: Dictionary = {}, collected_centers: Array = [],
		collected_bearings: Array = []) -> int:
	if world == null or surface == null or local_rect.size.x <= 0 or local_rect.size.y <= 0:
		return 0
	var clipped := local_rect.intersection(Rect2i(Vector2i.ZERO, surface.canvas_size))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return 0
	if surface.blue_rule() != null:
		surface.blue_rule().reclaim(surface, clipped, skip_bodies)
	collected_bearings.append_array(GearBearings.take(surface, world, clipped, mask, skip_bodies))
	var world_rect := Rect2(surface.to_global(Vector2(clipped.position)), Vector2(clipped.size))
	var targets: Array = []
	for child in world.get_children():
		if not child is PixelBody2D:
			continue
		var body = child.get("body")
		if body == null or body.tags.has(LIVING_TAG) or skip_bodies.has(body):
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
		_restore_body_nails_to_surface(surface, body, clipped, mask)
		if plan.is_empty():
			continue
		collected_centers.append_array(GearCenters.take_in_rect(surface, world, clipped, mask, skip_bodies))
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
	var background_anchors: Dictionary = {}
	var infinite_anchors: Dictionary = {}
	var infinite_fuel := false
	var yellow_refund := 0
	for point: Vector2i in moved_pixels:
		var destination: Vector2i = point + offset
		var material: int = moved_pixels[point]
		var nail_kind: int = surface.nail_layer.kind_at(destination)
		if nail_kind == Nail.Kind.FIXED:
			anchors[destination] = true
		elif nail_kind == Nail.Kind.BACKGROUND:
			background_anchors[destination] = true
		elif nail_kind == Nail.Kind.INFINITE:
			infinite_anchors[destination] = true
			infinite_fuel = infinite_fuel or material == InkPalette.RED.id
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
		_spawn_component(world, surface.global_position, part, anchors,
			background_anchors, editor_placed_nails, false, infinite_anchors,
			not infinite_anchors.is_empty(), infinite_fuel)
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
		if child is YellowAxle and not child.is_queued_for_deletion():
			child._process(0.0)


## 画布回收属于编辑操作，留在画布外的像素必须继续作为可编辑实体存在。
## 战斗运行时会把过薄或过小的碎片降级成短命灰尘；这里若沿用该策略，
## 回收一条细线的中段会让线的一端直接消失。仅在同步碎裂期间关闭降级，
## 随后恢复运行时参数，避免改变正常碰撞/破坏策略。
func _fracture_preserving_remainders(world, body, plan: Dictionary,
		anchors: Dictionary) -> Dictionary:
	var physics = world.get("world")
	var background_points: Dictionary = body.tags.get(BACKGROUND_TAG, {}).duplicate()
	var infinite_points: Dictionary = body.tags.get(Nail.INFINITE_TAG, {}).duplicate()
	var infinite_body: bool = Traits.is_unbreakable(body)
	var infinite_fuel: bool = Traits.is_infinite_fuel(body)
	var background_layer: int = int(body.tags.get("background_original_layer", body.collision_layer))
	var background_mask: int = int(body.tags.get("background_original_mask", body.collision_mask))
	if physics == null:
		return world.fracture_pixels_and_sync(body, plan, 0.0, false, anchors)
	var old_min_thickness: float = physics.min_fragment_thickness
	var old_min_pixels: int = physics.min_fragment_pixels_downgrade
	physics.min_fragment_thickness = 0.0
	physics.min_fragment_pixels_downgrade = 0
	var result: Dictionary = world.fracture_pixels_and_sync(body, plan, 0.0, false, anchors)
	var pieces: Array = result.fragments.duplicate()
	if result.body_alive:
		pieces.append(body)
	GearCenters.observe_fracture(body, pieces)
	var runtime = world.get_node_or_null("SimulationRuntime/PhysicsStep")
	if runtime != null:
		var runtime_pieces: Array = result.fragments.duplicate()
		if result.body_alive:
			runtime_pieces.append(body)
		for piece in runtime_pieces:
			runtime._update_background_anchors(piece, background_points,
				background_layer, background_mask)
			runtime._update_infinite_nails(piece, infinite_points, infinite_body, infinite_fuel)
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
	body_node.collision_layer = int(body.tags.get("background_original_layer", body.collision_layer))
	body_node.collision_mask = int(body.tags.get("background_original_mask", body.collision_mask))
	body_node.internal_render = body.internal_render
	body_node.initial_velocity = Vector2.ZERO
	body_node.initial_angular_velocity = 0.0
	if body_node is InkItem:
		body_node.gear_centers = GearCenters.body_records(body)
		body_node.fixed_nails = PackedVector2Array(body.tags.get(ANCHOR_TAG, {}).keys())
		body_node.background_nails = PackedVector2Array(body.tags.get(BACKGROUND_TAG, {}).keys())
		body_node.infinite_nails = PackedVector2Array(body.tags.get(Nail.INFINITE_TAG, {}).keys())
		body_node.infinite_nail_body = Traits.is_unbreakable(body)
		body_node.infinite_fuel_body = Traits.is_infinite_fuel(body)
		body_node.background_collision_layer = body_node.collision_layer
		body_node.background_collision_mask = body_node.collision_mask
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
	var samples := _project_body(surface, body, local_rect, mask)
	for target: Vector2i in samples:
		var material: int = samples[target]
		moved_pixels[target] = material
		if material != InkPalette.BLUE.id:
			var color = _canvas_color(surface, material)
			if color != null:
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
		if not child._anchor_alive() and not child._try_rebind():
			child.queue_free()


func _remove_all_nails(world, body) -> void:
	for child in world.get_children():
		if child is Nail and child.get("body") == body:
			child.queue_free()


func _collect_nail_anchors(world, body, anchors: Dictionary) -> void:
	for point: Vector2i in body.tags.get(ANCHOR_TAG, {}):
		for shape in body.shapes:
			if shape.get_pixel(point.x, point.y) == 0:
				continue
			if not anchors.has(shape):
				anchors[shape] = {}
			anchors[shape][point] = true
			break


func _restore_body_nails_to_surface(surface, body, rect := Rect2i(), mask: Dictionary = {}) -> void:
	for entry in [[ANCHOR_TAG, Nail.Kind.FIXED], [BACKGROUND_TAG, Nail.Kind.BACKGROUND],
			[Nail.INFINITE_TAG, Nail.Kind.INFINITE]]:
		for point: Vector2i in body.tags.get(entry[0], {}):
			var alive := false
			for shape in body.shapes:
				if shape.get_pixel(point.x, point.y) != 0:
					alive = true
					break
			if not alive:
				continue
			var world_point: Vector2 = body.to_world(Vector2(point) + Vector2.ONE * 0.5)
			var target := Vector2i((surface.to_local(world_point) - Vector2.ONE * 0.5).round())
			if not _inside_canvas(surface, target) or (rect.has_area() and not rect.has_point(target)) \
			or not SelectionMask.contains(mask, target):
				continue
			if surface.nail_layer.add(target, entry[1]):
				if entry[1] != Nail.Kind.INFINITE:
					surface._bump_ink(surface._nail_material(entry[1]), surface.NAIL_COST, false)


## 把一个刚体**落在画布里的**像素按材质颜色写回画布，返回写进画布的像素数。
## `plan`（{shape: {Vector2i: true}}）收下画布内的全部像素（含钉子），调用方据此把它们从刚体上摘掉；
## `anchors`（同上分组）收下刚体上的全部钉子像素，供摘除后的分片判定静态。
func _sample_body(surface, body, plan: Dictionary, collect_plan := true, refund_yellow := true) -> int:
	var bounds := Rect2i(Vector2i.ZERO, surface.canvas_size)
	if collect_plan:
		# 破坏计划仍在原实体网格中计算，不能用目标采样结果反推待删除像素。
		_collect_body_plan(surface, body, bounds, plan)
	var samples := _project_body(surface, body, bounds)
	var written := 0
	for target: Vector2i in samples:
		var material: int = samples[target]
		if material == InkPalette.BLUE.id or (material == InkPalette.YELLOW.id and not refund_yellow):
			continue
		var color = _canvas_color(surface, material)
		if color == null:
			continue
		var prior: int = surface.material_at(target.x, target.y)
		if (prior == InkPalette.RED.id or prior == InkPalette.YELLOW.id) \
		and material != InkPalette.RED.id and material != InkPalette.YELLOW.id:
			continue
		surface.write_pixel(target, color)
		written += 1
	return written


func _collect_body_plan(surface, body, bounds: Rect2i, plan: Dictionary) -> void:
	for shape in body.shapes:
		for key in shape.chunks:
			var chunk = shape.chunks[key]
			var occupied: int = chunk.occ
			var base := Vector2i(PixelShape.key_x(key), PixelShape.key_y(key)) * Bits.SIZE
			while occupied != 0:
				var index: int = Bits.first_bit_index(occupied)
				occupied &= occupied - 1
				var at := base + Vector2i(index % Bits.SIZE, index >> 3)
				var target := Vector2i(surface.to_local(body.to_world(Vector2(at) + Vector2.ONE * 0.5)).floor())
				if bounds.has_point(target):
					if not plan.has(shape):
						plan[shape] = {}
					plan[shape][at] = true


## 反向采样：每个目标像素中心查询一次原始实体，旋转后不会留下正向散点投影的孔洞。
## 按形状外接框裁剪扫描范围；只输出原本有材质的格子，不膨胀边缘、不填真实镂空。
func _project_body(surface, body, bounds: Rect2i, mask: Dictionary = {}) -> Dictionary:
	var result := {}
	var clipped := bounds.intersection(Rect2i(Vector2i.ZERO, surface.canvas_size))
	for shape in body.shapes:
		var rect: Rect2i = shape.local_aabb()
		if not rect.has_area():
			continue
		var minimum := Vector2(INF, INF)
		var maximum := Vector2(-INF, -INF)
		for corner in [Vector2(rect.position), Vector2(rect.end),
			Vector2(rect.position.x, rect.end.y), Vector2(rect.end.x, rect.position.y)]:
			var point: Vector2 = surface.to_local(body.to_world(corner))
			minimum = minimum.min(point)
			maximum = maximum.max(point)
		var region := Rect2i(Vector2i(minimum.floor()), Vector2i(maximum.ceil() - minimum.floor())).intersection(clipped)
		# 仿射逆变换只算一次；内层避免反复走节点/物理变换。
		var to_body: Transform2D = Transform2D(body.rotation, body.position).affine_inverse() * surface.global_transform
		var masked := not mask.is_empty()
		var cached_key := 0
		var cached_materials := PackedByteArray()
		var cached_valid := false
		for y in range(region.position.y, region.end.y):
			# 将当前扫描行裁到旋转形状的实际四边形，避免细长斜杆的巨大空白 AABB。
			var origin: Vector2 = to_body * Vector2(0.5, y + 0.5)
			var start_x := region.position.x
			var end_x := region.end.x
			for axis in 2:
				var step: float = to_body.x[axis]
				if absf(step) < 0.0000001:
					if origin[axis] < rect.position[axis] or origin[axis] >= rect.end[axis]:
						end_x = start_x
				else:
					var first: float = (rect.position[axis] - origin[axis]) / step
					var last: float = (rect.end[axis] - origin[axis]) / step
					start_x = maxi(start_x, floori(minf(first, last)))
					end_x = mini(end_x, ceili(maxf(first, last)) + 1)
			for x in range(start_x, end_x):
				var target := Vector2i(x, y)
				if masked and not SelectionMask.contains(mask, target):
					continue
				var source := Vector2i((to_body * (Vector2(target) + Vector2.ONE * 0.5)).floor())
				var key: int = (source.x >> 3) << 32 | ((source.y >> 3) & 0xFFFFFFFF)
				if not cached_valid or key != cached_key:
					cached_valid = true
					cached_key = key
					var chunk = shape.chunks.get(key)
					cached_materials = chunk.mat if chunk != null else PackedByteArray()
				if cached_materials.is_empty():
					continue
				var material: int = cached_materials[((source.y & 7) << 3) | (source.x & 7)]
				if material != 0:
					result[target] = material
	return result


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
