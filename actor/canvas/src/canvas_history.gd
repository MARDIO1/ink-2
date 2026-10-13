extends RefCounted

const BodyNode := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
const InkItem := preload("res://actor/ink_item/src/ink_item.gd")
const Stroke := preload("res://actor/yellow/src/yellow_stroke.gd")
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
	var data: PackedByteArray = surface.black_image.get_data()
	var state := {"size": surface.canvas_size, "position": canvas.position,
		"image": data.compress(FileAccess.COMPRESSION_FASTLZ), "ledger": surface.ink_px_by_material.duplicate(),
		"bodies": [], "before_ids": {}, "remove_ids": {}, "yellow": [], "health": {}, "health_delta": {}}
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
				"width": stroke.brush_width, "compact": stroke.compact_raster,
				"worn": stroke.worn.duplicate(), "paid": stroke.paid,
				"active": stroke.activated, "state": stroke.state, "rest": stroke.rest_length,
				"a": stroke.saved_anchor_a, "b": stroke.saved_anchor_b, "source": weakref(stroke.source_surface) if stroke.source_surface != null else null})
	var health = surface._health_node()
	if health != null and not surface.ink_free:
		for entry in Palette.INKS:
			state.health[entry.material.id] = health.ink_of(entry.material.id)
	return state

static func commit(canvas, state: Dictionary) -> void:
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
			stroke.worn = saved.worn
			stroke.paid = saved.paid
			stroke.rest_length = saved.rest
			stroke.saved_anchor_a = saved.a
			stroke.saved_anchor_b = saved.b
			stroke.activated = saved.active
			stroke.source_surface = saved.source.get_ref() if saved.source != null else null
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
	surface.black_texture = ImageTexture.create_from_image(surface.black_image)
	surface.black_sprite.texture = surface.black_texture
	surface.ink_px_by_material = state.ledger.duplicate()
	surface._pending_ink.clear()
	surface._rebuild_nails()
	var health = surface._health_node()
	if health != null:
		for id in state.health_delta:
			health.add(id, state.health_delta[id])
	canvas.map_changed.emit()
