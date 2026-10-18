extends RefCounted
## 连续旋转始终重采样原始选区，避免每次 2° 的取整误差反复侵蚀像素。
const Mask := preload("res://actor/canvas/src/selection_mask.gd")
const GearCenters := preload("res://actor/canvas/src/gear_centers.gd")
const GearBearings := preload("res://actor/canvas/src/gear_bearings.gd")
var cache: Dictionary = {}

func selected(point: Vector2, rect: Rect2i, mask: Dictionary) -> bool:
	var at := Vector2i(point.floor())
	return rect.has_point(at) and Mask.contains(mask, at)

func turn(point: Vector2, pivot: Vector2, angle: float) -> Vector2:
	return pivot + (point - pivot).rotated(angle)

func apply(canvas) -> bool:
	var surface = canvas.surface
	if not surface.has_selection() or surface._selection_dragging or surface._selecting:
		return false
	var rect: Rect2i = surface.selection_rect()
	var mask: Dictionary = surface.selection_mask()
	var continuing: bool = not cache.is_empty() and cache.last_rect == rect \
		and cache.circle == surface._selected_circle and surface.undo_available() \
		and surface.undo_top() == cache.last_step
	var original: Rect2i = cache.rect if continuing else rect
	var angle: float = cache.angle + deg_to_rad(2.0) if continuing else deg_to_rad(2.0)
	var pivot := Vector2(original.position) + Vector2(original.size) * 0.5
	var destination := original
	if not surface._selected_circle:
		var lo := pivot
		var hi := pivot
		for corner in [Vector2(original.position), Vector2(original.end),
			Vector2(original.position.x, original.end.y), Vector2(original.end.x, original.position.y)]:
			var rotated := turn(corner, pivot, angle)
			lo = lo.min(rotated)
			hi = hi.max(rotated)
		destination = Rect2i(Vector2i(lo.floor()), Vector2i(hi.ceil() - lo.floor()))
	if not Rect2i(Vector2i.ZERO, surface.canvas_size).encloses(destination):
		return false
	var bounds := Rect2(surface.to_global(Vector2(rect.position)), Vector2(rect.size))
	var state: Dictionary = canvas.History.capture(canvas, true, bounds)
	var physical := {}
	var whole: Dictionary = cache.whole if continuing else canvas.whole_bodies_in_selection(rect, mask)
	var moved_centers: Array = []
	var moved_bearings: Array = []
	canvas.solid.rasterize_rect(surface, canvas.world, rect, physical, mask, whole,
		moved_centers, moved_bearings)
	if not continuing:
		cache = {"whole": whole, "rect": rect, "mask": mask.duplicate(), "circle": surface._selected_circle,
			"black": surface.black_image.duplicate(), "rod": surface.rod_layer.pixels.duplicate(),
			"blue": surface.blue_layer.mask.duplicate(), "physical": physical.duplicate(),
			"centers": GearCenters.normalize(surface.gear_centers), "anchors": surface.rod_layer.anchor_points.duplicate(),
			"draft_bearings": surface.draft_bearings.duplicate(true),
			"rails": surface.rod_layer.rails.duplicate(true), "pins": surface.rod_layer.slider_pins.duplicate(true),
			"springs": [], "motors": []}
		var yellow = surface.yellow_rule()
		if yellow != null:
			for stroke in yellow.strokes:
				if stroke.source_surface == surface and not stroke.activated:
					cache.springs.append({"node": stroke, "path": stroke.path.duplicate()})
		var blue = surface.blue_rule()
		if blue != null:
			for motor in blue.objects(blue.Motor):
				if motor.source_surface == surface and not motor.active and not motor.preview:
					cache.motors.append({"node": motor, "position": motor.global_position, "rotation": motor.rotation})
	var writes := {}
	var rotated_physical := {}
	for y in range(destination.position.y, destination.end.y):
		for x in range(destination.position.x, destination.end.x):
			var at := Vector2i(x, y)
			if cache.circle and not Mask.contains(cache.mask, at):
				continue
			var source := Vector2i(turn(Vector2(at) + Vector2.ONE * 0.5, pivot, -angle).floor())
			if not selected(Vector2(source), original, cache.mask):
				continue
			var black: Color = cache.black.get_pixelv(source)
			var rod: Color = cache.rod.get_pixelv(source)
			var blue: bool = cache.blue.has(source)
			if black.a <= 0.5 and rod.a <= 0.5 and not blue:
				continue
			# 绝不覆盖未选中的墨水；边缘空间不足时保持原状。
			if not selected(Vector2(at), rect, mask) and (surface.black_image.get_pixelv(at).a > 0.5 \
				or surface.rod_layer.pixels.get_pixelv(at).a > 0.5 or surface.blue_layer.mask.has(at)):
				canvas.History.restore(canvas, state)
				cache.clear()
				return false
			writes[at] = [black, rod, blue]
			if cache.physical.has(source):
				rotated_physical[at] = cache.physical[source]
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var at := Vector2i(x, y)
			if not Mask.contains(mask, at):
				continue
			surface._set_pixel_raw(at, Color.TRANSPARENT, false, true)
			surface.rod_layer.pixels.set_pixelv(at, Color.TRANSPARENT)
			surface.blue_layer.mask.erase(at)
	for at: Vector2i in writes:
		surface._set_pixel_raw(at, writes[at][0], false)
		surface.rod_layer.pixels.set_pixelv(at, writes[at][1])
		if writes[at][2]:
			surface.blue_layer.mask[at] = true
	surface.gear_centers = GearCenters.normalize(cache.centers)
	for i in surface.gear_centers.size():
		var record: Dictionary = surface.gear_centers[i]
		if selected(GearCenters.position_of(record), original, cache.mask):
			record["position"] = turn(GearCenters.position_of(record), pivot, angle)
	surface.draft_bearings = cache.get("draft_bearings", []).duplicate(true)
	for record in surface.draft_bearings:
		if selected(Vector2(record.get("position", Vector2.ZERO)), original, cache.mask):
			record["position"] = turn(Vector2(record.position), pivot, angle)
			record["support_position"] = turn(Vector2(record.get("support_position", record.position)),
				pivot, angle)
	surface.rod_layer.anchor_points = cache.anchors.duplicate()
	for i in surface.rod_layer.anchor_points.size():
		if selected(surface.rod_layer.anchor_points[i], original, cache.mask):
			surface.rod_layer.anchor_points[i] = turn(surface.rod_layer.anchor_points[i], pivot, angle)
	surface.rod_layer.rails = cache.rails.duplicate(true)
	surface.rod_layer.slider_pins = cache.pins.duplicate(true)
	for rail in surface.rod_layer.rails:
		for key in ["a", "b"]:
			if selected(rail[key], original, cache.mask):
				rail[key] = turn(rail[key], pivot, angle)
	for pin in surface.rod_layer.slider_pins:
		for key in ["source", "position"]:
			if selected(pin[key], original, cache.mask):
				pin[key] = turn(pin[key], pivot, angle)
	for entry in cache.springs:
		if not is_instance_valid(entry.node):
			continue
		var path: PackedVector2Array = entry.path.duplicate()
		var complete := true
		for point in path:
			complete = complete and selected(surface.to_local(canvas.world.to_global(point)), original, cache.mask)
		if complete:
			for i in path.size():
				path[i] = canvas.world.to_local(surface.to_global(turn(surface.to_local(canvas.world.to_global(path[i])), pivot, angle)))
			entry.node.path = path
			entry.node.build_pixels()
	for entry in cache.motors:
		var point: Vector2 = surface.to_local(entry.position)
		if is_instance_valid(entry.node) and selected(point, original, cache.mask):
			entry.node.global_position = surface.to_global(turn(point, pivot, angle))
			entry.node.rotation = entry.rotation + angle
	if not rotated_physical.is_empty():
		canvas.solid.spawn_moved_pixels(surface, canvas.world, rotated_physical, Vector2i.ZERO, canvas._map_editor_mode)
		for record in moved_centers:
			record["position"] = turn(GearCenters.position_of(record), pivot, angle)
		GearCenters.attach(surface, canvas.world, moved_centers)
		for record in moved_bearings:
			record["position"] = turn(Vector2(record.get("position", Vector2.ZERO)), pivot, angle)
			var support_point := Vector2(record.get("support_position", record.position))
			if bool(record.get("fixed_to_world", false)) or selected(support_point, original, cache.mask):
				record["support_position"] = turn(support_point, pivot, angle)
		GearBearings.restore(surface, moved_bearings)
		canvas.solid.sync_serializable_bodies(canvas.world)
	canvas.transform_whole_bodies(whole, Vector2.ZERO, deg_to_rad(2.0), pivot)
	surface.rod_layer.refresh()
	surface.blue_layer.refresh()
	surface.blue_layer.build_widths()
	surface._flush_texture()
	surface._flush_ink()
	surface._selected_rect = destination
	surface.selection_overlay.set_selection(destination, surface._selected_circle)
	canvas.History.commit(canvas, state)
	cache.angle = angle
	cache.last_rect = destination
	cache.last_step = surface.undo_top()
	return true
