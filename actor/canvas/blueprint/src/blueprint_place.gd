extends RefCounted
## 蓝图放置事务：预检（`placement_error`）→ 提交（`place`）。
##
## 采集与预览留在 `blueprint_codec.gd`；这里通过 `Codec` 复用几何助手与耗墨统计，
## 所以依赖方向是 place → codec，单向。撤销由画布历史负责：一次放置对应一次事务。

const Codec := preload("res://actor/canvas/blueprint/src/blueprint_codec.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Format := preload("res://blueprint/src/blueprint_format.gd")
const Bearing := preload("res://ink/yellow/src/axle.gd")
const Hinge := preload("res://ink/yellow/src/hinge.gd")
const Stroke := preload("res://ink/yellow/src/stroke.gd")
const Motor := preload("res://ink/blue/src/motor.gd")
const Wire := preload("res://ink/blue/src/wire_layer.gd")
const InkItem := preload("res://actor/ink_item/src/ink_item.gd")
const ShapeNode := preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
const Nail := preload("res://actor/nail/src/nail.gd")
const GearCenters := preload("res://actor/canvas/src/gear_centers.gd")


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
			amounts = Codec.costs(data)
		for material in amounts:
			if health.ink_of(material) < surface.MIN_PAINT_INK or amounts[material] > surface._drawable_ink_room(material):
				return "墨水不足（材质 %d 需 %d px，剩余 %d px）" % [material, amounts[material], health.ink_of(material)]
	# 透明空白不占位；同一蓝图内部的轮体/支座重叠不作冲突。
	if occupied.is_empty():
		occupied = Codec.footprint(data)
	var region := Rect2(Codec.world_point(canvas, Vector2(offset)), Vector2(size))
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
			var saved := {"point": Codec.xy(Codec.local_point(canvas, child.position)), "tip": Codec.xy(child.tip), "angle": child.rotation, "width": child.brush_width}
			special.merge(Codec.motor_cells(saved))
	for relative: Vector2i in occupied:
		var at := relative + offset
		if not Rect2i(Vector2i.ZERO, surface.canvas_size).has_point(at):
			return "部件超出画布边界"
		if surface.material_at(at.x, at.y) != 0 or surface.rod_layer.pixels.get_pixelv(at).a > 0.5 or surface.blue_layer.mask.has(at) or special.has(at):
			return "与画布上的内容重叠"
		var point := Codec.world_point(canvas, Vector2(at) + Vector2.ONE * 0.5)
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
	if not Format.validate(data):
		return "蓝图数据无效"
	var amounts := Codec.costs(data)
	var error := placement_error(canvas, data, offset, amounts)
	if not error.is_empty():
		return error
	var surface = canvas.surface
	var bounds := Rect2(surface.to_global(Vector2(offset)), Vector2(Codec.vec(data.size)))
	var state: Dictionary = canvas.History.capture(canvas, true, bounds)
	state["bounds"] = bounds
	var center_ids := {}
	for point in data.get("gear_centers", []):
		var record := Format.center_any(point)
		if record.is_empty():
			continue
		var copied: Dictionary = surface.add_gear_center(Vector2(record.position[0], record.position[1]) + Vector2(offset),
			float(record.radius), int(record.material))
		center_ids[int(record.id)] = int(copied.id)
	var width := int(data.size[0])
	for entry in data.pixels:
		var material := int(entry[1])
		surface._set_pixel_raw(Codec.cell(entry[0], width) + offset, Palette.color_for_material_id(material))
	for saved_index in data.get("fixed_nails", []):
		surface.nail_layer.add(Codec.cell(saved_index, width) + offset, Nail.Kind.FIXED)
	for saved_index in data.get("background_nails", []):
		surface.nail_layer.add(Codec.cell(saved_index, width) + offset, Nail.Kind.BACKGROUND)
	for saved_index in data.get("infinite_nails", []):
		surface.nail_layer.add(Codec.cell(saved_index, width) + offset, Nail.Kind.INFINITE)
	surface._bump_ink(Palette.GREY.id, data.get("fixed_nails", []).size() * surface.NAIL_COST)
	surface._bump_ink(Palette.WHITE.id, data.get("background_nails", []).size() * surface.NAIL_COST)
	for entry in data.rods:
		surface.rod_layer.pixels.set_pixelv(Codec.cell(entry, width) + offset, Palette.YELLOW.color)
	# 独立黄墨层自己在 clear/erase 时退款，不能再计入普通像素账本。
	if not surface.ink_free and not data.rods.is_empty():
		surface._health_node().reduce(Palette.YELLOW.id, data.rods.size())
	for entry in data.blue:
		surface.blue_layer.mask[Codec.cell(entry, width) + offset] = true
	surface.blue_layer.refresh()
	surface.blue_layer.build_widths()
	surface._bump_ink(Palette.BLUE.id, data.blue.size())
	for entry in data.anchors:
		surface.rod_layer.anchor_points.append(Codec.vec(entry) + Vector2(offset))
	# 导轨与滑块销必须和像素一起回填，否则放置后导轨线、销都会消失。
	for entry in data.get("rails", []):
		surface.rod_layer.rails.append({"a": Codec.vec(entry.a) + Vector2(offset),
			"b": Codec.vec(entry.b) + Vector2(offset), "width": int(entry.width)})
	for entry in data.get("slider_pins", []):
		surface.rod_layer.slider_pins.append({"source": Codec.vec(entry.source) + Vector2(offset),
			"position": Codec.vec(entry.position) + Vector2(offset)})
	for saved in data.springs:
		var stroke = Codec._spring(saved, canvas, offset)
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
		motor.position = Codec.world_point(canvas, Codec.vec(saved.point) + Vector2(offset))
		motor.rotation = saved.angle
		motor.tip = Codec.vec(saved.tip)
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
			image.set_pixelv(Codec.cell(entry[0], width), Color8(int(entry[1]), 0, 0, 255))
		var node := InkItem.new()
		node.name = "BlueprintPart%d" % canvas.world.get_child_count()
		node.position = Codec.world_point(canvas, Vector2(offset))
		node.is_static = saved.static
		node.fixed_nails = PackedVector2Array(saved.get("fixed_nails", []).map(
			func(saved_index): return Codec.cell(saved_index, width)))
		node.background_nails = PackedVector2Array(saved.get("background_nails", []).map(
			func(saved_index): return Codec.cell(saved_index, width)))
		node.infinite_nails = PackedVector2Array(saved.get("infinite_nails", []).map(
			func(saved_index): return Codec.cell(saved_index, width)))
		node.infinite_nail_body = bool(saved.get("infinite_nail_body", false))
		node.infinite_fuel_body = bool(saved.get("infinite_fuel_body", false))
		var local_centers: Array = []
		for point in saved.get("gear_centers", []):
			var record := Format.center_any(point)
			if record.is_empty():
				continue
			local_centers.append(GearCenters.make(Vector2(record.position[0], record.position[1]),
				float(record.radius), int(record.material)))
		node.gear_centers = local_centers
		node.add_to_group("ink_item", true)
		var shape := ShapeNode.new()
		shape.source = ShapeNode.Source.PAINT
		shape.paint = image
		node.add_child(shape)
		canvas.world.add_child(node)
		node.owner = canvas.world
		shape.owner = canvas.world
		created.append({"node": node, "body": canvas.world.add_body_node(node)})
	for saved in data.get("draft_bearings", []):
		var record: Dictionary = saved.duplicate(true)
		for key in ["support_path", "support_body", "wheel_path", "wheel_body"]:
			record.erase(key)
		record["position"] = Codec.vec(saved.position) + Vector2(offset)
		record["support_position"] = Codec.vec(saved.support_position) + Vector2(offset)
		record["center_id"] = int(center_ids.get(int(saved.get("center_id", -1)), -1))
		var support_index := int(saved.get("support", -1))
		if support_index >= 0:
			record["support_path"] = canvas.world.get_path_to(created[support_index].node)
		record.erase("support")
		surface.draft_bearings.append(record)
	for saved in data.gears:
		var bearing := Bearing.new()
		var wheel = created[int(saved.wheel)]
		var wheel_local_at := Codec.vec(saved.get("wheel_point", saved.point)) + Vector2(offset)
		var wheel_world := Codec.world_point(canvas, wheel_local_at)
		bearing.explicit = true
		bearing.yellow_position = wheel_world
		bearing.black_position = wheel_world
		bearing.teeth = int(saved.teeth)
		bearing.gear_material = int(saved.material)
		var support_index := int(saved.get("support", -1))
		bearing.fixed_to_world = bool(saved.get("world", support_index < 0))
		var wheel_cell := Vector2i(wheel.body.to_local(wheel_world).floor())
		bearing.yellow_anchor = {"body": wheel.body, "cell": wheel_cell,
			"local": wheel.body.to_local(wheel_world)}
		canvas.world.add_child(bearing)
		bearing.owner = canvas.world
		bearing.wheel_path = bearing.get_path_to(wheel.node)
		if support_index >= 0:
			var support = created[support_index].body
			var support_point := Codec.vec(saved.get("support_point", saved.point)) + Vector2(offset)
			var support_world := Codec.world_point(canvas, support_point)
			var at := Vector2i(support.to_local(support_world).floor())
			bearing.support_material = int(saved.get("support_material", 0))
			if bearing.support_material == 0:
				bearing.support_material = Wire.material_at(support, at)
			bearing.black_anchor = {"body": support, "cell": at,
				"local": support.to_local(support_world)}
			bearing.black_position = support_world
			bearing.support_path = bearing.get_path_to(created[support_index].node)
		bearing.connect_joint()
		bearing._process(0.0)
	surface.refresh()
	canvas.History.commit(canvas, state)
	canvas.map_changed.emit()
	return ""
