@tool
extends Node2D
## 黄色独立图层。复用 CanvasSurface 笔刷和 CanvasSolid 连通域/刚体生成。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")
const Hinge := preload("res://ink/yellow/src/hinge.gd")
const Stroke := preload("res://ink/yellow/src/stroke.gd")
@export var pixels: Image
@export var anchor_points: PackedVector2Array = []
var texture: ImageTexture
var source_surface
var last_point := Vector2.ZERO
var erasing := false
var changed: Dictionary = {}
var prior_anchors: PackedVector2Array
var ink_delta := 0
var prior_springs: Array = []

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
	refresh()

func refresh() -> void:
	texture = ImageTexture.create_from_image(pixels)
	queue_redraw()

func _draw() -> void:
	if texture != null:
		draw_texture(texture, Vector2.ZERO)
	for point in anchor_points:
		if _black(point) and pixels.get_pixelv(Vector2i(point.floor())).a > 0:
			draw_texture(Hinge.BEARING, point - Vector2(5.5, 5.5))

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var rule = source_surface.yellow_rule()
	if rule != null:
		modulate.a = rule.yellow_opacity
	if not anchor_points.is_empty():
		queue_redraw()

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
	var room: int = int(source_surface._ink_room(Palette.YELLOW.id))
	for cell: Vector2i in out:
		if not source_surface._inside(Vector2(cell)):
			continue
		var had: bool = pixels.get_pixelv(cell).a > 0
		if had == not erasing or (not erasing and room <= 0):
			continue
		if not changed.has(cell):
			changed[cell] = had
		pixels.set_pixelv(cell, Color.TRANSPARENT if erasing else Palette.YELLOW.color)
		var delta := -1 if erasing else 1
		ink_delta += delta
		if not source_surface.ink_free and health != null:
			health.reduce(Palette.YELLOW.id, delta)
		room -= delta
	if erasing:
		for index in range(anchor_points.size() - 1, -1, -1):
			if pixels.get_pixelv(Vector2i(anchor_points[index].floor())).a <= 0:
				anchor_points.remove_at(index)
		source_surface.yellow_rule().erase_spring_ends(source_surface, last_point, point)
	last_point = point
	refresh()

func finish(point: Vector2) -> void:
	extend(point)
	var step := {"rod_pixels": changed.duplicate(), "rod_anchors": prior_anchors, "rod_delta": ink_delta}
	var springs_changed: bool = erasing and prior_springs != source_surface.yellow_rule().draft_data(source_surface)
	if springs_changed:
		step["rod_springs"] = prior_springs
	if not changed.is_empty() or prior_anchors != anchor_points or springs_changed:
		source_surface.push_undo_step(step)
	refresh()

func place_anchor(point: Vector2) -> bool:
	var candidate := point.floor() + Vector2.ONE * 0.5
	if not _black(candidate) or pixels.get_pixelv(Vector2i(candidate.floor())).a <= 0 or anchor_points.has(candidate):
		return false
	var before := anchor_points.duplicate()
	anchor_points.append(candidate)
	source_surface.push_undo_step({"rod_pixels": {}, "rod_anchors": before, "rod_delta": 0})
	refresh()
	return true

func erase_anchor(point: Vector2) -> bool:
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
	refresh()

func make_shape():
	var shape = Shape.new()
	var rect := pixels.get_used_rect()
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if pixels.get_pixel(x, y).a > 0:
				shape.set_pixel(x, y, Palette.YELLOW.id)
	return shape

func solidify(world) -> void:
	var physics = world.world
	var solid = source_surface.get_parent().solid
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
		var obstacles: Array = []
		for body in physics.bodies:
			if not connected_bodies.has(body):
				obstacles.append(body)
		solid._remove_overlaps(original, source_surface, obstacles)
		for part in Destruction.split(original, 1):
			solid._spawn_component(world, source_surface.global_position, part, {}, false)
			for point: Vector2 in anchors:
				if part.get_pixel(int(point.x), int(point.y)) == 0:
					continue
				var hinge := Hinge.new()
				hinge.yellow_position = world.to_local(source_surface.to_global(point))
				hinge.black_position = hinge.yellow_position
				world.add_child(hinge)
				hinge.owner = world
				hinge.restore()
	clear(false)
