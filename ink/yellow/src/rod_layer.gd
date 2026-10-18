@tool
extends Node2D
## 黄色独立图层。复用 CanvasSurface 笔刷和 CanvasSolid 连通域/刚体生成。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")
const Hinge := preload("res://ink/yellow/src/hinge.gd")
const Stroke := preload("res://ink/yellow/src/stroke.gd")
const Rail := preload("res://ink/yellow/src/rail.gd")
const SliderPin := preload("res://ink/yellow/src/slider_pin.gd")
const SelectionMask := preload("res://actor/canvas/src/selection_mask.gd")
const GearCenters := preload("res://actor/canvas/src/gear_centers.gd")
const GearBearings := preload("res://actor/canvas/src/gear_bearings.gd")
const History := preload("res://actor/canvas/src/canvas_history.gd")
## CanvasSurface.Tool.CIRCLE；rod_layer 被 surface 预加载，不能反向 preload 它。
const TOOL_CIRCLE := 5
@export var pixels: Image
@export var anchor_points: PackedVector2Array = []
@export var rails: Array = []
@export var slider_pins: Array = []
var texture: ImageTexture
var source_surface
var last_point := Vector2.ZERO
var erasing := false
var changed: Dictionary = {}
var prior_anchors: PackedVector2Array
var ink_delta := 0
var prior_springs: Array = []
var rail_drawing := false
var rail_origin := Vector2.ZERO
var rail_cursor := Vector2.ZERO
## 轴承工具预览与点击共用同一个解析结果，避免预览吸附到中心、点击却连到别处。
var _bearing_preview: Dictionary = {}
var _bearing_preview_mouse := Vector2.INF
var _bearing_support_index := -1
var _bearing_support_body = null
var _bearing_draft_support := false

func _ready() -> void:
	source_surface = get_parent()
	z_index = 8
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	resize(source_surface.canvas_size)

func resize(size: Vector2i, offset := Vector2i.ZERO) -> void:
	if pixels == null or pixels.get_size() != size or offset != Vector2i.ZERO:
		var expanded := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
		if pixels != null:
			expanded.blit_rect(pixels, Rect2i(Vector2i.ZERO, pixels.get_size()), offset)
		pixels = expanded
		for index in anchor_points.size():
			anchor_points[index] += Vector2(offset)
		for rail in rails:
			rail["a"] = Vector2(rail.a) + Vector2(offset)
			rail["b"] = Vector2(rail.b) + Vector2(offset)
		for pin in slider_pins:
			pin["source"] = Vector2(pin.source) + Vector2(offset)
			pin["position"] = Vector2(pin.position) + Vector2(offset)
	refresh()

func refresh() -> void:
	if texture != null and texture.get_size() == Vector2(pixels.get_size()):
		texture.update(pixels)
	else:
		texture = ImageTexture.create_from_image(pixels)
	queue_redraw()

func _draw() -> void:
	if texture != null:
		draw_texture(texture, Vector2.ZERO)
	for point in anchor_points:
		if _black(point) and pixels.get_pixelv(Vector2i(point.floor())).a > 0:
			draw_texture(Hinge.BEARING, point - Vector2(5.5, 5.5))
	# 草稿里已经明确放置的轴承也要立即显示，而不是等固化后才出现。
	for record in source_surface.draft_bearings:
		var point := Vector2(record.get("position", Vector2.ZERO))
		if source_surface._inside(point):
			draw_texture(Hinge.BEARING, point - Vector2(5.5, 5.5))
	_draw_bearing_preview()
	for rail in rails:
		_draw_centerline(Vector2(rail.a), Vector2(rail.b))
	for pin in slider_pins:
		if _black(Vector2(pin.source)):
			_draw_slider_pin(Vector2(pin.position))
	if rail_drawing:
		var width := float(source_surface.brush_size)
		draw_line(rail_origin, rail_cursor, Palette.YELLOW.color, width, false)
		draw_line(rail_origin, rail_cursor, _rail_color(), 2.0, false)

func _rail_color() -> Color:
	var color: Color = Palette.YELLOW.color.darkened(0.48)
	color.a = 1.0
	return color

func _draw_centerline(a: Vector2, b: Vector2) -> void:
	var length := a.distance_to(b)
	var steps := maxi(1, ceili(length))
	var run_start := -1
	for index in steps + 1:
		var point := a.lerp(b, float(index) / steps)
		var visible: bool = source_surface._inside(point) and pixels.get_pixelv(Vector2i(point.floor())).a > 0
		if visible and run_start < 0:
			run_start = index
		if run_start >= 0 and (not visible or index == steps):
			var last := index if visible and index == steps else index - 1
			if last >= run_start:
				draw_line(a.lerp(b, float(run_start) / steps), a.lerp(b, float(last) / steps), _rail_color(), 2.0, false)
			run_start = -1

func _draw_slider_pin(point: Vector2) -> void:
	var rect := Rect2(point - Vector2(4.5, 4.5), Vector2(9.0, 9.0))
	draw_rect(rect, Color(0.08, 0.07, 0.02, 1.0), true)
	draw_rect(Rect2(point - Vector2(2.5, 2.5), Vector2(5.0, 5.0)), Palette.YELLOW.color, true)

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var rule = source_surface.yellow_rule()
	if rule != null:
		modulate.a = rule.yellow_opacity
	_update_bearing_preview()
	if not anchor_points.is_empty() or not _bearing_preview.is_empty():
		queue_redraw()


func _bearing_tool_active() -> bool:
	if source_surface == null or int(source_surface.get("tool")) != TOOL_CIRCLE:
		return false
	if source_surface.ink_material_id() != Palette.YELLOW.id:
		return false
	return source_surface._inside(source_surface._mouse_point())


func _update_bearing_preview() -> void:
	if not _bearing_tool_active():
		if not _bearing_preview.is_empty():
			_bearing_preview = {}
			_bearing_preview_mouse = Vector2.INF
			queue_redraw()
		return
	var point: Vector2 = source_surface._mouse_point()
	if point != _bearing_preview_mouse:
		_bearing_support_index = -1
		_bearing_support_body = null
		_bearing_draft_support = false
	_bearing_preview_mouse = point
	_bearing_preview = bearing_target(point.floor() + Vector2.ONE * 0.5)


## 预览与点击唯一的入口：按住 Alt 禁用吸附，允许偏心安装。
func _bearing_options() -> Dictionary:
	var options := {"snap": not Input.is_key_pressed(KEY_ALT), "support_index": _bearing_support_index}
	if _bearing_support_body != null:
		options["support_body"] = _bearing_support_body
	if _bearing_draft_support:
		options["draft_support"] = true
	return options


func bearing_target(point: Vector2) -> Dictionary:
	return GearBearings.resolve_target(source_surface, point, _bearing_options())


func _draw_bearing_preview() -> void:
	if _bearing_preview.is_empty():
		return
	var point: Vector2 = Vector2(_bearing_preview.get("position", Vector2.ZERO))
	if _bearing_preview.has("error"):
		draw_arc(point, 6.0, 0.0, TAU, 20, Color(0.8, 0.15, 0.12), 1.5, false)
		return
	draw_arc(point, 5.5, 0.0, TAU, 20, Palette.YELLOW.color, 1.5, false)
	draw_line(point + Vector2(-3, 0), point + Vector2(3, 0), Color(0.08, 0.07, 0.02), 1.0)
	draw_line(point + Vector2(0, -3), point + Vector2(0, 3), Color(0.08, 0.07, 0.02), 1.0)
	if _bearing_preview.get("support", null) != null:
		var support_point: Vector2 = Vector2(_bearing_preview.get("support_position", point))
		draw_arc(support_point, 7.0, 0.0, TAU, 20, Color(0.95, 0.72, 0.08, 0.85), 1.0, false)
		var support = _bearing_preview.support
		var box: Rect2 = support.aabb
		draw_rect(Rect2(source_surface.to_local(box.position), box.size), Color(1.0, 0.45, 0.08, 0.9), false, 1.5)

func _black(point: Vector2) -> bool:
	return source_surface._inside(point) and source_surface.material_at(int(point.x), int(point.y)) == Palette.BLACK.id

func begin(point: Vector2, erase := false) -> void:
	changed.clear()
	prior_anchors = anchor_points.duplicate()
	ink_delta = 0
	var rule = source_surface.yellow_rule()
	prior_springs = rule.draft_data(source_surface) if rule != null and erase else []
	erasing = erase
	last_point = point
	extend(point)

func extend(point: Vector2) -> void:
	var out := {}
	source_surface._brush_line(out, last_point, point)
	var health = source_surface._health_node()
	var room: int = int(source_surface._drawable_ink_room(Palette.YELLOW.id))
	var visual_changed := false
	for cell: Vector2i in out:
		if not source_surface._inside(Vector2(cell)):
			continue
		var had: bool = pixels.get_pixelv(cell).a > 0
		if had == not erasing or (not erasing and room <= 0):
			if not erasing and not had and room <= 0:
				source_surface._warn_ink_shortage(source_surface.MIN_PAINT_INK)
			continue
		if not changed.has(cell):
			changed[cell] = had
		if erasing:
			source_surface._remove_nail_at(cell)
		pixels.set_pixelv(cell, Color.TRANSPARENT if erasing else Palette.YELLOW.color)
		visual_changed = true
		var delta := -1 if erasing else 1
		ink_delta += delta
		if not source_surface.ink_free and health != null:
			health.reduce(Palette.YELLOW.id, delta)
		room -= delta
	if erasing:
		for index in range(anchor_points.size() - 1, -1, -1):
			if pixels.get_pixelv(Vector2i(anchor_points[index].floor())).a <= 0:
				anchor_points.remove_at(index)
				visual_changed = true
		source_surface.yellow_rule().erase_spring_ends(source_surface, last_point, point)
	last_point = point
	if not erasing and source_surface._ink_room(Palette.YELLOW.id) < source_surface.MIN_PAINT_INK:
		source_surface._warn_ink_shortage(source_surface.MIN_PAINT_INK)
	if visual_changed or erasing:
		refresh()

func finish(point: Vector2, record_undo := true) -> Dictionary:
	extend(point)
	var step := {"rod_pixels": changed.duplicate(), "rod_anchors": prior_anchors, "rod_delta": ink_delta}
	var springs_changed: bool = erasing and prior_springs != source_surface.yellow_rule().draft_data(source_surface)
	if springs_changed:
		step["rod_springs"] = prior_springs
	if not changed.is_empty() or prior_anchors != anchor_points or springs_changed:
		if record_undo:
			source_surface.push_undo_step(step)
		refresh()
		return step
	refresh()
	return {}

## 框删黄墨草稿；像素、轴系与墨水账由画布事务一起撤销。
func erase_rect(rect: Rect2i, mask: Dictionary = {}) -> bool:
	var clipped := rect.intersection(Rect2i(Vector2i.ZERO, pixels.get_size()))
	var removed := 0
	for y in range(clipped.position.y, clipped.end.y):
		for x in range(clipped.position.x, clipped.end.x):
			if not SelectionMask.contains(mask, Vector2i(x, y)):
				continue
			if pixels.get_pixel(x, y).a <= 0.5:
				continue
			source_surface._remove_nail_at(Vector2i(x, y))
			pixels.set_pixel(x, y, Color.TRANSPARENT)
			removed += 1
	var old_anchor_count := anchor_points.size()
	for index in range(anchor_points.size() - 1, -1, -1):
		var anchor := Vector2i(anchor_points[index].floor())
		if clipped.has_point(anchor) and SelectionMask.contains(mask, anchor):
			anchor_points.remove_at(index)
	var old_pin_count := slider_pins.size()
	slider_pins = slider_pins.filter(func(pin):
		for key in ["source", "position"]:
			var at := Vector2i(Vector2(pin[key]).floor())
			if clipped.has_point(at) and SelectionMask.contains(mask, at):
				return false
		return true)
	if removed == 0 and old_anchor_count == anchor_points.size() \
	and old_pin_count == slider_pins.size():
		return false
	if not source_surface.ink_free:
		var health = source_surface._health_node()
		if health != null:
			health.add(Palette.YELLOW.id, removed)
	refresh()
	return removed > 0 or old_anchor_count != anchor_points.size() \
	or old_pin_count != slider_pins.size()

## 选区移动同步移动像素、锚点和轨道元数据，不丢失新轴系。
func move_rect(rect: Rect2i, offset: Vector2i, mask: Dictionary = {}) -> bool:
	if offset == Vector2i.ZERO:
		return false
	var source := {}
	var clipped := rect.intersection(Rect2i(Vector2i.ZERO, pixels.get_size()))
	for y in range(clipped.position.y, clipped.end.y):
		for x in range(clipped.position.x, clipped.end.x):
			var point := Vector2i(x, y)
			if SelectionMask.contains(mask, point) and pixels.get_pixelv(point).a > 0.5:
				source[point] = pixels.get_pixelv(point)
	if source.is_empty():
		return false
	_move_rail_metadata(source, offset)
	for point: Vector2i in source:
		pixels.set_pixelv(point, Color.TRANSPARENT)
	var overwritten := 0
	for point: Vector2i in source:
		var target: Vector2i = point + offset
		if pixels.get_pixelv(target).a > 0.5:
			overwritten += 1
		pixels.set_pixelv(target, source[point])
	for index in anchor_points.size():
		var anchor := Vector2i(anchor_points[index].floor())
		if clipped.has_point(anchor) and SelectionMask.contains(mask, anchor):
			anchor_points[index] += Vector2(offset)
	for pin in slider_pins:
		for key in ["source", "position"]:
			var at := Vector2i(Vector2(pin[key]).floor())
			if clipped.has_point(at) and SelectionMask.contains(mask, at):
				pin[key] = Vector2(pin[key]) + Vector2(offset)
	if overwritten > 0 and not source_surface.ink_free:
		var health = source_surface._health_node()
		if health != null:
			health.add(Palette.YELLOW.id, overwritten)
	refresh()
	return true

## 被选区切开的轨道按中心线拆分，未选中片段留在原位。
func _move_rail_metadata(selected: Dictionary, offset: Vector2i) -> void:
	var updated: Array = []
	for rail in rails:
		var a := Vector2(rail.a)
		var b := Vector2(rail.b)
		var steps := maxi(1, ceili(a.distance_to(b)))
		var start := 0
		var moving: bool = selected.has(Vector2i(a.floor()))
		for index in range(1, steps + 2):
			var next_moving: bool = index <= steps and selected.has(Vector2i(a.lerp(b, float(index) / steps).floor()))
			if index <= steps and next_moving == moving:
				continue
			if index - 1 > start:
				var shift := Vector2(offset) if moving else Vector2.ZERO
				updated.append({"a": a.lerp(b, float(start) / steps) + shift,
					"b": a.lerp(b, float(index - 1) / steps) + shift, "width": rail.width})
			start = index
			moving = next_moving
	rails = updated

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB \
	and _bearing_tool_active() and int(_bearing_preview.get("support_count", 0)) > 1:
		_bearing_support_index = posmod(_bearing_support_index + 1, int(_bearing_preview.support_count))
		_bearing_support_body = null
		_bearing_draft_support = false
		_bearing_preview = bearing_target(source_surface._mouse_point().floor() + Vector2.ONE * 0.5)
		_bearing_support_body = _bearing_preview.get("support")
		_bearing_draft_support = _bearing_preview.get("kind") == "draft" and _bearing_support_body == null and not bool(_bearing_preview.get("fixed_to_world", true))
		queue_redraw()
		source_surface.notice_requested.emit("轴承支座 %d / %d（Tab 切换）" % [_bearing_support_index + 1, int(_bearing_preview.support_count)])
		get_viewport().set_input_as_handled()


func place_anchor(point: Vector2, options: Dictionary = {}) -> bool:
	var candidate := point.floor() + Vector2.ONE * 0.5
	var resolved := _bearing_options()
	resolved.merge(options, true)
	var target: Dictionary = GearBearings.resolve_target(source_surface, candidate, resolved)
	if not target.is_empty():
		if target.has("error"):
			source_surface.notice_requested.emit(str(target.error))
			return false
		if target.kind == "draft":
			var before_bearings: Array = source_surface.draft_bearings.duplicate(true)
			if not GearBearings.install(source_surface, target):
				return false
			source_surface.push_undo_step({"rod_pixels": {},
				"rod_anchors": anchor_points.duplicate(), "rod_delta": 0,
				"black_pixels": {"draft_bearings": before_bearings}})
		else:
			var canvas = source_surface.get_parent()
			var bounds := Rect2(source_surface.to_global(candidate - Vector2.ONE * 16.0), Vector2(32, 32))
			var state: Dictionary = History.capture(canvas, true, bounds)
			if not GearBearings.install(source_surface, target):
				return false
			History.commit(canvas, state)
		refresh()
		return true
	# 普通黄墨连接：黑墨与黄墨必须重叠，保留原有手动轴点语义。
	if not _black(candidate) or pixels.get_pixelv(Vector2i(candidate.floor())).a <= 0 or anchor_points.has(candidate):
		return false
	var before := anchor_points.duplicate()
	anchor_points.append(candidate)
	source_surface.push_undo_step({"rod_pixels": {}, "rod_anchors": before, "rod_delta": 0})
	refresh()
	return true

func begin_rail(point: Vector2) -> void:
	rail_drawing = true
	rail_origin = point.floor() + Vector2.ONE * 0.5
	rail_cursor = rail_origin
	queue_redraw()

func extend_rail(point: Vector2) -> void:
	if not rail_drawing:
		return
	rail_cursor = point.clamp(Vector2.ZERO, Vector2(source_surface.canvas_size) - Vector2.ONE)
	queue_redraw()

func finish_rail(point: Vector2) -> bool:
	if not rail_drawing:
		return false
	extend_rail(point)
	rail_drawing = false
	if rail_origin.distance_to(rail_cursor) < 3.0:
		var placed := place_slider_pin(rail_cursor)
		queue_redraw()
		return placed
	var before_rails: Array = rails.duplicate(true)
	var before_pins: Array = slider_pins.duplicate(true)
	var changed_pixels := {}
	var delta := _paint_rail(rail_origin, rail_cursor, source_surface.brush_size, changed_pixels)
	if changed_pixels.is_empty():
		queue_redraw()
		return false
	rails.append({"a": rail_origin, "b": rail_cursor, "width": source_surface.brush_size})
	source_surface.push_undo_step({"rod_pixels": changed_pixels, "rod_anchors": anchor_points.duplicate(),
		"rod_rails": before_rails, "rod_pins": before_pins, "rod_delta": delta})
	refresh()
	return true

func cancel_rail() -> void:
	rail_drawing = false
	queue_redraw()

func _paint_rail(a: Vector2, b: Vector2, width: int, changed_pixels: Dictionary) -> int:
	var direction := (b - a).normalized()
	var normal := direction.orthogonal()
	var length := a.distance_to(b)
	var half := maxf(0.5, width * 0.5)
	var low := Vector2i((a.min(b) - Vector2.ONE * half).floor()).max(Vector2i.ZERO)
	var high := Vector2i((a.max(b) + Vector2.ONE * half).ceil()).min(source_surface.canvas_size - Vector2i.ONE)
	var room: int = int(source_surface._ink_room(Palette.YELLOW.id))
	var health = source_surface._health_node()
	var delta := 0
	for y in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			var cell := Vector2i(x, y)
			var relative := Vector2(cell) + Vector2.ONE * 0.5 - a
			var along := relative.dot(direction)
			if along < 0.0 or along > length or absf(relative.dot(normal)) > half:
				continue
			if pixels.get_pixelv(cell).a > 0 or room <= 0:
				continue
			changed_pixels[cell] = false
			pixels.set_pixelv(cell, Palette.YELLOW.color)
			delta += 1
			room -= 1
			if not source_surface.ink_free and health != null:
				health.reduce(Palette.YELLOW.id, 1)
	return delta

func place_slider_pin(point: Vector2) -> bool:
	var source := point.floor() + Vector2.ONE * 0.5
	if not _black(source):
		return false
	var best: Dictionary = {}
	var best_distance := INF
	for rail in rails:
		var a := Vector2(rail.a)
		var b := Vector2(rail.b)
		var closest := Geometry2D.get_closest_point_to_segment(source, a, b)
		var distance := source.distance_to(closest)
		if distance <= float(rail.width) * 0.5 and distance < best_distance \
		and pixels.get_pixelv(Vector2i(closest.floor())).a > 0:
			best = {"source": source, "position": closest}
			best_distance = distance
	if best.is_empty():
		return false
	for pin in slider_pins:
		if Vector2(pin.source).distance_to(source) < 1.0:
			return false
	var before := slider_pins.duplicate(true)
	slider_pins.append(best)
	source_surface.push_undo_step({"rod_pixels": {}, "rod_anchors": anchor_points.duplicate(),
		"rod_rails": rails.duplicate(true), "rod_pins": before, "rod_delta": 0})
	refresh()
	return true

func erase_anchor(point: Vector2) -> bool:
	var host = GearBearings.host_of(source_surface)
	if host != null:
		var has_bearing := false
		for child in host.get_children():
			if child is Hinge and not child.is_queued_for_deletion() and not child.yellow_anchor.is_empty() \
			and source_surface.to_local(host.to_global(Stroke.anchor_world(child.yellow_anchor))).distance_to(point) <= 6.5:
				has_bearing = true
				break
		if not has_bearing:
			for record in source_surface.draft_bearings:
				if Vector2(record.get("position", Vector2.ZERO)).distance_to(point) <= 6.5:
					has_bearing = true
					break
		if has_bearing:
			var canvas = source_surface.get_parent()
			var bounds := Rect2(source_surface.to_global(point - Vector2.ONE * 16.0), Vector2(32, 32))
			var state: Dictionary = History.capture(canvas, true, bounds)
			if GearBearings.erase_at(source_surface, point):
				History.commit(canvas, state)
				refresh()
				return true
	for index in range(slider_pins.size() - 1, -1, -1):
		if Vector2(slider_pins[index].position).distance_squared_to(point) <= 30.25:
			var before_pins := slider_pins.duplicate(true)
			slider_pins.remove_at(index)
			source_surface.push_undo_step({"rod_pixels": {}, "rod_anchors": anchor_points.duplicate(),
				"rod_rails": rails.duplicate(true), "rod_pins": before_pins, "rod_delta": 0})
			refresh()
			return true
	var nearest := -1
	var nearest_distance := 5.5 * 5.5
	for index in anchor_points.size():
		var distance := anchor_points[index].distance_squared_to(point)
		if distance <= nearest_distance:
			nearest = index
			nearest_distance = distance
	if nearest < 0:
		return false
	var before := anchor_points.duplicate()
	anchor_points.remove_at(nearest)
	source_surface.push_undo_step({"rod_pixels": {}, "rod_anchors": before, "rod_delta": 0})
	refresh()
	return true

func undo(step: Dictionary) -> void:
	for cell: Vector2i in step.rod_pixels:
		pixels.set_pixelv(cell, Palette.YELLOW.color if step.rod_pixels[cell] else Color.TRANSPARENT)
	anchor_points = step.rod_anchors
	if step.has("rod_rails"):
		rails = step.rod_rails.duplicate(true)
	if step.has("rod_pins"):
		slider_pins = step.rod_pins.duplicate(true)
	if step.has("rod_springs"):
		source_surface.yellow_rule().restore_drafts(source_surface, step.rod_springs, true)
	var health = source_surface._health_node()
	if not source_surface.ink_free and health != null:
		health.add(Palette.YELLOW.id, step.rod_delta)
	refresh()

func clear(refund := true) -> void:
	if pixels == null:
		return
	if refund and not source_surface.ink_free:
		var count: int = make_shape().pixel_count()
		var health = source_surface._health_node()
		if health != null:
			health.add(Palette.YELLOW.id, count)
	pixels.fill(Color.TRANSPARENT)
	anchor_points.clear()
	rails.clear()
	slider_pins.clear()
	refresh()

func make_shape():
	var shape = Shape.new()
	var rect := pixels.get_used_rect()
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if pixels.get_pixel(x, y).a > 0:
				shape.set_pixel(x, y, Palette.YELLOW.id)
	return shape

func _rail_spans(rail: Dictionary, shape) -> Array:
	var a := Vector2(rail.a)
	var b := Vector2(rail.b)
	var steps := maxi(1, ceili(a.distance_to(b)))
	var spans: Array = []
	var start := -1
	for index in steps + 1:
		var point := a.lerp(b, float(index) / steps)
		var exists: bool = shape.get_pixel(int(floorf(point.x)), int(floorf(point.y))) == Palette.YELLOW.id
		if exists and start < 0:
			start = index
		if start >= 0 and (not exists or index == steps):
			var last := index if exists and index == steps else index - 1
			if last > start:
				spans.append([a.lerp(b, float(start) / steps), a.lerp(b, float(last) / steps)])
			start = -1
	return spans

func solidify(world, nail_state: Dictionary = {}, hub_centers: PackedVector2Array = PackedVector2Array()) -> void:
	var physics = world.world
	var solid = source_surface.get_parent().solid
	var fixed_nails: Dictionary = nail_state.get("fixed", {})
	var background_nails: Dictionary = nail_state.get("background", {})
	var infinite_nails: Dictionary = nail_state.get("infinite", {})
	var consumed_fixed := {}
	var consumed_background := {}
	var consumed_infinite := {}
	# 套在黄墨上的轮子不能被当成障碍物挖洞，否则杠杆会在轴心处被切成两段。
	# 这里在生成黄墨刚体之前先认出这些轮体（此刻世界里只有墨水刚体）。
	var hub_bodies: Array = []
	for center in hub_centers:
		var hub_at: Vector2 = world.to_local(source_surface.to_global(Vector2(center)))
		for body in physics.bodies:
			if body.tags.has("living") or hub_bodies.has(body):
				continue
			var hub_cell := Vector2i(body.to_local(hub_at).floor())
			for shape in body.shapes:
				if shape.get_pixel(hub_cell.x, hub_cell.y) != 0:
					hub_bodies.append(body)
					break
	for original in Destruction.split(make_shape(), 1):
		var anchors: Dictionary = {}
		var connected_bodies: Array = []
		for point in anchor_points:
			if original.get_pixel(int(point.x), int(point.y)) == 0:
				continue
			var at: Vector2 = world.to_local(source_surface.to_global(point))
			var black: Dictionary = Stroke.find_anchor(physics, at)
			if not black.is_empty():
				anchors[point] = black
				connected_bodies.append(black.body)
		for pin in slider_pins:
			if original.get_pixel(int(pin.position.x), int(pin.position.y)) == 0:
				continue
			var black: Dictionary = Stroke.find_anchor(physics, world.to_local(source_surface.to_global(Vector2(pin.source))))
			if not black.is_empty() and not connected_bodies.has(black.body):
				connected_bodies.append(black.body)
		var obstacles: Array = []
		for body in physics.bodies:
			if not connected_bodies.has(body) and not hub_bodies.has(body):
				obstacles.append(body)
		solid._remove_overlaps(original, source_surface, obstacles)
		for part in Destruction.split(original, 1):
			var part_fixed: Dictionary = solid._anchors_in_shape(part, fixed_nails)
			var part_background: Dictionary = solid._anchors_in_shape(part, background_nails)
			var part_infinite: Dictionary = solid._anchors_in_shape(part, infinite_nails)
			consumed_fixed.merge(part_fixed, true)
			consumed_background.merge(part_background, true)
			consumed_infinite.merge(part_infinite, true)
			solid._spawn_component(world, source_surface.global_position, part,
				part_fixed, part_background, false, not part_fixed.is_empty(),
				part_infinite, not part_infinite.is_empty(), false)
			for rail in rails:
				for span in _rail_spans(rail, part):
					var runtime_rail := Rail.new()
					runtime_rail.saved_a = world.to_local(source_surface.to_global(Vector2(span[0])))
					runtime_rail.saved_b = world.to_local(source_surface.to_global(Vector2(span[1])))
					runtime_rail.rail_width = int(rail.width)
					world.add_child(runtime_rail)
					runtime_rail.owner = world
			for point: Vector2 in anchors:
				if part.get_pixel(int(point.x), int(point.y)) == 0:
					continue
				var hinge := Hinge.new()
				hinge.yellow_position = world.to_local(source_surface.to_global(point))
				hinge.black_position = hinge.yellow_position
				world.add_child(hinge)
				hinge.owner = world
				hinge.restore()
	for pin in slider_pins:
		var source_world: Vector2 = world.to_local(source_surface.to_global(Vector2(pin.source)))
		if Stroke.find_anchor(physics, source_world).is_empty():
			continue
		var runtime_pin := SliderPin.new()
		runtime_pin.saved_source = source_world
		runtime_pin.saved_position = world.to_local(source_surface.to_global(Vector2(pin.position)))
		world.add_child(runtime_pin)
		runtime_pin.owner = world
	for point: Vector2i in consumed_fixed:
		source_surface.nail_layer.remove(point)
	for point: Vector2i in consumed_background:
		source_surface.nail_layer.remove(point)
	for point: Vector2i in consumed_infinite:
		source_surface.nail_layer.remove(point)
	clear(false)
	# 固化消费了黄墨和钉子，但不应退款；重数空画布以清掉只含黄墨时留下的账本。
	source_surface.recount_ink_px()
