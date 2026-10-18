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
var opposition_recovery := 0.0
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
var contact_epoch := 0
var _neighbour_stamp: Array = []
var _bridge_layout_stamp: Array = []
var _bridge_stamps: Dictionary = {}
var _bridge_entries: Dictionary = {}
var _wire_rect_cache: Dictionary = {}
var _wire_rect_layout: Dictionary = {}
var stats := {"injected": 0.0, "consumed": 0.0, "lost": 0.0, "updates": 0, "shorts": 0}
var _native: Object = null
var _native_supports_recovery := false
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
	if not ClassDB.class_exists("InkEnergyGrid2") and not ClassDB.class_exists("InkEnergyGrid"):
		GDExtensionManager.load_extension("res://ink/blue/native/ink_energy.gdextension")
	var native_class := "InkEnergyGrid2" if ClassDB.class_exists("InkEnergyGrid2") else "InkEnergyGrid"
	assert(ClassDB.class_exists(native_class), "InkEnergyGrid missing: build ink/native then import project")
	_native_supports_recovery = native_class == "InkEnergyGrid2"
	_native = ClassDB.instantiate(native_class)

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
	# 先确定 DLL 协议版本，再决定是否发送回收字段；否则首帧会少写 8 字节。
	_ensure()
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
	if _native_supports_recovery:
		commands.put_double(opposition_recovery)
	var contact_key: Array = [_serial, contact_epoch]
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
			motor.startup_delay = rule.motor_startup_delay
			motor.power_window = rule.motor_power_window
			motor.force_ramp = rule.motor_force_ramp
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
		if not is_instance_valid(shape):
			continue
		if shape.get_pixel(cell.x, cell.y) == Palette.RED.id:
			return shape
	return null

func _rect_world(body, rect: Rect2) -> Rect2:
	var result := Rect2(body.to_world(rect.position), Vector2.ZERO)
	for p in [Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
		result = result.expand(body.to_world(p))
	return result

## 摘掉已释放的电机条目（烧毁/碎裂后缓存里可能还留着它们）。
## 对已释放对象调用 get_instance_id() 会直接崩，所以必须先判有效。
static func drop_dead_entries(entries: Array, dead_id: int) -> Array:
	return entries.filter(
		func(entry): return is_instance_valid(entry) and entry.get_instance_id() != dead_id)
func _revision(body) -> Array:
	var result: Array = []
	for shape in body.shapes:
		if not is_instance_valid(shape):
			continue
		result.append(shape.get_instance_id())
		result.append(shape.revision)
	return result

func _bounds(body) -> Rect2:
	# 当前运行时形状只删除像素；同一形状删后旧范围仍是安全的保守包围盒。
	# 形状替换/新建或 living 身份变化则重扫，避免每次燃烧遍历整块黑色载体。
	var identity: Array = [body.tags.has("living")]
	for shape in body.shapes:
		if not is_instance_valid(shape):
			continue
		identity.append(shape.get_instance_id())
	var cached: Dictionary = source_bounds.get(body, {})
	if cached.get("identity", []) == identity:
		return cached.rect
	var rect := Rect2()
	var regions: Array[Rect2] = []
	for shape in body.shapes:
		if not is_instance_valid(shape):
			continue
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

## 三类连接各自失效：导线邻居、电机接触、轴承桥接。
## 齿轮转动只会让真正相关的那一份失效，不会连带重算全部导电接触。
func _rebuild_local_contacts(rule, wires: Array, motors: Array) -> void:
	var phase_start := Time.get_ticks_usec()
	_refresh_neighbours(wires)
	stats["neigh_us"] = stats.get("neigh_us", 0) + Time.get_ticks_usec() - phase_start
	phase_start = Time.get_ticks_usec()
	_refresh_consumers(wires, motors)
	stats["consumers_us"] = stats.get("consumers_us", 0) + Time.get_ticks_usec() - phase_start
	phase_start = Time.get_ticks_usec()
	_refresh_bridges(rule, wires)
	stats["bridges_us"] = stats.get("bridges_us", 0) + Time.get_ticks_usec() - phase_start


## 位姿量化键：2px、约 3°。亚格级移动不可能改变导线压住哪些像元。
func _pose_key(body) -> Array:
	return [Vector2i((body.position / 2.0).round()), roundi(body.rotation * 20.0)]


## 导线邻居：只在导线集合、布局或量化位姿变化时重算，并按 64px 桶查交集。
func _refresh_neighbours(wires: Array) -> void:
	var stamp: Array = []
	for wire in wires:
		if not is_instance_valid(wire):
			continue
		stamp.append(wire.get_instance_id())
		stamp.append(wire.layout_version)
		stamp.append(_pose_key(wire.body))
	if stamp == _neighbour_stamp:
		return
	_neighbour_stamp = stamp
	contact_epoch += 1
	neighbours.clear()
	var boxes := {}
	var buckets := {}
	for wire in wires:
		var bounds := _rect_world(wire.body, wire.local_bounds()).grow(1.5)
		boxes[wire] = bounds
		var lo := Vector2i((bounds.position / 64.0).floor())
		var hi := Vector2i((bounds.end / 64.0).ceil())
		for gy in range(lo.y, hi.y + 1):
			for gx in range(lo.x, hi.x + 1):
				buckets.get_or_add(Vector2i(gx, gy), []).append(wire)
	for wire in wires:
		var bounds: Rect2 = boxes[wire]
		var lo := Vector2i((bounds.position / 64.0).floor())
		var hi := Vector2i((bounds.end / 64.0).ceil())
		for gy in range(lo.y, hi.y + 1):
			for gx in range(lo.x, hi.x + 1):
				for other in buckets.get(Vector2i(gx, gy), []):
					if other == wire or neighbours.get(wire, []).has(other):
						continue
					if bounds.intersects(boxes[other]):
						neighbours.get_or_add(wire, []).append(other)


## 一对导线×电机的接触键。用导线局部坐标：同一刚体整体旋转不会让这一对失效；
## 跨刚体时这里记的是相对位姿，只有真正变化的配对会重算。
func _motor_pair_stamp(wire, motor) -> Array:
	return [wire.layout_version,
		Vector2i((wire.body.to_local(motor.position) / 4.0).round()),
		roundi((motor.rotation - wire.body.rotation) * 10.0),
		motor.tip, motor.brush_width]


## 电机接触：逐对增量更新，只撤销/重建真正变化的那一对。
func _refresh_consumers(wires: Array, motors: Array) -> void:
	var live_keys := {}
	var changed := false
	for wire in wires:
		var targets: Dictionary = consumers.get(wire, {})
		for motor in motors:
			var key := Vector2i(wire.get_instance_id(), motor.get_instance_id())
			live_keys[key] = true
			var pair_stamp := _motor_pair_stamp(wire, motor)
			var cached: Dictionary = motor_cache.get(key, {})
			if cached.get("stamp", []) == pair_stamp:
				continue
			changed = true
			# 只撤销这一对的旧投影，其他配对保持不动。
			for at: Vector2i in cached.get("cells", []):
				var list: Array = targets.get(at, [])
				if not list.is_empty():
					list.erase(motor)
					if list.is_empty():
						targets.erase(at)
			var cells: Array = []
			for support in motor.support_cells:
				var at := Vector2i(support) if wire.body == motor.body \
					else Vector2i(wire.body.to_local(motor.body.to_world(support + Vector2.ONE * 0.5)).floor())
				if wire.mask.has(at):
					cells.append(at)
			for at: Vector2i in cells:
				var list: Array = targets.get(at, [])
				if not list.has(motor):
					list.append(motor)
					targets[at] = list
			motor_cache[key] = {"stamp": pair_stamp, "cells": cells}
		consumers[wire] = targets
	for key in motor_cache.keys():
		if not live_keys.has(key):
			# 电机已经消失：把它的旧投影从所有导线上摘掉，否则还会继续被供电。
			motor_cache.erase(key)
			changed = true
			var dead: int = key.y
			for wire in consumers.keys():
				var targets: Dictionary = consumers[wire]
				for at in targets.keys():
					# 电机可能已被释放（烧毁/碎裂）：对已释放对象取 id 会直接崩。
					var kept := drop_dead_entries(targets[at], dead)
					if kept.is_empty():
						targets.erase(at)
					else:
						targets[at] = kept
	for wire in consumers.keys():
		if not wires.has(wire):
			consumers.erase(wire)
			changed = true
	if changed:
		contact_epoch += 1


## 导线布局整体变化时需要重算全部桥接；单个轴承按自己的位姿键增量更新。
func _bridge_layout_key(wires: Array) -> Array:
	var key: Array = []
	for wire in wires:
		if not is_instance_valid(wire):
			continue
		key.append(wire.get_instance_id())
		key.append(wire.layout_version)
	return key


## 轴承桥接的失效键：位置量化 1px，两侧相对旋转量化约 5°。
## 相对旋转会改变轴承盖住哪些导电像素，所以不能把桥接结果永久缓存。
func _bridge_stamp(rule, hinge) -> Array:
	var yellow = hinge.yellow_anchor.body
	var black = hinge.black_anchor.body
	return [Vector2i(rule.Anchor.anchor_world(hinge.yellow_anchor).round()),
		Vector2i((yellow.position / 2.0).round()),
		Vector2i((black.position / 2.0).round()),
		roundi((yellow.rotation - black.rotation) * 4.0),
		hinge.texture != null]


func _refresh_bridges(rule, wires: Array) -> void:
	var layout := _bridge_layout_key(wires)
	if layout != _bridge_layout_stamp:
		_bridge_layout_stamp = layout
		_bridge_stamps.clear()
		for key in _bridge_entries.keys():
			_clear_bridge_entries(key)
	var loop_start := Time.get_ticks_usec()
	var live := {}
	for hinge in rule.objects(rule.Hinge):
		if hinge.joint == null or not hinge.joint.is_active() \
		or hinge.yellow_anchor.is_empty() or hinge.black_anchor.is_empty():
			continue
		var key: int = hinge.get_instance_id()
		live[key] = true
		var stamp := _bridge_stamp(rule, hinge)
		if _bridge_stamps.get(key, []) == stamp and _bridge_entries.has(key):
			continue
		_bridge_stamps[key] = stamp
		_rebuild_bridge(rule, wires, hinge, key)
	for key in _bridge_stamps.keys():
		if live.has(key):
			continue
		_bridge_stamps.erase(key)
		_clear_bridge_entries(key)
	stats["bridge_loop_us"] = stats.get("bridge_loop_us", 0) + Time.get_ticks_usec() - loop_start


## 只撤掉这个轴承上一次写进 bridges 的条目，不影响别的轴承。
func _clear_bridge_entries(key) -> void:
	for entry: Array in _bridge_entries.get(key, []):
		var wire = entry[0]
		var at: Vector2i = entry[1]
		var mapped: Dictionary = bridges.get(wire, {})
		mapped.erase(at)
		if mapped.is_empty():
			bridges.erase(wire)
	if _bridge_entries.has(key):
		_bridge_entries.erase(key)
		contact_epoch += 1


## 导线在某个局部圆范围内的像素列表：按 16px / 半径 4px 量化缓存。
## 轴承每转 15° 就要重算一次，但圆心几乎不动，重扫 min(面积, 像素数) 才是主要开销。
func _cached_rect_pixels(wire, local_center: Vector2, radius: float) -> Array:
	if _wire_rect_layout.get(wire, -1) != wire.layout_version:
		_wire_rect_layout[wire] = wire.layout_version
		_wire_rect_cache.erase(wire)
	var cache: Dictionary = _wire_rect_cache.get(wire, {})
	var cache_key := [Vector2i((local_center / 16.0).round()), roundi(radius / 4.0)]
	var cached: Array = cache.get(cache_key, [])
	if cached.is_empty():
		cached = []
		for at: Vector2i in wire.pixels_in_rect(Rect2(local_center, Vector2.ZERO).grow(radius)):
			# 刚体只平移旋转，局部距离不变：用圆判据筛掉远格，免掉每次 to_world。
			if (Vector2(at) + Vector2.ONE * 0.5).distance_squared_to(local_center) <= radius * radius:
				cached.append(at)
		if cache.size() > 48:
			cache.clear()
		cache[cache_key] = cached
		_wire_rect_cache[wire] = cache
	return cached
func _rebuild_bridge(rule, wires: Array, hinge, key) -> void:
	_clear_bridge_entries(key)
	var point: Vector2 = rule.Anchor.anchor_world(hinge.yellow_anchor)
	# 齿轮轴可以把贴图隐藏（`axle.hide_bearing`），此时 texture 为 null，
	# 直接 get_size() 会在固化重建桥接时崩掉；退回一个保守的半尺寸。
	var texture: Texture2D = hinge.texture
	var half: Vector2 = Vector2(texture.get_size()) * 0.5 if texture != null else Vector2(8.0, 8.0)
	var reach := maxf(half.length(), 8.0)
	var area := Rect2(point - half, half * 2.0)
	var scan_start := Time.get_ticks_usec()
	var sides: Array = [[], []]
	for side in 2:
		var body = hinge.yellow_anchor.body if side == 0 else hinge.black_anchor.body
		var local_center: Vector2 = body.to_local(point)
		var radius := reach
		for wire in wires:
			if wire.body != body:
				continue
			for at: Vector2i in _cached_rect_pixels(wire, local_center, radius):
				if area.has_point(body.to_world(Vector2(at) + Vector2.ONE * 0.5)):
					sides[side].append([wire, at])
	stats["bridge_scan_us"] = stats.get("bridge_scan_us", 0) + Time.get_ticks_usec() - scan_start
	if sides[0].is_empty() or sides[1].is_empty():
		return
	var nearest_start := Time.get_ticks_usec()
	stats["bridge_cells"] = stats.get("bridge_cells", 0) + sides[0].size() + sides[1].size()
	# 桥接只需要足够多的过轴门户；每侧封顶 64 个，避免大轴承上几百个像素两两配对。
	for side in 2:
		if sides[side].size() > 64:
			var step := ceili(float(sides[side].size()) / 64.0)
			var sampled: Array = []
			for i in range(0, sides[side].size(), step):
				sampled.append(sides[side][i])
			sides[side] = sampled
	stats["bridge_rebuilds"] = stats.get("bridge_rebuilds", 0) + 1
	var added: Array = []
	var grid_us := 0
	var entry_us := 0
	var entry_count := 0
	for side in 2:
		var grid_start := Time.get_ticks_usec()
		var grid := {}
		for candidate: Array in sides[side ^ 1]:
			var candidate_point: Vector2 = candidate[0].body.to_world(Vector2(candidate[1]) + Vector2.ONE * 0.5)
			grid.get_or_add(bridge_bucket(candidate_point), []).append([candidate_point, candidate])
		grid_us += Time.get_ticks_usec() - grid_start
		for entry: Array in sides[side]:
			var entry_start := Time.get_ticks_usec()
			entry_count += 1
			var world_point: Vector2 = entry[0].body.to_world(Vector2(entry[1]) + Vector2.ONE * 0.5)
			var best := _nearest_bridged(grid, world_point, sides[side ^ 1][0])
			entry_us += Time.get_ticks_usec() - entry_start
			if not best.is_empty():
				bridges.get_or_add(entry[0], {})[entry[1]] = best
				added.append([entry[0], entry[1]])
	stats["bridge_nearest_us"] = stats.get("bridge_nearest_us", 0) + Time.get_ticks_usec() - nearest_start
	stats["bridge_grid_us"] = stats.get("bridge_grid_us", 0) + grid_us
	stats["bridge_entry_us"] = stats.get("bridge_entry_us", 0) + entry_us
	stats["bridge_entry_count"] = stats.get("bridge_entry_count", 0) + entry_count
	if not added.is_empty():
		_bridge_entries[key] = added
		contact_epoch += 1

## 桥接用的 8px 空间桶键；查询时只看附近桶，避免 n×m 全配对。
func bridge_bucket(point: Vector2) -> Vector2i:
	return Vector2i(floori(point.x / 8.0), floori(point.y / 8.0))


## 桥接只需要在对侧找一个"能导电过去"的像素：固定查附近 2 圈（≤24px），
## 附近没有就用对侧的代表像素兜底。原先是逐圈外扩到整个轴承半径，
## 两侧像素稀疏时要扫几十个桶，单次重建能吃掉几毫秒。
func _nearest_bridged(grid: Dictionary, point: Vector2, fallback: Array) -> Array:
	var start := bridge_bucket(point)
	var best: Array = []
	var best_distance := INF
	# 只查自己这一格和周围一圈（≤24px）。轴承两侧的像素基本贴在一起，
	# 更远的对端直接用代表像素兜底，避免每格逐圈外扩带来的几十次桶查询。
	for gy in range(start.y - 1, start.y + 2):
		for gx in range(start.x - 1, start.x + 2):
			for item: Array in grid.get(Vector2i(gx, gy), []):
				var d: float = point.distance_squared_to(item[0])
				if d < best_distance:
					best_distance = d
					best = item[1]
	return best if not best.is_empty() else fallback
