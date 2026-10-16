extends RefCounted

const BodyNode := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
const InkItem := preload("res://actor/ink_item/src/ink_item.gd")
const Stroke := preload("res://ink/src/yellow/stroke.gd")
const Hinge := preload("res://ink/src/yellow/hinge.gd")
const Palette := preload("res://ink/src/ink_palette.gd")
const TOKEN := &"canvas_undo_identity"

static func identity(node: Node) -> int:
	if not node.has_meta(TOKEN):
		node.set_meta(TOKEN, node.get_instance_id())
	return int(node.get_meta(TOKEN))

static func capture(canvas, include_bodies := false, selection := Rect2()) -> Dictionary:
	var surface = canvas.surface
	surface._commit_undo_step()
	surface._flush_ink()
	var blue_state: Array = surface.blue_rule().capture(surface, include_bodies, selection if selection.has_area() else Rect2(surface.global_position, Vector2(surface.canvas_size))) if surface.blue_rule() != null else []
	var data: PackedByteArray = surface.black_image.get_data()
	var state := {"blue_before": surface.blue_rule().object_ids() if surface.blue_rule() != null else {}, "blue_remove": {}, "blue": blue_state, "blue_cells": surface.blue_layer.cells.duplicate(), "blue_active": include_bodies, "size": surface.canvas_size, "position": canvas.position,
		"rod_image": surface.rod_layer.pixels.duplicate(), "rod_anchors": surface.rod_layer.anchor_points.duplicate(),
		"image": data.compress(FileAccess.COMPRESSION_FASTLZ), "ledger": surface.ink_px_by_material.duplicate(),
		"bodies": [], "before_ids": {}, "remove_ids": {}, "yellow": [], "hinges": [], "health": {}, "health_delta": {}}
	for child in canvas.world.get_children():
		if child is Hinge and not child.is_queued_for_deletion():
			if not child.yellow_anchor.is_empty() and not child.black_anchor.is_empty():
				state.hinges.append([Stroke.anchor_world(child.yellow_anchor), Stroke.anchor_world(child.black_anchor)])
	var bounds := selection if selection.has_area() else Rect2(surface.global_position, Vector2(surface.canvas_size))
	canvas.world.realign_body_nodes()
	for index in canvas.world.world.bodies.size():
		var body = canvas.world.world.bodies[index]
		if body == null or body.tags.has("living"):
			continue
		var node = canvas.world._body_nodes[index] if index < canvas.world._body_nodes.size() else null
		var id: int = identity(node) if is_instance_valid(node) else int(body.tags.get(TOKEN, body.get_instance_id()))
		body.tags[TOKEN] = id
		state.before_ids[id] = true
		if not include_bodies or not body.aabb.intersects(bounds):
			continue
		var saved := InkItem.new()
		canvas.solid._write_body_node(saved, body, saved)
		saved.initial_velocity = body.linear_velocity
		saved.initial_angular_velocity = body.angular_velocity
		saved.set_meta(TOKEN, id)
		saved.add_to_group("ink_item", true)
		if node is InkItem:
			saved.hide_nails_in_play = node.hide_nails_in_play
		var packed := PackedScene.new()
		packed.pack(saved)
		state.bodies.append({"scene": packed, "id": id})
		state.remove_ids[id] = true
		saved.free()
	var yellow = surface.yellow_rule()
	if yellow != null:
		for stroke in yellow.strokes:
			if not is_instance_valid(stroke) or stroke.is_queued_for_deletion():
				continue
			if stroke.source_surface != surface and not include_bodies:
				continue
			state.yellow.append({"id": identity(stroke), "path": stroke.path.duplicate(),
				"compact": stroke.compact_raster, "dashed": stroke.dashed, "dash_length": stroke.dash_length, "dash_gap": stroke.dash_gap,
				"width": stroke.brush_width, "worn": stroke.worn.duplicate(), "paid": stroke.paid,
				"active": stroke.activated, "state": stroke.state, "rest": stroke.rest_length,
				"a": stroke.saved_anchor_a, "b": stroke.saved_anchor_b, "source": weakref(stroke.source_surface) if stroke.source_surface != null else null})
	var health = surface._health_node()
	if health != null and not surface.ink_free:
		for entry in Palette.INKS:
			state.health[entry.material.id] = health.ink_of(entry.material.id)
	return state

static func commit(canvas, state: Dictionary) -> void:
	if canvas.surface.blue_rule() != null:
		for entry in state.blue:
			state.blue_remove[entry.id] = true
		for id in canvas.surface.blue_rule().object_ids():
			if not state.blue_before.has(id):
				state.blue_remove[id] = true
	state.erase("blue_before")
	for node in canvas.world.get_children():
		if node is BodyNode and not node.is_queued_for_deletion() and not node.body.tags.has("living"):
			var id := identity(node)
			if not state.before_ids.has(id):
				state.remove_ids[id] = true
			node.body.tags[TOKEN] = id
	for body in canvas.world.world.bodies:
		if body.tags.has("living"):
			continue
		var id: int = int(body.tags.get(TOKEN, body.get_instance_id()))
		body.tags[TOKEN] = id
		if not state.before_ids.has(id):
			state.remove_ids[id] = true
	var health = canvas.surface._health_node()
	if health != null:
		for id in state.health:
			state.health_delta[id] = state.health[id] - health.ink_of(id)
	state.erase("before_ids")
	canvas.surface.push_undo_step({"transaction": state})

static func restore(canvas, state: Dictionary) -> void:
	var surface = canvas.surface
	for child in canvas.world.get_children():
		if child is Hinge:
			child.remove_joint()
			canvas.world.remove_child(child)
			child.queue_free()
	canvas.world.realign_body_nodes()
	for node in canvas.world.get_children().duplicate():
		if node is BodyNode and not node.is_queued_for_deletion() and state.remove_ids.has(identity(node)):
			canvas.solid._remove_all_nails(canvas.world, node.body)
			canvas.world.remove_body_node(node)
			canvas.world.remove_child(node)
			node.queue_free()
	for body in canvas.world.world.bodies.duplicate():
		if not body.tags.has("living") and state.remove_ids.has(body.tags.get(TOKEN, -1)):
			canvas.solid._remove_all_nails(canvas.world, body)
			canvas.world.world.remove_body(body)
	canvas.world.sync_world_bodies()
	for saved in state.bodies:
		var node = saved.scene.instantiate()
		canvas.world.add_child(node)
		node.owner = canvas.world
		for child in node.get_children():
			child.owner = canvas.world
		var body = canvas.world.add_body_node(node)
		body.tags[TOKEN] = saved.id
	for saved in state.get("hinges", []):
		var hinge := Hinge.new()
		hinge.yellow_position = saved[0]
		hinge.black_position = saved[1]
		canvas.world.add_child(hinge)
		hinge.owner = canvas.world
	var yellow = surface.yellow_rule()
	if yellow != null:
		var ids := {}
		for saved in state.yellow:
			ids[saved.id] = true
		for stroke in yellow.strokes.duplicate():
			if is_instance_valid(stroke) and (stroke.source_surface == surface or ids.has(identity(stroke))):
				stroke.remove_joint()
				yellow.strokes.erase(stroke)
				stroke.get_parent().remove_child(stroke)
				stroke.queue_free()
		for saved in state.yellow:
			var stroke := Stroke.new()
			stroke.path = saved.path
			stroke.brush_width = saved.width
			stroke.compact_raster = saved.get("compact", false)
			stroke.dashed = saved.get("dashed", true)
			stroke.dash_length = saved.get("dash_length", 8.0)
			stroke.dash_gap = saved.get("dash_gap", 6.0)
			stroke.worn = saved.worn
			stroke.paid = saved.paid
			stroke.rest_length = saved.rest
			stroke.saved_anchor_a = saved.a
			stroke.saved_anchor_b = saved.b
			stroke.activated = saved.active
			stroke.source_surface = saved.source.get_ref() if saved.source != null else null
			if is_instance_valid(stroke.source_surface):
				stroke.source_canvas = canvas.world.get_path_to(stroke.source_surface)
			stroke.set_meta(TOKEN, saved.id)
			canvas.world.add_child(stroke)
			stroke.owner = canvas.world if saved.active else null
			stroke.state = saved.state
			yellow.strokes.append(stroke)
	surface._preserve_next_resize = true
	surface.canvas_size = state.size
	surface._preserve_next_resize = false
	canvas._syncing_preserved_resize = true
	canvas.canvas_size = state.size
	canvas._syncing_preserved_resize = false
	canvas.position = state.position
	var size: Vector2i = state.size
	var bytes: PackedByteArray = state.image.decompress(size.x * size.y * 4, FileAccess.COMPRESSION_FASTLZ)
	surface.black_image = Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, bytes)
	surface.rebuild_ink_tiles()
	if state.has("rod_image"):
		surface.rod_layer.pixels = state.rod_image.duplicate()
		surface.rod_layer.anchor_points = state.rod_anchors.duplicate()
		surface.rod_layer.refresh()
	surface.blue_layer.cells = state.get("blue_cells", PackedVector2Array())
	surface.blue_layer.rebuild()
	if surface.blue_rule() != null:
		surface.blue_rule().restore(surface, state.get("blue", []), state.get("blue_remove", {}))
	surface.ink_px_by_material = state.ledger.duplicate()
	surface._pending_ink.clear()
	surface._rebuild_nails()
	var health = surface._health_node()
	if health != null:
		for id in state.health_delta:
			health.add(id, state.health_delta[id])
	canvas.map_changed.emit()
