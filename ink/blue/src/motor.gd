extends Node2D
## 箭头只记录一个黑色像素锚点；不创建刚体或关节。
## 管理箭头、锚点、到达能源缓冲和施力预算；energy_flow.gd 仅向缓冲投递。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Anchor := preload("res://ink/yellow/src/stroke.gd")

#region 数据与显示
@export var tip := Vector2.ZERO
@export var brush_width: int = 7
@export var active := false
@export var paid := false
@export var area: int = 0
@export var source_canvas: NodePath
## 到达功率的启动门、滑动窗口和爬坡；只平滑供能预算，不直接改最终施力。
@export_range(0.0, 0.5, 0.01) var startup_delay := 0.1
@export_range(0.02, 1.0, 0.01) var power_window := 0.2
@export_range(0.01, 0.5, 0.01) var force_ramp := 0.15
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
var _power_samples := PackedFloat32Array()
var _power_index := 0
var _power_sum := 0.0
var _power_filled := 0
var _stable_time := 0.0
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
func length_scale(exponent: float, minimum: float) -> float:
	return maxf(clampf(minimum, 0.0, 1.0), pow(minf(1.0, tip.length() / 120.0), exponent))

func power_limit(per_width: float, exponent := 2.0, minimum := 0.0) -> float:
	return brush_width * per_width * length_scale(exponent, minimum)

func consume(delta: float, force_per_length: float, power_per_width: float, idle_power: float,
		force_limit: float = INF, exponent := 2.0, minimum := 0.0) -> void:
	buffer_age += delta
	biological_age += delta
	var expired := false
	if biological_age >= hold_seconds - 0.000001:
		energy_buffer = maxf(0.0, energy_buffer - biological_energy)
		biological_energy = 0.0
	if buffer_age >= hold_seconds - 0.000001:
		energy_buffer = 0.0
		biological_energy = 0.0
		expired = true
	var instant_power := minf(power_limit(power_per_width, exponent, minimum),
		energy_buffer / maxf(delta, release_seconds))
	var smooth_power := _window_power(instant_power, delta)
	if smooth_power > 0.0:
		_stable_time = minf(_stable_time + delta, startup_delay + force_ramp + 1.0)
	else:
		_stable_time = maxf(0.0, _stable_time - delta)
	var gate := 0.0
	if _stable_time > startup_delay:
		gate = clampf((_stable_time - startup_delay) / maxf(force_ramp, 0.001), 0.0, 1.0)
	if expired:
		_stable_time = 0.0
		_power_sum = 0.0
		if not _power_samples.is_empty():
			_power_samples.fill(0.0)
		received_power = 0.0
	else:
		# 窗口只能重排缓冲里已经存在的能量，不能在空缓冲时凭空续力。
		received_power = minf(smooth_power * gate, instant_power)
	used_power = drive(received_power, delta, force_per_length, idle_power, force_limit, exponent, minimum)
	var fraction := biological_energy / maxf(energy_buffer, 0.001)
	energy_buffer = maxf(0.0, energy_buffer - used_power * delta)
	biological_energy = minf(energy_buffer, maxf(0.0, biological_energy - used_power * delta * fraction))
	if energy_buffer <= 0.0:
		energy_buffer = 0.0
		biological_energy = 0.0
		_stable_time = 0.0
		_power_sum = 0.0
		if not _power_samples.is_empty():
			_power_samples.fill(0.0)

## 环形缓冲的移动平均：固定步长下每个电机每帧 O(1)，不新建数组节点。
func _window_power(instant: float, delta: float) -> float:
	var count := maxi(1, roundi(power_window / maxf(delta, 0.001)))
	if _power_samples.size() != count:
		_power_samples.resize(count)
		_power_samples.fill(instant)
		_power_sum = instant * count
		_power_index = 0
		_power_filled = count
	_power_sum += instant - _power_samples[_power_index]
	_power_samples[_power_index] = instant
	_power_index = (_power_index + 1) % count
	_power_filled = mini(_power_filled + 1, count)
	if absf(_power_sum) < 0.000001:
		_power_sum = 0.0
	return _power_sum / maxf(_power_filled, 1.0)

func drive(available: float, delta: float, force_per_length: float, idle_power: float,
		force_limit: float = INF, exponent := 2.0, minimum := 0.0) -> float:
	applied_force = 0.0
	if available <= 0.0:
		return 0.0
	var base := minf(available, idle_power)
	var budget := maxf(0.0, available - base)
	var direction := tip.normalized().rotated(rotation)
	var force := minf(force_limit, tip.length() * force_per_length * length_scale(exponent, minimum))
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
	# 内部保持纯蓝，只把外轮廓栅格化；占用格与承载校验使用同一份像素足迹。
	for point in pixels_for(tip, brush_width):
		var at := Vector2i(point)
		draw_rect(Rect2(Vector2(at), Vector2.ONE), Palette.BLUE.color, true)

func _ready() -> void:
	z_index = 9
	if not source_canvas.is_empty():
		source_surface = get_parent().get_node_or_null(source_canvas)
	if active:
		call_deferred("restore")

func restore() -> void:
	var level := get_parent()
	if level != null and level.get("body_bake_pending") == true:
		await Signal(level, &"body_bake_completed")
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

## 和蓝墨覆盖层、刚体本体一致：在物理帧末尾更新变换，
## 渲染帧不再写位置，物理插值才能把箭头跟着轮体一起插值。
func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if active and body != null:
		sync_pose()

func valid(physics) -> bool:
	if body == null or not physics.bodies.has(body):
		return false
	var revision: Array = []
	for shape in body.shapes:
		if not is_instance_valid(shape):
			continue
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
