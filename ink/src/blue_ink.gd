extends Node
## 蓝墨编辑/保存与运行时接口适配。导线、箭头和能源传播各有独立实现。
## 传播在 blue/energy_flow.gd；箭头自己的收费/施力在 blue/motor.gd，不建立电网或路径树。
const Palette := preload("res://ink/src/ink_palette.gd")
const Wire := preload("res://ink/src/blue/wire_layer.gd")
const Motor := preload("res://ink/src/blue/motor.gd")
const Anchor := preload("res://ink/src/yellow/stroke.gd")
const Hinge := preload("res://ink/src/yellow/hinge.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")

#region 配置与状态
@export var force_per_length := 100000.0
@export var power_per_width := 100000000.0
@export var source_power_per_pixel := 100000000.0
@export var idle_power := 10000000.0
@export var energy_per_red_pixel := 100000000.0
@export_range(0.02, 1.0, 0.01) var fuel_interval := 0.1
var drawing = null
var _world = null
var _profile_enabled := false
var _profile: Dictionary = {}
var _pending_wires: Dictionary = {}
const EnergyFlow := preload("res://ink/src/blue/energy_flow.gd")
var flow := EnergyFlow.new()
@export var propagation_speed := 600.0
@export var emission_interval := 0.5
@export var motor_buffer_seconds := 0.6
@export var energy_lifetime := 20.0

func _ready() -> void:
	_world = get_parent().get_parent()

func objects(kind) -> Array:
	var result: Array = []
	if not is_instance_valid(_world):
		return result
	for child in _world.get_children():
		if is_instance_of(child, kind) and not child.is_queued_for_deletion():
			result.append(child)
	return result

func set_profile_enabled(enabled: bool) -> void:
	_profile_enabled = enabled
	_profile.clear()

func take_profile() -> Dictionary:
	var result := _profile.duplicate()
	_profile.clear()
	return result
#endregion

#region 绘制、固化与回收
func begin(surface, point: Vector2) -> void:
	cancel()
	var nearest := Vector2i(point.floor())
	var distance := INF
	for y in range(nearest.y - 6, nearest.y + 7):
		for x in range(nearest.x - 6, nearest.x + 7):
			var at := Vector2i(x, y)
			if surface._inside(at) and surface.material_at(x, y) == Palette.BLACK.id:
				var value := point.distance_squared_to(Vector2(at) + Vector2.ONE * 0.5)
				if value < distance:
					distance = value
					nearest = at
	if distance > 36.0:
		return
	surface._begin_undo_step()
	drawing = Motor.new()
	drawing.preview = true
	drawing.source_surface = surface
	drawing.source_canvas = _world.get_path_to(surface)
	drawing.position = surface.to_global(Vector2(nearest) + Vector2.ONE * 0.5)
	drawing.brush_width = surface.brush_size
	_world.add_child(drawing)

func extend(surface, point: Vector2) -> void:
	if drawing != null and drawing.source_surface == surface:
		var requested: Vector2 = surface.to_global(point) - drawing.position
		var low := 0.0
		var high := 1.0
		for iteration in 9:
			var factor := high if iteration == 0 else (low + high) * 0.5
			var fits := true
			for offset in Motor.pixels_for(requested * factor, drawing.brush_width):
				var at := Vector2i(surface.to_local(drawing.position + offset).floor())
				if not surface._inside(at) or surface.material_at(at.x, at.y) != Palette.BLACK.id:
					fits = false
					break
			if fits:
				low = factor
				if factor == 1.0:
					break
			else:
				high = factor
		drawing.tip = requested * low
		drawing.queue_redraw()

func finish(surface, point: Vector2) -> bool:
	if drawing == null:
		return false
	extend(surface, point)
	var motor = drawing
	drawing = null
	var length: float = motor.tip.length()
	motor.area = maxi(1, ceili(length * motor.brush_width + motor.brush_width * motor.brush_width))
	if length < 1.0 or motor.area > surface._ink_room(Palette.BLUE.id):
		motor.queue_free()
		surface._cancel_undo_step()
		return false
	motor.preview = false
	motor.paid = not surface.ink_free
	motor.set_meta("canvas_undo_identity", motor.get_instance_id())
	motor.owner = _world
	surface._bump_ink(Palette.BLUE.id, motor.area)
	surface._flush_ink()
	surface._commit_undo_step()
	return true

func cancel() -> void:
	if is_instance_valid(drawing):
		var surface = drawing.source_surface
		drawing.queue_free()
		if is_instance_valid(surface):
			surface._cancel_undo_step()
	drawing = null

func solidify(surface) -> void:
	if _pending_wires.has(surface):
		var yellow_bodies: Array = []
		for body in _world.world.bodies:
			for shape in body.shapes:
				if shape.chunks.values().any(func(chunk): return chunk.mat.has(Palette.YELLOW.id)):
					yellow_bodies.append(body)
					break
		attach_wires(surface, yellow_bodies, _pending_wires[surface])
		_pending_wires.erase(surface)
	for motor in objects(Motor):
		if motor.active or motor.preview or motor.source_surface != surface:
			continue
		var anchor: Dictionary = Anchor.find_anchor(_world.world, motor.position)
		if anchor.is_empty():
			motor.queue_free()
		else:
			motor.bind(anchor)

## 固化前把裸导线加入联合实体；覆盖黑色仅保留导电标记。
func merge_shape(surface, shape) -> void:
	_pending_wires[surface] = surface.blue_layer.mask.duplicate()
	for at: Vector2i in surface.blue_layer.mask:
		if shape.get_pixel(at.x, at.y) == 0 and surface.rod_layer.pixels.get_pixelv(at).a <= 0.0:
			shape.set_pixel(at.x, at.y, Palette.BLUE.id)

func attach_wires(surface, bodies: Array, pixels: Dictionary) -> void:
	for body in bodies:
		var cells: PackedVector2Array = []
		for at: Vector2i in pixels:
			var world_point: Vector2 = surface.to_global(Vector2(at) + Vector2.ONE * 0.5)
			var cell := Vector2i(body.to_local(world_point).floor())
			var material: int = Wire.material_at(body, cell)
			if material in [Palette.BLACK.id, Palette.BLUE.id, Palette.YELLOW.id]:
				cells.append(Vector2(cell))
		if not cells.is_empty():
			add_wire(body, cells)

func add_wire(body, cells: PackedVector2Array):
	var wire := Wire.new()
	wire.active = true
	wire.cells = cells
	wire.body = body
	wire.carrier_material = Wire.material_at(body, Vector2i(cells[0]))
	wire.position = body.position
	wire.rotation = body.rotation
	_world.add_child(wire)
	wire.owner = _world
	wire.remember_revision()
	return wire

func erase_draft_anchor(surface, at: Vector2i) -> void:
	for motor in objects(Motor):
		if motor.active or motor.preview or motor.source_surface != surface:
			continue
		if motor.covers(surface.to_global(Vector2(at) + Vector2.ONE * 0.5)):
			surface._bump_ink(Palette.BLUE.id, -motor.area)
			motor.queue_free()

func clear_drafts(surface) -> void:
	for motor in objects(Motor):
		if not motor.active and motor.source_surface == surface:
			motor.queue_free()

func reclaim(surface, selection := Rect2i()) -> void:
	var bounds: Rect2i = selection if selection.has_area() else Rect2i(Vector2i.ZERO, surface.canvas_size)
	for motor in objects(Motor):
		if not motor.active:
			continue
		motor.sync_pose()
		if bounds.has_point(Vector2i(surface.to_local(motor.position).floor())):
			motor.active = false
			motor.body = null
			motor.source_surface = surface
			motor.source_canvas = _world.get_path_to(surface)
			surface._bump_ink(Palette.BLUE.id, motor.area, false)
	for wire in objects(Wire):
		if not wire.active or wire.body == null:
			continue
		var retained: PackedVector2Array = []
		for point in wire.cells:
			var at := Vector2i(surface.to_local(wire.body.to_world(point + Vector2.ONE * 0.5)).floor())
			if bounds.has_point(at):
				if not surface.blue_layer.mask.has(at):
					surface.blue_layer.mask[at] = true
					surface._bump_ink(Palette.BLUE.id, 1, false)
			else:
				retained.append(point)
		wire.cells = retained
		wire.rebuild()
		if retained.is_empty():
			wire.queue_free()
	surface.blue_layer.refresh()

func observe_fracture(physics, body, pieces: Array) -> void:
	for motor in objects(Motor):
		motor.rebind(physics, body, pieces)
	for wire in objects(Wire):
		if wire.body != body:
			continue
		if pieces.has(body) and wire.intact_on(body):
			wire.remember_revision()
			continue
		var groups: Dictionary = {}
		for point in wire.cells:
			var world_point: Vector2 = body.to_world(point + Vector2.ONE * 0.5)
			for piece in pieces:
				var at := Vector2i(piece.to_local(world_point).floor())
				var material: int = Wire.material_at(piece, at)
				if physics.bodies.has(piece) and material in [Palette.BLACK.id, Palette.BLUE.id, Palette.YELLOW.id]:
					groups.get_or_add(piece, []).append(Vector2(at))
					break
		var replacements: Array = []
		for piece in groups:
			replacements.append(add_wire(piece, PackedVector2Array(groups[piece])))
		flow.rebind_wire(wire, replacements)
		wire.queue_free()
#endregion

#region 编辑历史
func object_ids() -> Dictionary:
	var ids := {}
	for object in objects(Motor) + objects(Wire):
		ids[identity(object)] = true
	return ids

func identity(object) -> int:
	if not object.has_meta("canvas_undo_identity"):
		object.set_meta("canvas_undo_identity", object.get_instance_id())
	return int(object.get_meta("canvas_undo_identity"))

func capture(surface, include_active := false, selection := Rect2()) -> Array:
	var result: Array = []
	for object in objects(Motor) + objects(Wire):
		if object is Motor and object.preview:
			continue
		if object.active and not include_active:
			continue
		if object.active and selection.has_area() and object.body != null and not object.body.aabb.intersects(selection):
			continue
		if not object.active and object.source_surface != surface:
			continue
		object.sync_pose()
		var packed := PackedScene.new()
		packed.pack(object)
		result.append({"scene": packed, "id": identity(object), "active": object.active})
	return result

func restore(surface, saved: Array, remove_ids: Dictionary = {}) -> void:
	for object in objects(Motor) + objects(Wire):
		if remove_ids.has(identity(object)) or (not object.active and object.source_surface == surface):
			object.queue_free()
	for entry in saved:
		var object = entry.scene.instantiate()
		object.source_surface = surface
		object.set_meta("canvas_undo_identity", entry.id)
		_world.add_child(object)
		object.owner = _world

func draft_data(surface) -> Array:
	var data: Array = []
	for motor in objects(Motor):
		if not motor.active and not motor.preview and motor.source_surface == surface:
			data.append({"position": motor.position, "rotation": motor.rotation, "tip": motor.tip, "width": motor.brush_width, "area": motor.area})
	return data

func restore_draft_data(surface, data: Array) -> void:
	clear_drafts(surface)
	for saved in data:
		var motor := Motor.new()
		motor.position = saved.position
		motor.rotation = saved.rotation
		motor.tip = saved.tip
		motor.brush_width = saved.width
		motor.area = saved.area
		motor.paid = not surface.ink_free
		motor.source_surface = surface
		motor.source_canvas = _world.get_path_to(surface)
		_world.add_child(motor)
		motor.owner = _world
		surface._bump_ink(Palette.BLUE.id, motor.area)
#endregion

#region Runtime adapter
func resolve_fixed(context: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	flow.speed = maxf(100.0, propagation_speed)
	flow.interval = maxf(0.02, emission_interval)
	flow.lifetime = energy_lifetime
	flow.pixel_power = power_per_width
	var result: Dictionary = flow.update(self, context)
	if _profile_enabled:
		var elapsed := Time.get_ticks_usec() - started
		flow.stats["resolve_total_us"] = flow.stats.get("resolve_total_us", 0) + elapsed
		_profile.resolve_us = _profile.get("resolve_us", 0) + elapsed
		_profile.calls = _profile.get("calls", 0) + 1
		_profile.active_cells = flow.active_cells()
	return result
#endregion
