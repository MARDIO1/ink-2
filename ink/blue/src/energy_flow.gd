extends RefCounted
## 能源生产与接触适配：数值推进在 ink/native，GDScript 保留燃料和场景接口。
## 不建全局电网。缓存仅记录局部接触，形状/相对姿态改变时更新。
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Traits := preload("res://ink/general/src/ink_traits.gd")
const DIRS: Array[Vector2i] = [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]
var speed := 600.0
var interval := 0.1
var lifetime := 20.0
var minimum_energy := 1.0
var pixel_power := 100000000.0
var biological_producer := 0
var clock := 0
var distance_credit := 0.0
var consumers: Dictionary = {}
var neighbours: Dictionary = {}
var bridges: Dictionary = {}
var fuel: Dictionary = {}
var source_bounds: Dictionary = {}
var contact_cache: Dictionary = {}
var motor_cache: Dictionary = {}
var emit_elapsed := 0.0
var fuel_elapsed := 0.0
var first_emission := true
var _local_stamp: Array = []
var stats := {"injected": 0.0, "consumed": 0.0, "lost": 0.0, "updates": 0, "shorts": 0}
var _native: Object = null
var _ids: Dictionary = {}
var _layouts: Dictionary = {}
var _serial := 0
var _pending: Array = []
var _stored := 0.0
var _active := 0
var _template := PackedByteArray()
var _binary_contact_key: Array = []
var _native_motors: Array = []

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_native):
		_native.free()

func _ensure() -> void:
	if _native != null:
		return
	if not ClassDB.class_exists("InkEnergyGrid"):
		GDExtensionManager.load_extension("res://ink/blue/native/ink_energy.gdextension")
	assert(ClassDB.class_exists("InkEnergyGrid"), "InkEnergyGrid missing: build ink/native then import project")
	_native = ClassDB.instantiate("InkEnergyGrid")

func _call(commands: PackedByteArray) -> StreamPeerBuffer:
	_ensure()
	if _template.is_empty():
		_template.resize(65536)
	var input := PackedByteArray()
	input.resize(8)
	input.encode_s32(0, _template.size() - 4)
	input.encode_s32(4, commands.size())
	input.append_array(commands)
	var output: PackedByteArray = _native.step(input, _template)
	var size := output.decode_s32(0)
	if size == 4 and output.decode_s32(4) < -1:
		_template.resize((-output.decode_s32(4) + 4099) / 4096 * 4096)
		var retry := commands
		if commands.decode_s32(0) != 12:
			retry = PackedByteArray()
			retry.resize(4)
			retry.encode_s32(0, 13)
		input.resize(8)
		input.encode_s32(0, _template.size() - 4)
		input.encode_s32(4, retry.size())
		input.append_array(retry)
		output = _native.step(input, _template)
		size = output.decode_s32(0)
	assert(size > 0 and size < _template.size(), "Energy kernel output error")
	var result := StreamPeerBuffer.new()
	result.data_array = output.slice(4, size + 4)
	return result

func inject(wire, at: Vector2i, direction: int, energy: float, producer: int = 0) -> void:
	if energy > 0.0 and wire.mask.has(at):
		_pending.append([wire, at, direction, energy, producer])

func _vectors(buffer: StreamPeerBuffer, count: int) -> PackedVector2Array:
	# 使用 Godot 原生 Variant 解码，避免为每个显示点逐个调用 get_float。
	var encoded := PackedByteArray()
	encoded.resize(8)
	encoded.encode_u32(0, TYPE_PACKED_VECTOR2_ARRAY)
	encoded.encode_u32(4, count)
	encoded.append_array(buffer.get_data(count * 8)[1])
	return bytes_to_var(encoded)

func advance(wires: Array, delta: float) -> void:
	var commands := StreamPeerBuffer.new()
	var by_id := {}
	for old in _ids.keys():
		if not wires.has(old):
			commands.put_32(9)
			commands.put_32(_ids[old])
			_ids.erase(old)
			_layouts.erase(old)
			contact_cache.erase(old)
	for wire in wires:
		if not _ids.has(wire):
			_serial += 1
			_ids[wire] = _serial
		var id: int = _ids[wire]
		by_id[id] = wire
		if _layouts.get(wire, -1) != wire.layout_version:
			commands.put_32(1)
			commands.put_32(id)
			var pixels: PackedVector2Array = wire.cells
			commands.put_32(pixels.size())
			commands.put_data(pixels.to_byte_array())
			_layouts[wire] = wire.layout_version
		commands.put_32(2)
		commands.put_32(id)
		commands.put_double(wire.body.position.x)
		commands.put_double(wire.body.position.y)
		commands.put_double(wire.body.rotation)
	commands.put_32(11)
	commands.put_double(pixel_power * interval)
	commands.put_64(maxi(1, ceili(lifetime * speed)))
	commands.put_double(minimum_energy)
	commands.put_64(biological_producer)
	var contact_key: Array = [_serial, _local_stamp]
	for wire in wires:
		contact_key.append(_ids[wire])
		var ids: Array = []
		for other in neighbours.get(wire, []):
			ids.append(_ids[other])
		contact_key.append(ids)
	if contact_key != _binary_contact_key:
		_binary_contact_key = contact_key
		commands.put_32(4)
		_native_motors.clear()
		for wire in wires:
			var id: int = _ids[wire]
			for at: Vector2i in consumers.get(wire, {}):
				for motor in consumers[wire][at]:
					if not _native_motors.has(motor):
						_native_motors.append(motor)
					commands.put_32(5)
					commands.put_32(id)
					commands.put_32(at.x)
					commands.put_32(at.y)
					commands.put_32(_native_motors.find(motor))
			commands.put_32(7)
			commands.put_32(id)
			commands.put_32(neighbours.get(wire, []).size())
			for other in neighbours.get(wire, []):
				commands.put_32(_ids[other])
			for at: Vector2i in bridges.get(wire, {}):
				var target: Array = bridges[wire][at]
				commands.put_32(6)
				commands.put_32(id)
				commands.put_32(at.x)
				commands.put_32(at.y)
				commands.put_32(_ids[target[0]])
				commands.put_32(target[1].x)
				commands.put_32(target[1].y)
	for injection: Array in _pending:
		if not _ids.has(injection[0]):
			continue
		commands.put_32(14 if injection.size() > 5 else 3)
		commands.put_32(_ids[injection[0]])
		commands.put_32(injection[1].x)
		commands.put_32(injection[1].y)
		commands.put_32(injection[2])
		commands.put_double(injection[3])
		if injection.size() > 5:
			for index in range(4, 7):
				commands.put_64(injection[index])
			commands.put_32(injection[7])
			commands.put_64(injection[8])
			commands.put_32(injection[9])
		else:
			commands.put_64(injection[4])
	_pending.clear()
	distance_credit += maxf(0.0, speed) * delta
	var steps := int(distance_credit)
	distance_credit -= steps
	commands.put_32(10)
	commands.put_32(steps)
	commands.put_32(_native_motors.size())
	for motor in _native_motors:
		var room: float = motor.available_room() if motor.has_method("available_room") else 1.0e100
		commands.put_double(room)
	var phase_start := Time.get_ticks_usec()
	var result := _call(commands.data_array)
	stats["kernel_us"] = stats.get("kernel_us", 0) + Time.get_ticks_usec() - phase_start
	phase_start = Time.get_ticks_usec()
	var status := result.get_32()
	assert(status == 0, "Energy native command rejected")
	clock = result.get_64()
	stats.injected = result.get_double()
	stats.consumed = result.get_double()
	stats.lost = result.get_double()
	_stored = result.get_double()
	stats.updates = result.get_64()
	stats.shorts = result.get_64()
	for i in result.get_32():
		var energy := result.get_double()
		var bio := result.get_double()
		if _native_motors[i].has_method("available_room"):
			_native_motors[i].receive_energy(energy, bio)
		else:
			_native_motors[i].receive_energy(energy)
	_active = 0
	for i in result.get_32():
		var wire = by_id[result.get_32()]
		var count := result.get_32()
		_active += count
		var heads := _vectors(result, count)
		var energies: PackedFloat32Array = result.get_data(count * 4)[1].to_float32_array()
		var tails := _vectors(result, result.get_32())
		# 读游标不能藏在 assert 里，否则 release 导出移除断言后会错位。
		var deleted_count := result.get_32()
		var flash_count := result.get_32()
		assert(deleted_count == 0 and flash_count == 0, "Energy flow must not cut or flash wires")
		var display_start := Time.get_ticks_usec()
		wire.show_energy_points(heads, tails, energies, maxf(pixel_power * interval, 1.0))
		stats["display_us"] = stats.get("display_us", 0) + Time.get_ticks_usec() - display_start
	stats["decode_us"] = stats.get("decode_us", 0) + Time.get_ticks_usec() - phase_start

func state(wire) -> Dictionary:
	# 仅供碎裂迁移与测试读取；正常推进和显示不复制方向字典。
	if not _ids.has(wire):
		return {"front": {}}
	var command := StreamPeerBuffer.new()
	command.put_32(12)
	command.put_32(_ids[wire])
	var result := _call(command.data_array)
	var front := {}
	for i in result.get_32():
		var at := Vector2i(result.get_32(), result.get_32())
		var energy := Vector4(result.get_double(), result.get_double(), result.get_double(), result.get_double())
		front[at] = [energy, result.get_64(), result.get_64(), result.get_64(), result.get_32(), result.get_64(), result.get_32()]
	return {"front": front}

func stored_energy() -> float:
	return _stored

func active_cells() -> int:
	return _active

func rebind_wire(old, replacements: Array) -> void:
	var data := state(old)
	for at: Vector2i in data.front:
		var point: Vector2 = old.body.to_world(Vector2(at) + Vector2.ONE * 0.5)
		for wire in replacements:
			var cell := Vector2i(wire.body.to_local(point).floor())
			if wire.mask.has(cell):
				for d in 4:
					if data.front[at][0][d] > 0.0:
						_pending.append([wire, cell, d, data.front[at][0][d], data.front[at][1], data.front[at][2], data.front[at][3], data.front[at][4], data.front[at][5], data.front[at][6]])
				break

func update(rule, context: Dictionary) -> Dictionary:
	var physics = context.world
	var wires: Array = []
	for wire in rule.objects(rule.Wire):
		if wire.active and wire.body != null and physics.bodies.has(wire.body):
			wire.prune(physics)
			if not wire.is_queued_for_deletion():
				wires.append(wire)
	var motors: Array = []
	for motor in rule.objects(rule.Motor):
		if motor.active:
			if not motor.valid(physics):
				motor.queue_free()
				continue
			motor.sync_pose()
			motor.buffer_capacity = motor.power_limit(rule.power_per_width,
				rule.short_falloff_exponent, rule.short_min_scale) * rule.motor_buffer_seconds
			motor.release_seconds = interval
			motor.hold_seconds = maxf(rule.motor_buffer_seconds, interval * 1.1)
			motors.append(motor)
	var phase_start := Time.get_ticks_usec()
	_rebuild_local_contacts(rule, wires, motors)
	stats["contacts_us"] = stats.get("contacts_us", 0) + Time.get_ticks_usec() - phase_start
	var delta: float = context.pixel_world.fixed_dt
	emit_elapsed += delta
	if first_emission or emit_elapsed >= interval:
		first_emission = false
		emit_elapsed = fmod(emit_elapsed, interval)
		phase_start = Time.get_ticks_usec()
		_emit(rule, context, wires)
		stats["emit_us"] = stats.get("emit_us", 0) + Time.get_ticks_usec() - phase_start
	phase_start = Time.get_ticks_usec()
	advance(wires, delta)
	stats["advance_us"] = stats.get("advance_us", 0) + Time.get_ticks_usec() - phase_start
	var player = context.get("player_node")
	var bio_force := 0.0
	if player != null:
		var mass: float = player.body.mass + player.get_node("Arm").body.mass + player.get_node("Arm/Hand").body.mass
		bio_force = mass * physics.gravity.length() * rule.biological_force_weight_ratio
	for motor in motors:
		if motor.is_queued_for_deletion():
			continue
		var biological: bool = motor.biological_energy > 0.0
		motor.consume(delta, rule.force_per_length, rule.power_per_width, rule.idle_power,
			bio_force if biological else INF, rule.short_falloff_exponent, rule.short_min_scale)
		if biological:
			bio_force = maxf(0.0, bio_force - motor.applied_force)
	var result := {}
	# 发包时扣能源，整像素耗料批量提交到不引爆红色的燃料入口。
	fuel_elapsed += delta
	if fuel_elapsed < rule.fuel_interval:
		return {"fuel_removals": result}
	fuel_elapsed = fmod(fuel_elapsed, maxf(delta, rule.fuel_interval))
	for body in source_bounds.keys():
		if not physics.bodies.has(body):
			source_bounds.erase(body)
	for wire in contact_cache:
		for body in contact_cache[wire].keys():
			if not physics.bodies.has(body):
				contact_cache[wire].erase(body)
	for body in fuel.keys():
		if not physics.bodies.has(body):
			fuel.erase(body)
			continue
		var account: Dictionary = fuel[body]
		_settle_fuel_account(rule, body, account, result)
	return {"fuel_removals": result}

func _settle_fuel_account(rule, body, account: Dictionary, result: Dictionary) -> void:
	if Traits.is_unbreakable(body):
		return
	var count := int(account.credit)
	if count <= 0:
		return
	var protected: Dictionary = account.contacts
	var selected := {}
	# 固定 7x7（默认半径 3）局部查找；由外向内，避免先把接触层挖掉。
	for radius in range(rule.fuel_contact_radius, 0, -1):
		if count <= 0:
			break
		for origin: Vector2i in protected:
			for y in range(-radius, radius + 1):
				for x in range(-radius, radius + 1):
					if maxi(absi(x), absi(y)) != radius:
						continue
					var cell := origin + Vector2i(x, y)
					if protected.has(cell) or selected.has(cell):
						continue
					var shape = _red_shape_at(body, cell)
					if shape != null:
						result.get_or_add(body, {}).get_or_add(shape, {})[cell] = true
						selected[cell] = true
						account.credit -= 1.0
						count -= 1
						if count <= 0:
							break
				if count <= 0:
					break
	# 附近燃料已经用尽时才允许删除当前端子像素。
	for cell: Vector2i in protected:
		if count <= 0:
			break
		var shape = _red_shape_at(body, cell)
		if shape != null:
			result.get_or_add(body, {}).get_or_add(shape, {})[cell] = true
			account.credit -= 1.0
			count -= 1

func _red_shape_at(body, cell: Vector2i):
	for shape in body.shapes:
		if shape.get_pixel(cell.x, cell.y) == Palette.RED.id:
			return shape
	return null

func _rect_world(body, rect: Rect2) -> Rect2:
	var result := Rect2(body.to_world(rect.position), Vector2.ZERO)
	for p in [Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
		result = result.expand(body.to_world(p))
	return result

func _revision(body) -> Array:
	var result: Array = []
	for shape in body.shapes:
		result.append(shape.get_instance_id())
		result.append(shape.revision)
	return result

func _bounds(body) -> Rect2:
	# 当前运行时形状只删除像素；同一形状删后旧范围仍是安全的保守包围盒。
	# 形状替换/新建或 living 身份变化则重扫，避免每次燃烧遍历整块黑色载体。
	var identity: Array = [body.tags.has("living")]
	for shape in body.shapes:
		identity.append(shape.get_instance_id())
	var cached: Dictionary = source_bounds.get(body, {})
	if cached.get("identity", []) == identity:
		return cached.rect
	var rect := Rect2()
	var regions: Array[Rect2] = []
	for shape in body.shapes:
		if body.tags.has("living"):
			var part: Rect2 = Rect2(shape.local_aabb())
			regions.append(part)
			rect = rect.merge(part) if rect.has_area() else part
		else:
			for key: int in shape.chunks:
				if shape.chunks[key].mat.has(Palette.RED.id):
					var part := Rect2(Shape.key_x(key) * 8, Shape.key_y(key) * 8, 8, 8)
					regions.append(part)
					rect = rect.merge(part) if rect.has_area() else part
	source_bounds[body] = {"identity": identity, "rect": rect, "regions": regions}
	return rect

func _source_contacts(wire, body) -> Dictionary:
	# 局部烧断不改变其他能源接触几何；发包时逐端口验证 mask 即可。
	# 否则远处每次短路都会重扫所有红色接触，产生周期性长帧。
	var stamp: Array = [_revision(body), wire.layout_version]
	if body != wire.body:
		stamp.append(wire.body.to_local(body.position))
		stamp.append(body.rotation - wire.body.rotation)
	var pairs: Dictionary = contact_cache.get_or_add(wire, {})
	var cached: Dictionary = pairs.get(body, {})
	if cached.get("stamp", []) == stamp:
		return cached.cells
	# 多处能源不能取一个大包围盒再扫描其中的整张导线。
	# 按已有 8×8 红色块局部取候选，复杂走线的其他像素不会参与找电源。
	var candidates := {}
	for region: Rect2 in source_bounds[body].regions:
		var local: Rect2 = region.grow(1.0)
		if body != wire.body:
			var bounds := _rect_world(body, region).grow(1.5)
			local = Rect2(wire.body.to_local(bounds.position), Vector2.ZERO)
			for point: Vector2 in [Vector2(bounds.end.x, bounds.position.y), bounds.end, Vector2(bounds.position.x, bounds.end.y)]:
				local = local.expand(wire.body.to_local(point))
		for at: Vector2i in wire.pixels_in_rect(local):
			candidates[at] = true
	var cells := {}
	for at: Vector2i in candidates:
		var point: Vector2 = wire.body.to_world(Vector2(at) + Vector2.ONE * 0.5)
		for d in 4:
			var cell: Vector2i = at + DIRS[d] if body == wire.body else Vector2i(body.to_local(point + Vector2(DIRS[d])).floor())
			var material: int = wire.material_at(body, cell)
			if material == Palette.RED.id or (body.tags.has("living") and material != 0):
				cells.get_or_add(cell, []).append([wire, at, d ^ 1])
	pairs[body] = {"stamp": stamp, "cells": cells}
	return cells

func _emit(rule, context: Dictionary, wires: Array) -> void:
	var player = context.get("player_node")
	var player_bodies: Array = []
	if player != null:
		player_bodies = [player.body, player.get_node("Arm").body, player.get_node("Arm/Hand").body]
	biological_producer = player.get_instance_id() if player != null else 0
	var groups := {}
	for body in context.world.bodies:
		# 玩家只能通过有效抓握端口供能，身体/手臂/手的擦碰都不发包。
		if player_bodies.has(body):
			continue
		# 不可破坏但未开无尽燃料的 body（例如钉子钉在黑色载体上）
		# 不参与燃料抽取；避免“不可破坏却仍被蓝墨扣掉红像素”的矛盾。
		if Traits.is_unbreakable(body) and not Traits.is_infinite_fuel(body):
			continue
		if body.tags.has("living") and float(body.tags.get(
			"supply_power", rule.biological_default_power)) <= 0.0:
			continue
		var rect := _bounds(body)
		if not rect.has_area():
			continue
		var contacts := {}
		var bounds := _rect_world(body, rect).grow(1.5)
		for wire in wires:
			if bounds.intersects(_rect_world(wire.body, wire.local_bounds())):
				var found := _source_contacts(wire, body)
				for cell: Vector2i in found:
					for port: Array in found[cell]:
						if wire.mask.has(port[1]):
							contacts.get_or_add(cell, []).append(port)
		if contacts.is_empty():
			continue
		if Traits.is_infinite_fuel(body):
			var infinite_energy: float = contacts.size() * rule.source_power_per_pixel * interval
			var infinite_share: float = infinite_energy / contacts.size()
			for cell: Vector2i in contacts:
				var ports: Array = contacts[cell]
				for port: Array in ports:
					inject(port[0], port[1], port[2], infinite_share / ports.size(), body.get_instance_id())
			continue
		if body.tags.has("living"):
			var group: Dictionary = groups.get_or_add(body, {"body": body, "ports": []})
			for ports: Array in contacts.values():
				group.ports.append_array(ports)
		else:
			var account: Dictionary = fuel.get_or_add(body, {"credit": 0.0, "contacts": {}})
			account.contacts = contacts.duplicate()
			var energy := minf(contacts.size() * rule.source_power_per_pixel * interval, maxf(0.0, contacts.size() - account.credit) * rule.energy_per_red_pixel)
			var share: float = energy / contacts.size()
			for cell: Vector2i in contacts:
				var ports: Array = contacts[cell]
				for port: Array in ports:
					inject(port[0], port[1], port[2], share / ports.size(), body.get_instance_id())
				account.contacts[cell] = true
			account.credit += energy / maxf(rule.energy_per_red_pixel, 0.001)
	for group: Dictionary in groups.values():
		var power: float = maxf(0.0, float(group.body.tags.get(
			"supply_power", rule.biological_default_power)))
		for port: Array in group.ports:
			inject(port[0], port[1], port[2], power * interval / group.ports.size(), group.body.get_instance_id())
	if player == null:
		return
	var hand = player.get_node("Arm/Hand/HandControl")
	if hand.grabbed_body == null or hand.grip_joint == null or not hand.grip_joint.is_active():
		return
	var point: Vector2 = hand.grip_joint.anchor_a_world()
	var ports: Array = []
	for wire in wires:
		if wire.body != hand.grabbed_body:
			continue
		var at := Vector2i(wire.body.to_local(point).floor())
		for offset: Vector2i in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			if wire.mask.has(at + offset):
				ports.append([wire, at + offset])
				break
	var feet = player.get_node("PlayerInput")
	var power: float = maxf(0.0, feet.max_power - feet.debug_active_power) + maxf(0.0, hand.max_power - hand.debug_active_power)
	for port: Array in ports:
		inject(port[0], port[1], -1, power * interval / ports.size(), biological_producer)

func _rebuild_local_contacts(rule, wires: Array, motors: Array) -> void:
	var phase_start := Time.get_ticks_usec()
	neighbours.clear()
	var stamp: Array = []
	for wire in wires:
		stamp.append(wire.get_instance_id())
		stamp.append(wire.layout_version)
		var bounds := _rect_world(wire.body, wire.local_bounds()).grow(1.5)
		for other in wires:
			if other != wire and bounds.intersects(_rect_world(other.body, other.local_bounds())):
				neighbours.get_or_add(wire, []).append(other)
		for motor in motors:
			stamp.append(motor.get_instance_id())
			# 位置量化到 4px、角度量化到约 6°：电机覆盖面只有几个像素，
			# 亚格级的挪动不可能改变它压住哪些导线像素，没必要每帧重建接触。
			stamp.append(Vector2i((wire.body.to_local(motor.position) / 4.0).round()))
			stamp.append(roundi((motor.rotation - wire.body.rotation) * 10.0))
			stamp.append(motor.tip)
			stamp.append(motor.brush_width)
	for hinge in rule.objects(rule.Hinge):
		for wire in wires:
			stamp.append(wire.version)
		stamp.append(hinge.get_instance_id())
		stamp.append(hinge.joint != null and hinge.joint.is_active())
		if not hinge.yellow_anchor.is_empty() and not hinge.black_anchor.is_empty():
			# 桥接只用到轴心的世界坐标和轴承贴图尺寸，都是轴对齐的；
			# 轮子自转不改变盖住哪些导线像素，所以不要把 rotation 放进 stamp。
			stamp.append(Vector2i((rule.Anchor.anchor_world(hinge.yellow_anchor) / 2.0).round()))
	stats["stamp_us"] = stats.get("stamp_us", 0) + Time.get_ticks_usec() - phase_start
	if stamp == _local_stamp:
		return
	_local_stamp = stamp
	phase_start = Time.get_ticks_usec()
	var live_keys := {}
	for wire in wires:
		for motor in motors:
			live_keys[Vector2i(wire.get_instance_id(), motor.get_instance_id())] = true
	for key in motor_cache.keys():
		if not live_keys.has(key):
			motor_cache.erase(key)
	consumers.clear()
	for wire in wires:
		var targets := {}
		for motor in motors:
			var a: Vector2 = wire.body.to_local(motor.position)
			var b: Vector2 = wire.body.to_local(motor.position + motor.tip.rotated(motor.rotation))
			var motor_stamp: Array = [wire.layout_version, a, b, motor.brush_width]
			var key := Vector2i(wire.get_instance_id(), motor.get_instance_id())
			var cached: Dictionary = motor_cache.get(key, {})
			if cached.get("stamp", []) != motor_stamp:
				var cells: Array = []
				for support in motor.support_cells:
					var at := Vector2i(support) if wire.body == motor.body else Vector2i(wire.body.to_local(motor.body.to_world(support + Vector2.ONE * 0.5)).floor())
					if wire.mask.has(at):
						cells.append(at)
				cached = {"stamp": motor_stamp, "cells": cells}
				motor_cache[key] = cached
			for at: Vector2i in cached.cells:
				targets.get_or_add(at, []).append(motor)
		consumers[wire] = targets
	stats["consumers_us"] = stats.get("consumers_us", 0) + Time.get_ticks_usec() - phase_start
	phase_start = Time.get_ticks_usec()
	_rebuild_bridges(rule, wires)
	stats["bridges_us"] = stats.get("bridges_us", 0) + Time.get_ticks_usec() - phase_start

func _rebuild_bridges(rule, wires: Array) -> void:
	bridges.clear()
	for hinge in rule.objects(rule.Hinge):
		if hinge.joint == null or not hinge.joint.is_active() or hinge.yellow_anchor.is_empty() or hinge.black_anchor.is_empty():
			continue
		var point: Vector2 = rule.Anchor.anchor_world(hinge.yellow_anchor)
		# 齿轮轴可以把贴图隐藏（`axle.hide_bearing`），此时 texture 为 null，
		# 直接 get_size() 会在固化重建桥接时崩掉；退回一个保守的半尺寸。
		var texture: Texture2D = hinge.texture
		var half: Vector2 = Vector2(texture.get_size()) * 0.5 if texture != null else Vector2(8.0, 8.0)
		var reach := maxf(half.length(), 8.0)
		var area := Rect2(point - half, half * 2.0)
		var sides: Array = [[], []]
		for side in 2:
			var body = hinge.yellow_anchor.body if side == 0 else hinge.black_anchor.body
			for wire in wires:
				if wire.body != body:
					continue
				for at: Vector2i in wire.pixels_in_rect(Rect2(body.to_local(point), Vector2.ZERO).grow(reach)):
					if area.has_point(body.to_world(Vector2(at) + Vector2.ONE * 0.5)):
						sides[side].append([wire, at])
		if sides[0].is_empty() or sides[1].is_empty():
			continue
		# 每侧先按 8px 网格建桶，取最近对端时只扫附近格子。
		# 原先每个像素都要和对侧全部像素算一次距离：大导线上一次重建就是几十万次，
		# 齿轮一转 stamp 每帧都变，整段蓝色规则因此吃掉上百毫秒。
		stats["bridge_cells"] = stats.get("bridge_cells", 0) + sides[0].size() + sides[1].size()
		for side in 2:
			var grid := {}
			for candidate: Array in sides[side ^ 1]:
				var candidate_point: Vector2 = candidate[0].body.to_world(Vector2(candidate[1]) + Vector2.ONE * 0.5)
				grid.get_or_add(bridge_bucket(candidate_point), []).append([candidate_point, candidate])
			for entry: Array in sides[side]:
				var world_point: Vector2 = entry[0].body.to_world(Vector2(entry[1]) + Vector2.ONE * 0.5)
				var best := _nearest_bridged(grid, world_point, reach)
				if not best.is_empty():
					bridges.get_or_add(entry[0], {})[entry[1]] = best


## 桥接用的 8px 空间桶键；查询时只看附近桶，避免 n×m 全配对。
func bridge_bucket(point: Vector2) -> Vector2i:
	return Vector2i(floori(point.x / 8.0), floori(point.y / 8.0))


func _nearest_bridged(grid: Dictionary, point: Vector2, reach: float) -> Array:
	var start := bridge_bucket(point)
	var best: Array = []
	var best_distance := INF
	var max_ring := ceili(reach / 8.0) + 1
	for ring in range(0, max_ring + 1):
		for gy in range(start.y - ring, start.y + ring + 1):
			for gx in range(start.x - ring, start.x + ring + 1):
				if maxi(absi(gx - start.x), absi(gy - start.y)) != ring:
					continue
				for item: Array in grid.get(Vector2i(gx, gy), []):
					var d: float = point.distance_squared_to(item[0])
					if d < best_distance:
						best_distance = d
						best = item[1]
		# ring 圈已经覆盖了切比雪夫距离 ring*8 内的所有桶；比当前最优更近的点
		# 只可能更靠近，不可能落在还没扫的外圈，可以提前收工。
		if not best.is_empty() and best_distance <= float(ring * 8) * float(ring * 8):
			break
	return best
