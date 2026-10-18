extends RefCounted
## 只读选区采集、独立部件重建，以及一次性提交的绘画事务。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Mask := preload("res://actor/canvas/src/selection_mask.gd")
const Store := preload("res://ui/hud/blueprint/src/blueprint_store.gd")
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

static func vec(value: Array) -> Vector2:
	return Vector2(value[0], value[1])

static func xy(value: Vector2) -> Array:
	return [value.x, value.y]

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
	if rect.size.x < 1 or rect.size.y < 1 or rect.size.x > Store.MAX_SIDE or rect.size.y > Store.MAX_SIDE:
		return {"error": "蓝图尺寸需在 1～1024 像素内"}
	var surface = canvas.surface
	var data := {"version": Store.VERSION, "id": "", "name": "未命名蓝图", "description": "", "tags": [],
		"updated": 0, "favorite": false, "editor_only": false, "size": [rect.size.x, rect.size.y],
		"pixels": [], "fixed_nails": [], "background_nails": [], "infinite_nails": [],
		"rods": [], "blue": [], "anchors": [], "springs": [], "motors": [], "bodies": [], "gears": [],
		"gear_centers": [], "rails": [], "slider_pins": []}
	for point in surface.gear_centers:
		if inside(Vector2i(point.floor()), rect, mask):
			data.gear_centers.append(xy(point - Vector2(rect.position)))
	var pixels := {}
	var rods := {}
	var blues := {}
	var fixed_nails := {}
	var background_nails := {}
	var infinite_nails := {}
	var required := []
	var gears := []
	for child in canvas.world.get_children():
		if not child is Bearing or child.is_queued_for_deletion() or child.yellow_anchor.is_empty():
			continue
		var at := Vector2i(local_point(canvas, Stroke.anchor_world(child.yellow_anchor)).floor())
		# 即使只框到轮缘，也不能把齿轮误存成普通碎片。
		var wheel = child.yellow_anchor.body
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
		if not child.fixed_to_world:
			if child.black_anchor.is_empty():
				return {"error": "齿轮支座无效，请先修复连接"}
			support = child.black_anchor.body
			if not required.has(support):
				required.append(support)
		gears.append({"node": child, "wheel": wheel, "support": support, "at": at})
	# 逐像素读取草稿，不调用会移走原实体的 rasterize/return_to_canvas。
	var scan := rect.intersection(Rect2i(Vector2i.ZERO, surface.canvas_size))
	for y in range(scan.position.y, scan.end.y):
		for x in range(scan.position.x, scan.end.x):
			var at := Vector2i(x, y)
			if not inside(at, rect, mask):
				continue
			var key := index(at - rect.position, rect.size.x)
			var material: int = surface.material_at(x, y)
			if material != 0:
				pixels[key] = material
			if surface.rod_layer.pixels.get_pixel(x, y).a > 0.5:
				rods[key] = true
			if surface.blue_layer.mask.has(at):
				blues[key] = true
			if surface.nail_layer.nails.has(at):
				fixed_nails[key] = true
			elif surface.nail_layer.background_nails.has(at):
				background_nails[key] = true
			elif surface.nail_layer.infinite_nails.has(at):
				infinite_nails[key] = true
	for body in canvas.world.world.bodies:
		if body.tags.has("living"):
			continue
		var saved := {"pixels": [], "static": body.is_static,
			"fixed_nails": [], "background_nails": [], "infinite_nails": [],
			"infinite_nail_body": Traits.is_unbreakable(body),
			"infinite_fuel_body": Traits.is_infinite_fuel(body)}
		var is_required := required.has(body)
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
		data.gears.append({"point": xy(Vector2(entry.at - rect.position) + Vector2.ONE * 0.5),
			"wheel": required.find(entry.wheel), "support": required.find(entry.support),
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
			var path: Array = []
			var touched := false
			var complete := true
			var points: Array = [child.path[0], child.path[-1]]
			if child.state == Stroke.State.ACTIVE and child.anchors.size() == 2:
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
				var old_axis: Vector2 = child.path[-1] - child.path[0]
				var length_ratio: float = points[0].distance_to(points[-1]) / maxf(0.001, old_axis.length())
				for point in child.worn:
					var local: Vector2 = point if child.compact_raster else (point - child.path[0]).rotated(-old_axis.angle())
					worn.append(xy(Vector2(local.x * length_ratio, local.y)))
				data.springs.append({"path": path, "width": child.brush_width, "worn": worn,
					"dash": child.dash_length, "gap": child.dash_gap, "dashed": child.dashed})
	data.pixels = _entries(pixels)
	data.fixed_nails = fixed_nails.keys()
	data.background_nails = background_nails.keys()
	data.infinite_nails = infinite_nails.keys()
	data.rods = rods.keys()
	data.blue = blues.keys()
	if not Store.validate(data):
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

static func placement_error(canvas, data: Dictionary, offset: Vector2i, amounts: Dictionary = {}, occupied: Dictionary = {}) -> String:
	if not is_instance_valid(canvas) or not canvas.is_inside_tree() or not canvas.active or not canvas.visible:
		return "目标画布已失效"
	if not canvas._map_editor_mode and not canvas.is_player_near_workbench():
		return "请靠近画布使用"
	if data.editor_only and not canvas._map_editor_mode:
		return "含齿轮的蓝图仅编辑器可用"
	var surface = canvas.surface
	var size := Vector2i(int(data.size[0]), int(data.size[1]))
	if not Rect2i(Vector2i.ZERO, surface.canvas_size).encloses(Rect2i(offset, size)):
		return "蓝图超出画布边界"
	if not surface.ink_free:
		var health = surface._health_node()
		if health == null:
			return "找不到墨水来源"
		if amounts.is_empty():
			amounts = costs(data)
		for material in amounts:
			if health.ink_of(material) < surface.MIN_PAINT_INK or amounts[material] > surface._drawable_ink_room(material):
				return "墨水不足（材质 %d 需 %d px，剩余 %d px）" % [material, amounts[material], health.ink_of(material)]
	# 透明空白不占位；同一蓝图内部的轮体/支座重叠不作冲突。
	if occupied.is_empty():
		occupied = footprint(data)
	var region := Rect2(world_point(canvas, Vector2(offset)), Vector2(size))
	var body_grid := {}
	for body in canvas.world.world.bodies:
		if not body.aabb.intersects(region):
			continue
		var bounds: Rect2 = body.aabb.intersection(region)
		for y in range(floori(bounds.position.y / 64), floori(bounds.end.y / 64) + 1):
			for x in range(floori(bounds.position.x / 64), floori(bounds.end.x / 64) + 1):
				var key := Vector2i(x, y)
				if not body_grid.has(key):
					body_grid[key] = []
				body_grid[key].append(body)
	var special := {}
	for child in canvas.world.get_children():
		if child.is_queued_for_deletion():
			continue
		if child is Stroke and not child.preview:
			for at in child.cells:
				var point := Vector2i(surface.to_local(child.pixel_world(Vector2(at) + Vector2.ONE * 0.5)).floor())
				special[point] = true
		elif child is Motor and not child.preview:
			var saved := {"point": xy(local_point(canvas, child.position)), "tip": xy(child.tip), "angle": child.rotation, "width": child.brush_width}
			special.merge(motor_cells(saved))
	for relative: Vector2i in occupied:
		var at := relative + offset
		if not Rect2i(Vector2i.ZERO, surface.canvas_size).has_point(at):
			return "部件超出画布边界"
		if surface.material_at(at.x, at.y) != 0 or surface.rod_layer.pixels.get_pixelv(at).a > 0.5 or surface.blue_layer.mask.has(at) or special.has(at):
			return "与画布上的内容重叠"
		var point := world_point(canvas, Vector2(at) + Vector2.ONE * 0.5)
		var bucket := Vector2i(floori(point.x / 64), floori(point.y / 64))
		for body in body_grid.get(bucket, []):
			if not body.aabb.has_point(point):
				continue
			var pos := Vector2i(body.to_local(point).floor())
			for shape in body.shapes:
				if shape.get_pixel(pos.x, pos.y) != 0:
					return "与已有实体重叠"
	return ""

static func place(canvas, data: Dictionary, offset: Vector2i) -> String:
	if not Store.validate(data):
		return "蓝图数据无效"
	var amounts := costs(data)
	var error := placement_error(canvas, data, offset, amounts)
	if not error.is_empty():
		return error
	var surface = canvas.surface
	var bounds := Rect2(surface.to_global(Vector2(offset)), Vector2(vec(data.size)))
	var state: Dictionary = canvas.History.capture(canvas, true, bounds)
	state["bounds"] = bounds
	for point in data.get("gear_centers", []):
		surface.gear_centers.append(vec(point) + Vector2(offset))
	var width := int(data.size[0])
	for entry in data.pixels:
		var material := int(entry[1])
		surface._set_pixel_raw(cell(entry[0], width) + offset, Palette.color_for_material_id(material))
	for saved_index in data.get("fixed_nails", []):
		surface.nail_layer.add(cell(saved_index, width) + offset, Nail.Kind.FIXED)
	for saved_index in data.get("background_nails", []):
		surface.nail_layer.add(cell(saved_index, width) + offset, Nail.Kind.BACKGROUND)
	for saved_index in data.get("infinite_nails", []):
		surface.nail_layer.add(cell(saved_index, width) + offset, Nail.Kind.INFINITE)
	surface._bump_ink(Palette.GREY.id, data.get("fixed_nails", []).size() * surface.NAIL_COST)
	surface._bump_ink(Palette.WHITE.id, data.get("background_nails", []).size() * surface.NAIL_COST)
	for entry in data.rods:
		surface.rod_layer.pixels.set_pixelv(cell(entry, width) + offset, Palette.YELLOW.color)
	# 独立黄墨层自己在 clear/erase 时退款，不能再计入普通像素账本。
	if not surface.ink_free and not data.rods.is_empty():
		surface._health_node().reduce(Palette.YELLOW.id, data.rods.size())
	for entry in data.blue:
		surface.blue_layer.mask[cell(entry, width) + offset] = true
	surface.blue_layer.refresh()
	surface.blue_layer.build_widths()
	surface._bump_ink(Palette.BLUE.id, data.blue.size())
	for entry in data.anchors:
		surface.rod_layer.anchor_points.append(vec(entry) + Vector2(offset))
	# 导轨与滑块销必须和像素一起回填，否则放置后导轨线、销都会消失。
	for entry in data.get("rails", []):
		surface.rod_layer.rails.append({"a": vec(entry.a) + Vector2(offset),
			"b": vec(entry.b) + Vector2(offset), "width": int(entry.width)})
	for entry in data.get("slider_pins", []):
		surface.rod_layer.slider_pins.append({"source": vec(entry.source) + Vector2(offset),
			"position": vec(entry.position) + Vector2(offset)})
	for saved in data.springs:
		var stroke = _spring(saved, canvas, offset)
		stroke.source_surface = surface
		stroke.source_canvas = canvas.world.get_path_to(surface)
		stroke.paid = not surface.ink_free
		canvas.world.add_child(stroke)
		stroke.owner = canvas.world
		surface.yellow_rule().strokes.append(stroke)
		if not surface.ink_free:
			surface._health_node().reduce(Palette.YELLOW.id, stroke.cells.size())
	for saved in data.motors:
		var motor := Motor.new()
		motor.position = world_point(canvas, vec(saved.point) + Vector2(offset))
		motor.rotation = saved.angle
		motor.tip = vec(saved.tip)
		motor.brush_width = int(saved.width)
		motor.area = int(saved.area)
		motor.source_surface = surface
		motor.source_canvas = canvas.world.get_path_to(surface)
		motor.paid = not surface.ink_free
		canvas.world.add_child(motor)
		motor.owner = canvas.world
		surface._bump_ink(Palette.BLUE.id, motor.area)
	var created: Array = []
	for saved in data.bodies:
		var image := Image.create_empty(width, int(data.size[1]), false, Image.FORMAT_R8)
		for entry in saved.pixels:
			image.set_pixelv(cell(entry[0], width), Color8(int(entry[1]), 0, 0, 255))
		var node := InkItem.new()
		node.name = "BlueprintPart%d" % canvas.world.get_child_count()
		node.position = world_point(canvas, Vector2(offset))
		node.is_static = saved.static
		node.fixed_nails = PackedVector2Array(saved.get("fixed_nails", []).map(
			func(saved_index): return cell(saved_index, width)))
		node.background_nails = PackedVector2Array(saved.get("background_nails", []).map(
			func(saved_index): return cell(saved_index, width)))
		node.infinite_nails = PackedVector2Array(saved.get("infinite_nails", []).map(
			func(saved_index): return cell(saved_index, width)))
		node.infinite_nail_body = bool(saved.get("infinite_nail_body", false))
		node.infinite_fuel_body = bool(saved.get("infinite_fuel_body", false))
		node.add_to_group("ink_item", true)
		var shape := ShapeNode.new()
		shape.source = ShapeNode.Source.PAINT
		shape.paint = image
		node.add_child(shape)
		canvas.world.add_child(node)
		node.owner = canvas.world
		shape.owner = canvas.world
		created.append({"node": node, "body": canvas.world.add_body_node(node)})
	for saved in data.gears:
		var bearing := Bearing.new()
		var wheel = created[int(saved.wheel)]
		var axle := world_point(canvas, vec(saved.point) + Vector2(offset))
		bearing.yellow_position = axle
		bearing.black_position = axle
		bearing.teeth = int(saved.teeth)
		bearing.gear_material = int(saved.material)
		bearing.fixed_to_world = saved.support < 0
		bearing.yellow_anchor = {"body": wheel.body, "cell": Vector2i(wheel.body.to_local(axle).floor()), "local": wheel.body.to_local(axle)}
		if saved.support >= 0:
			var support = created[int(saved.support)].body
			var at := Vector2i(support.to_local(axle).floor())
			bearing.support_material = Wire.material_at(support, at)
			bearing.black_anchor = {"body": support, "cell": at, "local": support.to_local(axle)}
		canvas.world.add_child(bearing)
		bearing.owner = canvas.world
		bearing.wheel_path = bearing.get_path_to(wheel.node)
		bearing.connect_joint()
		bearing._process(0.0)
	surface.refresh()
	canvas.History.commit(canvas, state)
	canvas.map_changed.emit()
	return ""
