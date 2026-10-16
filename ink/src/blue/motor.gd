extends Node2D
## 箭头只记录一个黑色像素锚点；不创建刚体或关节。
## 管理箭头、锚点、到达能源缓冲和施力预算；energy_flow.gd 仅向缓冲投递。
const Palette := preload("res://ink/src/ink_palette.gd")
const Anchor := preload("res://ink/src/yellow/stroke.gd")

#region 数据与显示
@export var tip := Vector2.ZERO
@export var brush_width: int = 7
@export var active := false
@export var paid := false
@export var area: int = 0
@export var source_canvas: NodePath
var body = null
var cell := Vector2i.ZERO
var anchor_local := Vector2.ZERO
var source_surface = null
var preview := false
var received_power := 0.0
var used_power := 0.0
var applied_force := 0.0
var energy_buffer := 0.0 # 焦耳，瞬态，不写入编辑草稿和 PackedScene。
var biological_energy := 0.0
var biological_age := 0.0
var buffer_capacity := 0.0
var release_seconds := 0.1
var hold_seconds := 0.2
var buffer_age := 0.0
var support_cells := PackedVector2Array()
var _support_revision: Array = []
var _coverage_shape: Array = []
var _coverage: Dictionary = {}

## 与绘制相同的实心箭头足迹，按主轴扫描，避免斜箭头扫描整个大包围盒。
static func pixels_for(vector: Vector2, width: int) -> PackedVector2Array:
	var pixels := {}
	var length := vector.length()
	if length < 0.01:
		return PackedVector2Array()
	var direction := vector / length
	var back := vector - direction * minf(length, maxf(6.0, width * 2.0))
	var radius := width * 0.5
	var swap := absf(direction.y) > absf(direction.x)
	var end := Vector2(back.y, back.x) if swap else back
	if back.length() > 0.01:
		for a in range(floori(minf(0, end.x) - radius), ceili(maxf(0, end.x) + radius) + 1):
			var center := float(a) * end.y / end.x
			var spread := radius * 1.5 + 1.0
			for b in range(floori(center - spread), ceili(center + spread) + 1):
				var point := Vector2(b, a) if swap else Vector2(a, b)
				var along := point.dot(direction)
				if along >= 0.0 and along <= back.length() and absf(point.cross(direction)) <= radius:
					pixels[Vector2i(point)] = true
	var triangle := PackedVector2Array([vector, back + direction.orthogonal() * width, back - direction.orthogonal() * width])
	var bounds := Rect2(triangle[0], Vector2.ZERO).expand(triangle[1]).expand(triangle[2])
	for y in range(floori(bounds.position.y), ceili(bounds.end.y) + 1):
		for x in range(floori(bounds.position.x), ceili(bounds.end.x) + 1):
			if Geometry2D.is_point_in_polygon(Vector2(x, y), triangle):
				pixels[Vector2i(x, y)] = true
	return PackedVector2Array(pixels.keys())

func covers(point: Vector2) -> bool:
	if _coverage_shape != [tip, brush_width]:
		_coverage_shape = [tip, brush_width]
		_coverage.clear()
		for at in pixels_for(tip, brush_width):
			_coverage[Vector2i(at)] = true
	return _coverage.has(Vector2i(to_local(point).round()))

func supported_on(target, points: PackedVector2Array) -> bool:
	for at in points:
		if not Anchor.has_black(target, Vector2i(at)):
			return false
	return not points.is_empty()

func _support_on(target) -> PackedVector2Array:
	var points := PackedVector2Array()
	for offset in pixels_for(tip, brush_width):
		points.append(Vector2(Vector2i(target.to_local(to_global(offset)).floor())))
	return points

func available_room() -> float:
	return maxf(0.0, buffer_capacity - energy_buffer)

func receive_energy(energy: float, biological: float = 0.0) -> float:
	var taken := minf(maxf(0.0, buffer_capacity - energy_buffer), energy)
	energy_buffer += taken
	biological_energy += taken * clampf(biological / maxf(energy, 0.001), 0.0, 1.0)
	if biological > 0.0:
		biological_age = 0.0
	if taken > 0.0:
		buffer_age = 0.0
	return taken

## 能源已在发出时收费；这里只按实际施力消耗电机缓冲，不再回溯电源。
func power_limit(per_width: float) -> float:
	return brush_width * per_width * pow(minf(1.0, tip.length() / 120.0), 2.0)

func consume(delta: float, force_per_length: float, power_per_width: float, idle_power: float, force_limit: float = INF) -> void:
	buffer_age += delta
	biological_age += delta
	if biological_age > hold_seconds:
		energy_buffer = maxf(0.0, energy_buffer - biological_energy)
		biological_energy = 0.0
	if buffer_age > hold_seconds:
		energy_buffer = 0.0
		biological_energy = 0.0
	received_power = minf(power_limit(power_per_width), energy_buffer / maxf(delta, release_seconds))
	used_power = drive(received_power, delta, force_per_length, idle_power, force_limit)
	var fraction := biological_energy / maxf(energy_buffer, 0.001)
	energy_buffer = maxf(0.0, energy_buffer - used_power * delta)
	biological_energy = minf(energy_buffer, maxf(0.0, biological_energy - used_power * delta * fraction))

func drive(available: float, delta: float, force_per_length: float, idle_power: float, force_limit: float = INF) -> float:
	applied_force = 0.0
	if available <= 0.0:
		return 0.0
	var base := minf(available, idle_power)
	var budget := maxf(0.0, available - base)
	var direction := tip.normalized().rotated(rotation)
	var force := minf(force_limit, tip.length() * force_per_length * pow(minf(1.0, tip.length() / 120.0), 2.0))
	var arm: Vector2 = position - body.com_world()
	var cross := arm.cross(direction)
	var inverse_mass: float = body.inv_mass + cross * cross * body.inv_inertia
	var velocity: float = body.velocity_at(position).dot(direction)
	var a: float = 0.5 * force * force * inverse_mass * delta
	var b := absf(force * velocity)
	var scale := 0.0
	if budget > 0.0:
		scale = minf(1.0, 2.0 * budget / maxf(b + sqrt(b * b + 4.0 * a * budget), 0.001))
	force *= scale
	applied_force = force
	body.apply_impulse(direction * force * delta, position)
	return base + a * scale * scale + b * scale

func _draw() -> void:
	var color: Color = Palette.BLUE.color
	if tip.length() > 0.01:
		var direction := tip.normalized()
		var back := tip - direction * minf(tip.length(), maxf(6.0, brush_width * 2.0))
		draw_line(Vector2.ZERO, back, color, brush_width)
		draw_colored_polygon(PackedVector2Array([tip, back + direction.orthogonal() * brush_width, back - direction.orthogonal() * brush_width]), color)

func _ready() -> void:
	z_index = 9
	if not source_canvas.is_empty():
		source_surface = get_parent().get_node_or_null(source_canvas)
	if active:
		call_deferred("restore")

func restore() -> void:
	if body != null:
		return
	var physics = get_parent().get("world")
	if physics == null:
		return
	var anchor: Dictionary = Anchor.find_anchor(physics, position)
	if anchor.is_empty():
		queue_free()
	else:
		bind(anchor)

func bind(anchor: Dictionary) -> void:
	var points := _support_on(anchor.body)
	if not supported_on(anchor.body, points):
		body = null
		queue_free()
		return
	body = anchor.body
	support_cells = points
	_support_revision.clear()
	cell = anchor.cell
	anchor_local = anchor.local
	rotation -= body.rotation
	# rotation 在激活时转换为刚体局部方向；每帧同步后另存该方向。
	set_meta("local_angle", rotation)
	active = true
	sync_pose()

func sync_pose() -> void:
	if body == null:
		return
	position = body.to_world(anchor_local)
	rotation = body.rotation + float(get_meta("local_angle", 0.0))

func _process(_delta: float) -> void:
	if active and body != null:
		sync_pose()

func valid(physics) -> bool:
	if body == null or not physics.bodies.has(body):
		return false
	var revision: Array = []
	for shape in body.shapes:
		revision.append(shape.get_instance_id())
		revision.append(shape.revision)
	if revision != _support_revision:
		_support_revision = revision
		return supported_on(body, support_cells)
	return true

func rebind(physics, old_body, pieces: Array) -> void:
	if body != old_body:
		return
	sync_pose()
	var point: Vector2 = position
	var direction: float = rotation
	for piece in pieces:
		var at := Vector2i(piece.to_local(point).floor())
		if physics.bodies.has(piece) and supported_on(piece, _support_on(piece)):
			rotation = direction
			bind({"body": piece, "cell": at, "local": piece.to_local(point)})
			return
	body = null
	queue_free()
#endregion
