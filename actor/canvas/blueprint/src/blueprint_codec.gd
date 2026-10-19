extends RefCounted
## 只读选区采集、独立部件重建，以及一次性提交的绘画事务。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Mask := preload("res://actor/canvas/src/selection_mask.gd")
const Format := preload("res://blueprint/src/blueprint_format.gd")
const Bearing := preload("res://ink/yellow/src/axle.gd")
const Hinge := preload("res://ink/yellow/src/hinge.gd")
const Stroke := preload("res://ink/yellow/src/stroke.gd")
const Motor := preload("res://ink/blue/src/motor.gd")
const Wire := preload("res://ink/blue/src/wire_layer.gd")
const InkItem := preload("res://actor/ink_item/src/ink_item.gd")
const ShapeNode := preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
const Nail := preload("res://actor/nail/src/nail.gd")
const Traits := preload("res://ink/general/src/ink_traits.gd")
const Rail := preload("res://ink/yellow/src/rail.gd")
const SliderPin := preload("res://ink/yellow/src/slider_pin.gd")
const GearCenters := preload("res://actor/canvas/src/gear_centers.gd")

static func vec(value: Array) -> Vector2:
	return Vector2(value[0], value[1])

static func xy(value: Vector2) -> Array:
	return [value.x, value.y]


static func _center_payload(record: Dictionary, origin: Vector2,
		canvas_point: Vector2 = Vector2.INF) -> Dictionary:
	var point := GearCenters.position_of(record) if canvas_point == Vector2.INF else canvas_point
	return {"position": xy(point - origin), "radius": GearCenters.radius_of(record),
		"material": GearCenters.material_of(record), "id": int(record.get("id", 0))}

static func cell(index, width: int) -> Vector2i:
	return Vector2i(int(index) % width, int(index) / width)

static func index(at: Vector2i, width: int) -> int:
	return at.y * width + at.x

static func local_point(canvas, point: Vector2) -> Vector2:
	return canvas.surface.to_local(canvas.world.to_global(point))

static func world_point(canvas, point: Vector2) -> Vector2:
	return canvas.world.to_local(canvas.surface.to_global(point))

static func inside(at: Vector2i, rect: Rect2i, mask: Dictionary) -> bool:
	return rect.has_point(at) and Mask.contains(mask, at)

static func capture(canvas, rect: Rect2i, mask: Dictionary = {}) -> Dictionary:
	if rect.size.x < 1 or rect.size.y < 1 or rect.size.x > Format.MAX_SIDE or rect.size.y > Format.MAX_SIDE:
		return {"error": "蓝图尺寸需在 1～1024 像素内"}
	var surface = canvas.surface
	var selection_bounds := Rect2(world_point(canvas, Vector2(rect.position)), Vector2.ZERO)
	for corner in [rect.end, Vector2i(rect.end.x, rect.position.y), Vector2i(rect.position.x, rect.end.y)]:
		selection_bounds = selection_bounds.expand(world_point(canvas, Vector2(corner)))
	var data := {"version": Format.VERSION, "id": "", "name": "未命名蓝图", "description": "", "tags": [],
		"updated": 0, "favorite": false, "editor_only": false, "size": [rect.size.x, rect.size.y],
		"pixels": [], "fixed_nails": [], "background_nails": [], "infinite_nails": [],
		"rods": [], "blue": [], "anchors": [], "springs": [], "motors": [], "bodies": [], "gears": [],
		"gear_centers": [], "draft_bearings": [], "rails": [], "slider_pins": []}
	for record in GearCenters.normalize(surface.gear_centers):
		if inside(Vector2i(GearCenters.position_of(record).floor()), rect, mask):
			data.gear_centers.append(_center_payload(record, Vector2(rect.position)))
	var pixels := {}
	var rods := {}
	var blues := {}
	var fixed_nails := {}
	var background_nails := {}
	var infinite_nails := {}
	var required := []
	var gears := []
	for record in surface.draft_bearings:
		var at := Vector2(record.get("position", Vector2.ZERO))
		if not inside(Vector2i(at.floor()), rect, mask):
			continue
		var support_point := Vector2(record.get("support_position", at))
		var fixed := bool(record.get("fixed_to_world", true))
		if not fixed and not inside(Vector2i(support_point.floor()), rect, mask):
			return {"error": "草稿轴承支座未完整框入，请同时包含支座连接点"}
		var support = null
		var path: NodePath = record.get("support_path", NodePath())
		if not fixed and not path.is_empty():
			var node: Node = canvas.world.get_node_or_null(path)
			if node == null or node.get("body") == null:
				return {"error": "草稿轴承支座无效，请先修复连接"}
			support = node.body
			if not required.has(support):
				required.append(support)
		data.draft_bearings.append({"position": xy(at - Vector2(rect.position)),
			"support_position": xy(support_point - Vector2(rect.position)), "fixed_to_world": fixed,
			"support": required.find(support), "support_material": int(record.get("support_material", 0)),
			"wheel_material": int(record.get("wheel_material", 0)), "center_id": int(record.get("center_id", -1))})
	for child in canvas.world.get_children():
		if not child is Bearing or child.is_queued_for_deletion() or child.yellow_anchor.is_empty():
			continue
		var at := Vector2i(local_point(canvas, Stroke.anchor_world(child.yellow_anchor)).floor())
		# 即使只框到轮缘，也不能把齿轮误存成普通碎片。
		var wheel = child.yellow_anchor.body
		if not wheel.aabb.intersects(selection_bounds):
			continue
		var touched := false
		for shape in wheel.shapes:
			var bounds: Rect2i = shape.local_aabb()
			for y in range(bounds.position.y, bounds.end.y):
				for x in range(bounds.position.x, bounds.end.x):
					if shape.get_pixel(x, y) != 0 and inside(Vector2i(local_point(canvas, wheel.to_world(Vector2(x, y) + Vector2.ONE * 0.5)).floor()), rect, mask):
						touched = true
		if not touched:
			continue
		if not inside(at, rect, mask):
			return {"error": "齿轮未完整框入：请包含整个轮体与轴心"}
		if not required.has(wheel):
			required.append(wheel)
		var support = null
		var support_at := at
		var support_material := 0
		if not child.fixed_to_world:
			if child.black_anchor.is_empty():
				return {"error": "齿轮支座无效，请先修复连接"}
			support = child.black_anchor.body
			support_at = Vector2i(local_point(canvas,
				Stroke.anchor_world(child.black_anchor)).floor())
			if not inside(support_at, rect, mask):
				return {"error": "齿轮支座未完整框入：请同时包含支座连接点"}
			support_material = int(child.support_material)
			if not required.has(support):
				required.append(support)
		gears.append({"node": child, "wheel": wheel, "support": support, "at": at,
			"support_at": support_at, "support_material": support_material,
			"world": bool(child.fixed_to_world), "legacy": not bool(child.explicit)})
	# 滑块和弹簧的主体也必须独立保存。摊平到像素层会把贴着固定底座的
	# 闸门/桥梁粘成静态连通块，导致普通墨水机关另存蓝图后无法运动。
	for child in canvas.world.get_children():
		if child.is_queued_for_deletion():
			continue
		var attached: Array = []
		if child is SliderPin and not child.black_anchor.is_empty():
			attached.append(child.black_anchor)
		elif child is Hinge and not child is Bearing:
			attached = [child.yellow_anchor, child.black_anchor]
		elif child is Stroke and child.state == Stroke.State.ACTIVE:
			attached = child.anchors
		for anchor in attached:
			if anchor.is_empty():
				continue
			var point := Vector2i(local_point(canvas, Stroke.anchor_world(anchor)).floor())
			if inside(point, rect, mask) and not required.has(anchor.body):
				required.append(anchor.body)
	# 逐像素读取草稿，不调用会移走原实体的 rasterize/return_to_canvas。
	var scan := rect.intersection(Rect2i(Vector2i.ZERO, surface.canvas_size))
	var black_bytes := PackedByteArray()
	var rod_bytes := PackedByteArray()
	if scan.has_area():
		black_bytes = surface.black_image.get_region(scan).get_data()
		rod_bytes = surface.rod_layer.pixels.get_region(scan).get_data()
	var colors := {}
	for y in range(scan.position.y, scan.end.y):
		for x in range(scan.position.x, scan.end.x):
			var offset: int = ((y - scan.position.y) * scan.size.x + x - scan.position.x) * 4
			if black_bytes[offset + 3] <= 127 and rod_bytes[offset + 3] <= 127:
				continue
			var at := Vector2i(x, y)
			if not mask.is_empty() and not Mask.contains(mask, at):
				continue
			var key := index(at - rect.position, rect.size.x)
			if black_bytes[offset + 3] > 127:
				var color := Color8(black_bytes[offset], black_bytes[offset + 1], black_bytes[offset + 2], black_bytes[offset + 3])
				if not colors.has(color):
					colors[color] = Palette.material_id_at_color(color)
				if int(colors[color]) != 0:
					pixels[key] = int(colors[color])
			if rod_bytes[offset + 3] > 127:
				rods[key] = true
	# 稀疏层按已有坐标读取，不在每个空白像素上反复查四个字典。
	for pair in [[surface.blue_layer.mask, blues], [surface.nail_layer.nails, fixed_nails],
		[surface.nail_layer.background_nails, background_nails], [surface.nail_layer.infinite_nails, infinite_nails]]:
		for at: Vector2i in pair[0]:
			if inside(at, rect, mask):
				pair[1][index(at - rect.position, rect.size.x)] = true
	for body in canvas.world.world.bodies:
		if body.tags.has("living") or (not required.has(body) and not body.aabb.intersects(selection_bounds)):
			continue
		var saved := {"pixels": [], "static": body.is_static,
			"fixed_nails": [], "background_nails": [], "infinite_nails": [],
			"gear_centers": [],
			"infinite_nail_body": Traits.is_unbreakable(body),
			"infinite_fuel_body": Traits.is_infinite_fuel(body)}
		var is_required := required.has(body)
		for record in GearCenters.body_records(body):
			if not GearCenters.record_alive(body, record):
				continue
			var center_canvas := local_point(canvas, body.to_world(GearCenters.position_of(record)))
			var center_at := Vector2i(center_canvas.floor())
			if not inside(center_at, rect, mask):
				continue
			if is_required:
				saved.gear_centers.append(_center_payload(record, Vector2(rect.position), center_canvas))
			else:
				data.gear_centers.append(_center_payload(record, Vector2(rect.position), center_canvas))
		for shape in body.shapes:
			var bounds: Rect2i = shape.local_aabb()
			# 大型地面只扫描映射后的选区范围；功能部件另做完整性检查。
			if not is_required:
				var a: Vector2 = body.to_local(world_point(canvas, Vector2(rect.position)))
				var lo: Vector2 = a
				var hi: Vector2 = a
				for corner in [Vector2(rect.end), Vector2(rect.position.x, rect.end.y), Vector2(rect.end.x, rect.position.y)]:
					var p: Vector2 = body.to_local(world_point(canvas, corner))
					lo = lo.min(p)
					hi = hi.max(p)
				bounds = bounds.intersection(Rect2i(Vector2i(lo.floor()) - Vector2i.ONE, Vector2i((hi - lo).ceil()) + Vector2i.ONE * 3))
			for y in range(bounds.position.y, bounds.end.y):
				for x in range(bounds.position.x, bounds.end.x):
					var material: int = shape.get_pixel(x, y)
					if material == 0:
						continue
					var at := Vector2i(local_point(canvas, body.to_world(Vector2(x, y) + Vector2.ONE * 0.5)).floor())
					if not inside(at, rect, mask):
						if is_required:
							return {"error": "机关或支座未完整框入，请扩大选区（圆形选区同样按圆内判定）"}
						continue
					if not Palette.is_ink(material) and material != Palette.nail_material_id():
						continue
					var key := index(at - rect.position, rect.size.x)
					if is_required:
						saved.pixels.append([key, material])
					elif material == Palette.YELLOW.id:
						rods[key] = true
					elif material == Palette.BLUE.id:
						blues[key] = true
					else:
						pixels[key] = material
		if is_required:
			# required 数组顺序是关节引用的稳定局部编号。
			while data.bodies.size() <= required.find(body):
				data.bodies.append({})
			var unique := {}
			for entry in saved.pixels:
				unique[entry[0]] = entry[1]
			saved.pixels = _entries(unique)
			data.bodies[required.find(body)] = saved
		for pair in [["static_anchor_points", saved.fixed_nails, fixed_nails],
			["background_anchor_points", saved.background_nails, background_nails],
			[Nail.INFINITE_TAG, saved.infinite_nails, infinite_nails]]:
			for point: Vector2i in body.tags.get(pair[0], {}):
				var at := Vector2i(local_point(canvas,
					body.to_world(Vector2(point) + Vector2.ONE * 0.5)).floor())
				if not inside(at, rect, mask):
					continue
				var key := index(at - rect.position, rect.size.x)
				if is_required:
					pair[1].append(key)
				else:
					pair[2][key] = true
	for entry in gears:
		var gear = entry.node
		data.gears.append({
			"point": xy(Vector2(entry.at - rect.position) + Vector2.ONE * 0.5),
			"wheel_point": xy(Vector2(entry.at - rect.position) + Vector2.ONE * 0.5),
			"support_point": xy(Vector2(entry.support_at - rect.position) + Vector2.ONE * 0.5),
			"wheel": required.find(entry.wheel), "support": required.find(entry.support),
			"world": bool(entry.world), "legacy": bool(entry.legacy),
			"support_material": int(entry.support_material),
			"material": gear.gear_material, "teeth": gear.teeth})
	data.editor_only = not data.gears.is_empty()
	for at in surface.rod_layer.anchor_points:
		if inside(Vector2i(at.floor()), rect, mask):
			data.anchors.append(xy(at - Vector2(rect.position)))
	# 导轨与滑块销是画布上的独立元数据，不存就会在放置后消失。
	for rail in surface.rod_layer.rails:
		var a := Vector2(rail.a)
		var b := Vector2(rail.b)
		var a_in := inside(Vector2i(a.floor()), rect, mask)
		var b_in := inside(Vector2i(b.floor()), rect, mask)
		# 两端都在框外、但导轨横穿选区时同样算半个部件，不能悄悄丢掉导轨线。
		var touched := a_in or b_in
		if not touched:
			var rail_steps := maxi(1, ceili(a.distance_to(b)))
			for step in rail_steps + 1:
				if inside(Vector2i(a.lerp(b, float(step) / rail_steps).floor()), rect, mask):
					touched = true
					break
		if touched and not (a_in and b_in):
			return {"error": "黄墨导轨未完整框入，请同时包含导轨两端"}
		if a_in and b_in:
			data.rails.append({"a": xy(a - Vector2(rect.position)), "b": xy(b - Vector2(rect.position)),
				"width": int(rail.width)})
	for pin in surface.rod_layer.slider_pins:
		var source := Vector2(pin.source)
		var position := Vector2(pin.position)
		var source_in := inside(Vector2i(source.floor()), rect, mask)
		var position_in := inside(Vector2i(position.floor()), rect, mask)
		if source_in != position_in:
			return {"error": "滑块销未完整框入，请把滑块销和它所在的导轨一起框住"}
		if source_in:
			data.slider_pins.append({"source": xy(source - Vector2(rect.position)),
				"position": xy(position - Vector2(rect.position))})
	for child in canvas.world.get_children():
		if child.is_queued_for_deletion():
			continue
		if child is Rail:
			var endpoints: PackedVector2Array = child.endpoints_world()
			var a := local_point(canvas, endpoints[0])
			var b := local_point(canvas, endpoints[1])
			var a_in := inside(Vector2i(a.floor()), rect, mask)
			var b_in := inside(Vector2i(b.floor()), rect, mask)
			var touched := a_in or b_in
			if not touched:
				var steps := maxi(1, ceili(a.distance_to(b)))
				for step in steps + 1:
					if inside(Vector2i(a.lerp(b, float(step) / steps).floor()), rect, mask):
						touched = true
						break
			if touched and not (a_in and b_in):
				return {"error": "黄墨导轨未完整框入，请同时包含导轨两端"}
			if a_in and b_in:
				data.rails.append({"a": xy(a - Vector2(rect.position)),
					"b": xy(b - Vector2(rect.position)), "width": child.rail_width})
			continue
		if child is SliderPin and not child.black_anchor.is_empty():
			var source := local_point(canvas, Stroke.anchor_world(child.black_anchor))
			var position := local_point(canvas, child.pin_world())
			var source_in := inside(Vector2i(source.floor()), rect, mask)
			var position_in := inside(Vector2i(position.floor()), rect, mask)
			if source_in != position_in:
				return {"error": "滑块销未完整框入，请把滑块销和它所在的导轨一起框住"}
			if source_in:
				data.slider_pins.append({"source": xy(source - Vector2(rect.position)),
					"position": xy(position - Vector2(rect.position))})
			continue
		if child is Hinge and not child is Bearing and not child.yellow_anchor.is_empty():
			var point := local_point(canvas, Stroke.anchor_world(child.yellow_anchor))
			if inside(Vector2i(point.floor()), rect, mask):
				var black := local_point(canvas, Stroke.anchor_world(child.black_anchor)) if not child.black_anchor.is_empty() else Vector2.INF
				if not inside(Vector2i(black.floor()), rect, mask):
					return {"error": "黄墨轴连接到选区外，请同时框入连接端"}
				data.anchors.append(xy(point - Vector2(rect.position)))
		if child is Wire and child.active and child.body != null:
			for at in child.cells:
				var point := Vector2i(local_point(canvas, child.body.to_world(at + Vector2.ONE * 0.5)).floor())
				if inside(point, rect, mask):
					blues[index(point - rect.position, rect.size.x)] = true
		if child is Motor and not child.preview:
			child.sync_pose()
			var point := local_point(canvas, child.position)
			var saved := {"point": xy(point - Vector2(rect.position)), "tip": xy(child.tip),
				"angle": child.rotation, "width": child.brush_width, "area": child.area}
			var touched := false
			var complete := true
			for at: Vector2i in motor_cells(saved):
				var hit := inside(at + rect.position, rect, mask)
				touched = touched or hit
				complete = complete and hit
			if touched:
				if not complete:
					return {"error": "蓝墨动力箭头未完整框入"}
				data.motors.append(saved)
		if child is Stroke and not child.preview and child.state in [Stroke.State.EDITING, Stroke.State.ACTIVE]:
			var source_path: PackedVector2Array = child.path
			if source_path.size() < 2:
				# 激活后的 Stroke 可能已清空绘制路径，端点要从保存的锚点恢复。
				if not child.activated or child.saved_anchor_a == child.saved_anchor_b:
					continue
				source_path = PackedVector2Array([child.saved_anchor_a, child.saved_anchor_b])
			if source_path.size() < 2:
				continue
			var path: Array = []
			var touched := false
			var complete := true
			var points: Array = [source_path[0], source_path[-1]]
			if child.state == Stroke.State.ACTIVE and child.anchors.size() == 2 \
			and not child.anchors[0].is_empty() and not child.anchors[1].is_empty():
				points = [Stroke.anchor_world(child.anchors[0]), Stroke.anchor_world(child.anchors[1])]
			for point in points:
				var at := local_point(canvas, point)
				var hit := inside(Vector2i(at.floor()), rect, mask)
				touched = touched or hit
				complete = complete and hit
				path.append(xy(at - Vector2(rect.position)))
			for at in child.cells:
				var point: Vector2 = surface.to_local(child.pixel_world(Vector2(at) + Vector2.ONE * 0.5))
				var hit := inside(Vector2i(point.floor()), rect, mask)
				touched = touched or hit
				complete = complete and hit
			if touched:
				if not complete:
					return {"error": "黄墨弹簧连接到选区外，请完整框入"}
				var worn: Array = []
				var old_axis: Vector2 = source_path[-1] - source_path[0]
				var length_ratio: float = points[0].distance_to(points[-1]) / maxf(0.001, old_axis.length())
				for point in child.worn:
					var local: Vector2 = point if child.compact_raster else (point - source_path[0]).rotated(-old_axis.angle())
					worn.append(xy(Vector2(local.x * length_ratio, local.y)))
				data.springs.append({"path": path, "width": child.brush_width, "worn": worn,
					"dash": child.dash_length, "gap": child.dash_gap, "dashed": child.dashed})
	data.pixels = _entries(pixels)
	data.fixed_nails = fixed_nails.keys()
	data.background_nails = background_nails.keys()
	data.infinite_nails = infinite_nails.keys()
	data.rods = rods.keys()
	data.blue = blues.keys()
	if not Format.validate(data):
		return {"error": "选区为空、包含不支持的材质或蓝图过大"}
	# 防止另存了缺少黑墨端子的半个机关，固化后才悄悄消失。
	var black := {}
	for entry in data.pixels:
		if entry[1] == Palette.BLACK.id:
			black[int(entry[0])] = true
	for saved in data.bodies:
		for entry in saved.pixels:
			if entry[1] == Palette.BLACK.id:
				black[int(entry[0])] = true
	for saved in data.motors:
		if not black.has(index(Vector2i(vec(saved.point).floor()), rect.size.x)):
			return {"error": "蓝墨箭头缺少选区内的黑墨锚点"}
	for saved in data.springs:
		for point in [saved.path[0], saved.path[-1]]:
			if not black.has(index(Vector2i(vec(point).floor()), rect.size.x)):
				return {"error": "黄墨弹簧缺少选区内的黑墨连接端"}
	for saved in data.slider_pins:
		if not black.has(index(Vector2i(vec(saved.source).floor()), rect.size.x)):
			return {"error": "滑块销缺少选区内的黑墨锚点"}
	return data

static func _entries(values: Dictionary) -> Array:
	var result: Array = []
	for key in values:
		result.append([key, values[key]])
	return result

static func _spring(saved: Dictionary, canvas = null, offset := Vector2i.ZERO):
	var stroke := Stroke.new()
	for point in saved.path:
		var at := vec(point) + Vector2(offset)
		stroke.path.append(world_point(canvas, at) if canvas != null else at)
	stroke.brush_width = int(saved.width)
	stroke.compact_raster = true
	stroke.dashed = saved.get("dashed", true)
	stroke.dash_length = saved.dash
	stroke.dash_gap = saved.gap
	for at in saved.get("worn", []):
		stroke.worn.append(vec(at))
	return stroke

static func motor_cells(saved: Dictionary) -> Dictionary:
	var result := {}
	var start := vec(saved.point)
	var delta := vec(saved.tip).rotated(saved.angle)
	var width := float(saved.width)
	var direction := delta.normalized()
	var end := start + delta
	var back := end - direction * minf(delta.length(), maxf(6, width * 2))
	var triangle := PackedVector2Array([end, back + direction.orthogonal() * width, back - direction.orthogonal() * width])
	var lo := Vector2i((start.min(end) - Vector2.ONE * width).floor())
	var hi := Vector2i((start.max(end) + Vector2.ONE * width).ceil())
	for y in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			var at := Vector2(x, y) + Vector2.ONE * 0.5
			if Geometry2D.is_point_in_polygon(at, triangle) or at.distance_squared_to(Geometry2D.get_closest_point_to_segment(at, start, back)) <= width * width * 0.25:
				result[Vector2i(x, y)] = true
	return result

static func spring_cells(saved: Dictionary) -> Dictionary:
	var result := {}
	var stroke = _spring(saved)
	stroke.build_pixels()
	for at in stroke.cells:
		result[Vector2i((Vector2(at).rotated((stroke.path[-1] - stroke.path[0]).angle()) + stroke.path[0]).floor())] = true
	stroke.free()
	return result

static func footprint(data: Dictionary) -> Dictionary:
	var result := {}
	var width := int(data.size[0])
	for entry in data.pixels:
		result[cell(entry[0], width)] = true
	for body in data.bodies:
		for entry in body.pixels:
			result[cell(entry[0], width)] = true
	for key in ["rods", "blue"]:
		for entry in data[key]:
			result[cell(entry, width)] = true
	for saved in data.motors:
		result.merge(motor_cells(saved))
	for saved in data.springs:
		result.merge(spring_cells(saved))
	return result

static func costs(data: Dictionary) -> Dictionary:
	var amounts := {}
	for entry in data.pixels:
		_add_cost(amounts, int(entry[1]), 1)
	for saved in data.bodies:
		for entry in saved.pixels:
			_add_cost(amounts, int(entry[1]), 1)
		_add_cost(amounts, Palette.GREY.id, saved.get("fixed_nails", []).size() * 10)
		_add_cost(amounts, Palette.WHITE.id, saved.get("background_nails", []).size() * 10)
	_add_cost(amounts, Palette.GREY.id, data.get("fixed_nails", []).size() * 10)
	_add_cost(amounts, Palette.WHITE.id, data.get("background_nails", []).size() * 10)
	_add_cost(amounts, Palette.YELLOW.id, data.rods.size())
	_add_cost(amounts, Palette.BLUE.id, data.blue.size())
	for saved in data.motors:
		_add_cost(amounts, Palette.BLUE.id, int(saved.area))
	for saved in data.springs:
		var stroke = _spring(saved)
		stroke.build_pixels()
		_add_cost(amounts, Palette.YELLOW.id, stroke.cells.size())
		stroke.free()
	return amounts

static func _add_cost(out: Dictionary, material: int, amount: int) -> void:
	if Palette.is_ink(material) and amount > 0:
		out[material] = out.get(material, 0) + amount

static func _preview_segment(image: Image, a: Vector2, b: Vector2, color: Color) -> void:
	var steps := maxi(1, ceili(a.distance_to(b)))
	var bounds := Rect2i(Vector2i.ZERO, image.get_size())
	for index in steps + 1:
		var at := Vector2i(a.lerp(b, float(index) / steps).floor())
		if bounds.has_point(at):
			image.set_pixelv(at, color)


static func preview(data: Dictionary) -> Image:
	var size := Vector2i(int(data.size[0]), int(data.size[1]))
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	var layers: Array = [data.pixels]
	for saved in data.bodies:
		layers.append(saved.pixels)
	for layer in layers:
		for entry in layer:
			image.set_pixelv(cell(entry[0], size.x), Palette.color_for_material_id(int(entry[1])))
	var nail_sets := [[data.get("fixed_nails", []), Nail.Kind.FIXED],
		[data.get("background_nails", []), Nail.Kind.BACKGROUND],
		[data.get("infinite_nails", []), Nail.Kind.INFINITE]]
	for saved in data.bodies:
		nail_sets.append([saved.get("fixed_nails", []), Nail.Kind.FIXED])
		nail_sets.append([saved.get("background_nails", []), Nail.Kind.BACKGROUND])
		nail_sets.append([saved.get("infinite_nails", []), Nail.Kind.INFINITE])
	for nail_set in nail_sets:
		var icon: Image = Nail.texture_for(nail_set[1]).get_image()
		icon.resize(roundi(icon.get_width() * Nail.VISUAL_SCALE), roundi(icon.get_height() * Nail.VISUAL_SCALE), Image.INTERPOLATE_NEAREST)
		for saved_index in nail_set[0]:
			var at := cell(saved_index, size.x)
			var origin := at - Vector2i(Nail.anchor_center_for(nail_set[1]) * Nail.VISUAL_SCALE)
			var clipped := Rect2i(origin, icon.get_size()).intersection(Rect2i(Vector2i.ZERO, size))
			if clipped.has_area():
				image.blend_rect(icon, Rect2i(clipped.position - origin, clipped.size), clipped.position)
	for key in ["rods", "blue"]:
		for entry in data[key]:
			image.set_pixelv(cell(entry, size.x), Palette.YELLOW.color if key == "rods" else Palette.BLUE.color)
	# 导轨与滑块销一起画进缩略图，蓝图库里能看出这是一套完整的滑动机构。
	var rail_color: Color = Palette.YELLOW.color.darkened(0.48)
	rail_color.a = 1.0
	for saved in data.get("rails", []):
		_preview_segment(image, vec(saved.a), vec(saved.b), rail_color)
	for saved in data.get("slider_pins", []):
		var pin_at := Vector2i(vec(saved.position).floor())
		if Rect2i(Vector2i.ZERO, size).has_point(pin_at):
			image.set_pixelv(pin_at, Color(0.08, 0.07, 0.02, 1.0))
			var right := pin_at + Vector2i(1, 0)
			if Rect2i(Vector2i.ZERO, size).has_point(right):
				image.set_pixelv(right, Palette.YELLOW.color)
	for saved in data.springs:
		var stroke = _spring(saved)
		stroke.build_pixels()
		for at in stroke.cells:
			var point: Vector2 = Vector2(at).rotated((stroke.path[-1] - stroke.path[0]).angle()) + stroke.path[0]
			if Rect2i(Vector2i.ZERO, size).has_point(Vector2i(point.floor())):
				image.set_pixelv(Vector2i(point.floor()), Palette.YELLOW.color)
		stroke.free()
	for saved in data.motors:
		for at: Vector2i in motor_cells(saved):
			if Rect2i(Vector2i.ZERO, size).has_point(at):
				image.set_pixelv(at, Palette.BLUE.color)
	return image
