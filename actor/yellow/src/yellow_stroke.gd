extends Node2D

#region 数据
const Palette = preload("res://Ink/src/ink_palette.gd")
const Destruction = preload("res://addons/pixel_destruction/core/destruction.gd")
const PixelShape = preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const TERMINAL = preload("res://actor/yellow/asset/terminal.svg")
const NEIGHBORS: Array[Vector2i] = [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]
enum State { EDITING, ACTIVE, DYING, REMOVED }
@export var path: PackedVector2Array = []
@export var brush_width: int = 7
@export var rest_length: float = -1.0
@export var worn: PackedVector2Array = []
@export var saved_anchor_a: Vector2 = Vector2.ZERO
@export var saved_anchor_b: Vector2 = Vector2.ZERO
@export var activated: bool = false
var state: State = State.EDITING
var anchors: Array = []
var joint = null
var source_surface = null
@export var paid: bool = false
var cells: Dictionary = {}
var occupancy: PixelShape
var frontier: Dictionary = {}
var wear_pool: Array[Vector2i] = []
var wear_indices: Dictionary = {}
var original_area: int = 0
var wear_credit: float = 0.0
var wear_elapsed: float = 0.0
var fade: float = 0.0
var invalid_end: int = -1
var cut_index: float = 0.0
var image: Image
var texture: ImageTexture
var bounds: Rect2i
var visual: Sprite2D
var endpoint_a: Sprite2D
var endpoint_b: Sprite2D
var preview: bool = false
var rng = RandomNumberGenerator.new()
#endregion

#region 显示
func _ready() -> void:
	z_index = 8
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rng.randomize()
	if path.is_empty() or preview:
		return
	build_pixels()
	if activated:
		state = State.ACTIVE
		call_deferred("_restore")

func _restore() -> void:
	var world = get_parent().get("world")
	if world == null:
		return
	anchors = [find_anchor(world, saved_anchor_a), find_anchor(world, saved_anchor_b)]
	if anchors[0].is_empty() or anchors[1].is_empty():
		fail(0 if anchors[0].is_empty() else 1)
	else:
		var rule = get_parent().get_node("SimulationRuntime/YellowInk")
		if not rule.strokes.has(self):
			rule.strokes.append(self)
		rule.connect_stroke(self, world)

func _draw() -> void:
	if not preview or path.is_empty():
		return
	if path.size() > 1:
		draw_polyline(path, Palette.YELLOW.color, brush_width)
	draw_texture(TERMINAL, path[0] - Vector2(4.5, 4.5))
	draw_texture(TERMINAL, path[-1] - Vector2(4.5, 4.5))

func build_pixels() -> bool:
	cells.clear()
	if path.is_empty():
		return false
	var radius: float = maxf(0.5, (brush_width - 1) * 0.5)
	for index in maxi(1, path.size() - 1):
		var a: Vector2 = path[index]
		var b: Vector2 = path[mini(index + 1, path.size() - 1)]
		var steps: int = maxi(1, ceili(a.distance_to(b) * 2.0))
		for step in steps + 1:
			var center: Vector2 = a.lerp(b, float(step) / steps)
			var lo: Vector2i = Vector2i((center - Vector2.ONE * radius).floor())
			var hi: Vector2i = Vector2i((center + Vector2.ONE * radius).ceil())
			for y in range(lo.y, hi.y + 1):
				for x in range(lo.x, hi.x + 1):
					var p: Vector2i = Vector2i(x, y)
					if (Vector2(p) + Vector2.ONE * 0.5).distance_squared_to(center) <= radius * radius:
						cells[p] = float(index) + float(step) / steps
					if cells.size() > 65536:
						return false
	original_area = cells.size()
	for point in worn:
		cells.erase(Vector2i(point))
	occupancy = PixelShape.new()
	for p: Vector2i in cells:
		occupancy.set_pixel(p.x, p.y, 1)
	wear_pool.clear()
	wear_indices.clear()
	for p: Vector2i in cells:
		var center: Vector2 = Vector2(p) + Vector2.ONE * 0.5
		if center.distance_squared_to(path[0]) >= 20.25 and center.distance_squared_to(path[-1]) >= 20.25:
			wear_indices[p] = wear_pool.size()
			wear_pool.append(p)
	if cells.is_empty():
		return false
	var low: Vector2i = cells.keys()[0]
	var high: Vector2i = low
	for p: Vector2i in cells:
		low = low.min(p)
		high = high.max(p)
	bounds = Rect2i(low, high - low + Vector2i.ONE)
	if bounds.size.x * bounds.size.y > 4194304:
		return false
	image = Image.create_empty(bounds.size.x, bounds.size.y, false, Image.FORMAT_RGBA8)
	for p: Vector2i in cells:
		image.set_pixelv(p - bounds.position, Palette.YELLOW.color)
	texture = ImageTexture.create_from_image(image)
	visual = Sprite2D.new()
	visual.centered = false
	visual.position = Vector2(bounds.position)
	visual.texture = texture
	add_child(visual)
	endpoint_a = Sprite2D.new()
	endpoint_a.texture = TERMINAL
	endpoint_a.position = path[0]
	add_child(endpoint_a)
	endpoint_b = Sprite2D.new()
	endpoint_b.texture = TERMINAL
	endpoint_b.position = path[-1]
	add_child(endpoint_b)
	for point in worn:
		_add_frontier(Vector2i(point))
	return true

func update_visual() -> void:
	if anchors.size() != 2 or state != State.ACTIVE:
		return
	var a: Vector2 = anchor_world(anchors[0])
	var b: Vector2 = anchor_world(anchors[1])
	var original: Vector2 = path[-1] - path[0]
	var current: Vector2 = b - a
	var factor: float = current.length() / original.length() if original.length() > 0.001 else 1.0
	var angle: float = current.angle() - original.angle() if original.length() > 0.001 and current.length() > 0.001 else rotation
	transform = Transform2D(angle, Vector2.ONE * maxf(0.001, factor), 0.0,
		a - path[0].rotated(angle) * maxf(0.001, factor))
	endpoint_a.scale = Vector2.ONE / maxf(0.001, factor)
	endpoint_b.scale = endpoint_a.scale
	saved_anchor_a = a
	saved_anchor_b = b

func animate_death(delta: float) -> void:
	fade += delta / 0.3
	if fade >= 1.0:
		state = State.REMOVED
		visible = false
		visual.queue_free()
		endpoint_a.queue_free()
		endpoint_b.queue_free()
		visual = null
		image = null
		texture = null
		return
	var count: float = maxi(1, path.size() - 1) * fade
	# 消散只更新显示，不消耗可回收的剩余墨水。
	for p: Vector2i in cells:
		var nearest: float = cells[p]
		var erase: bool = nearest < count if invalid_end == 0 else nearest >= path.size() - 1 - count
		if invalid_end < 0:
			erase = absf(nearest - cut_index) < count
		if erase:
			image.set_pixelv(p - bounds.position, Color.TRANSPARENT)
	texture.update(image)
	endpoint_a.modulate.a = 1.0 - fade
	endpoint_b.modulate.a = 1.0 - fade
#endregion

#region 锚点与物理
static func find_anchor(world, point: Vector2) -> Dictionary:
	var result: Dictionary = {}
	for body in world.bodies:
		if body.tags.has("living") or not body.aabb.has_point(point):
			continue
		var cell: Vector2i = Vector2i(body.to_local(point).floor())
		if has_black(body, cell):
			if not result.is_empty():
				return {}
			result = {"body": body, "cell": cell, "local": body.to_local(point)}
	return result

static func has_black(body, cell: Vector2i) -> bool:
	for shape in body.shapes:
		if shape.get_pixel(cell.x, cell.y) == Palette.BLACK.id:
			return true
	return false

static func anchor_world(anchor: Dictionary) -> Vector2:
	return anchor.body.to_world(anchor.local)

func remove_joint() -> void:
	if joint != null and joint.is_active():
		joint.remove()
	joint = null

func rebind(world, body, replacements: Array) -> void:
	if state != State.ACTIVE:
		return
	var changed: bool = false
	for index in anchors.size():
		var anchor: Dictionary = anchors[index]
		if anchor.body != body:
			continue
		var found: Array = []
		for piece in replacements:
			if world.bodies.has(piece) and has_black(piece, anchor.cell):
				found.append(piece)
		if found.size() != 1:
			fail(index)
			return
		anchor.body = found[0]
		changed = true
	if changed:
		remove_joint()

func fail(end: int = -1) -> void:
	remove_joint()
	state = State.DYING
	invalid_end = end
	cut_index = rng.randf_range(0.4, 0.6) * maxi(1, path.size() - 1)
	activated = false
	owner = null

func _exit_tree() -> void:
	remove_joint()
	anchors.clear()
#endregion

#region 磨损
func _add_frontier(p: Vector2i) -> void:
	for offset in NEIGHBORS:
		var neighbor: Vector2i = p + offset
		if wear_indices.has(neighbor):
			frontier[neighbor] = true

func erode(amount: int) -> void:
	for iteration in mini(amount, 256):
		if wear_pool.is_empty():
			break
		var p: Vector2i
		if not frontier.is_empty() and rng.randf() < 0.9:
			var candidates: Array = frontier.keys()
			p = candidates[rng.randi_range(0, candidates.size() - 1)]
		else:
			p = wear_pool[rng.randi_range(0, wear_pool.size() - 1)]
		var index: int = wear_indices[p]
		var last: Vector2i = wear_pool[-1]
		wear_pool[index] = last
		wear_indices[last] = index
		wear_pool.pop_back()
		wear_indices.erase(p)
		cells.erase(p)
		occupancy.clear_pixel(p.x, p.y)
		frontier.erase(p)
		worn.append(Vector2(p))
		_add_frontier(p)
		image.set_pixelv(p - bounds.position, Color.TRANSPARENT)
	texture.update(image)
	if not connected():
		fail()

func connected() -> bool:
	var start: Vector2i = Vector2i(path[0].floor())
	var end: Vector2i = Vector2i(path[-1].floor())
	if not cells.has(start) or not cells.has(end):
		return false
	var key_a: int = PixelShape.make_key(start.x >> 3, start.y >> 3)
	var key_b: int = PixelShape.make_key(end.x >> 3, end.y >> 3)
	var bit_a: int = 1 << ((start.y & 7) * 8 + (start.x & 7))
	var bit_b: int = 1 << ((end.y & 7) * 8 + (end.x & 7))
	for component: Dictionary in Destruction.components(occupancy).values():
		if (int(component.get(key_a, 0)) & bit_a) != 0:
			return (int(component.get(key_b, 0)) & bit_b) != 0
	return false
#endregion
