extends RefCounted
## 文档命令适配器；只获得明确列出的编辑端口，不持有 Creative 或 UI 节点。
const REQUIRED_PORTS := [&"_remove_monster_by_id", &"place_monster", &"_apply_monster_transform", &"_remove_dialogue_trigger_by_id", &"place_dialogue_trigger", &"_remove_map_text_by_id", &"_restore_deleted_image", &"place_map_text", &"_refresh_layout_overlay", &"_undo_placed_layout_node", &"_restore_deleted_play_canvas", &"place_ink_fountain", &"place_respawn_point", &"_restore_ink_quota", &"place_portal", &"place_play_canvas", &"delete_play_canvas", &"_ensure_monster_container", &"_ensure_dialogue_container", &"_ensure_text_container"]
var ports: Dictionary
var _map_canvas: Node
var _history: WeakRef
var history:
	get:
		return _history.get_ref()

func configure(canvas: Node, timeline: RefCounted, operations: Dictionary) -> void:
	_map_canvas = canvas
	_history = weakref(timeline)
	for key in REQUIRED_PORTS:
		assert(operations.has(key) and operations[key] is Callable and operations[key].is_valid(), "Missing editor command port: %s" % key)
	ports = operations.duplicate()

func undo(edit: Dictionary) -> bool:
	var changed := false
	match edit.get("type", &""):
		&"canvas":
			var surface: Node = _map_canvas.get_node_or_null("CanvasSurface") if _map_canvas != null else null
			changed = surface != null and surface.undo_last_edit()
		&"monster_place":
			changed = ports._remove_monster_by_id.call(str(edit.get("id", "")))
		&"monster_delete":
			changed = ports.place_monster.call(
				int(edit.get("kind", -1)),
				edit.get("position", Vector2.ZERO),
				false,
				str(edit.get("id", "")),
				edit.get("scale", Vector2.ONE)
			) != null
		&"monster_transform":
			changed = ports._apply_monster_transform.call(
				str(edit.get("id", "")),
				edit.get("old_position", Vector2.ZERO),
				edit.get("old_scale", Vector2.ONE)
			)
		&"dialogue_place":
			changed = ports._remove_dialogue_trigger_by_id.call(str(edit.get("id", "")))
		&"dialogue_delete":
			var trigger = ports.place_dialogue_trigger.call(
				edit.get("position", Vector2.ZERO),
				PackedStringArray(edit.get("lines", PackedStringArray())),
				false,
				str(edit.get("id", ""))
			)
			if trigger != null:
				trigger.scale = edit.get("scale", Vector2.ONE)
				history.rebind(edit.get("target"), trigger)
				edit["target"] = trigger
				changed = true
		&"text_place":
			changed = ports._remove_map_text_by_id.call(str(edit.get("id", "")))
		&"image_delete":
			var image = ports._restore_deleted_image.call(
				edit.get("source_data", PackedByteArray()), str(edit.get("source_format", "")),
				str(edit.get("filename", "")), edit.get("position", Vector2.ZERO),
				edit.get("scale", Vector2.ONE))
			if image != null:
				history.rebind(edit.get("target"), image)
				edit["target"] = image
				changed = true
		&"text_delete":
			var label = ports.place_map_text.call(
				edit.get("position", Vector2.ZERO),
				str(edit.get("text", "")),
				false,
				str(edit.get("id", ""))
			)
			if label != null:
				label.scale = edit.get("scale", Vector2.ONE)
				history.rebind(edit.get("target"), label)
				edit["target"] = label
				changed = true
		&"layout_move", &"object_transform":
			var target = edit.get("target")
			if is_instance_valid(target):
				target.global_position = edit.get("old_position", target.global_position)
				target.scale = edit.get("old_scale", target.scale)
				if target.has_method("sync_physics_from_node"):
					target.sync_physics_from_node(true)
				ports._refresh_layout_overlay.call()
				changed = true
		&"respawn_place", &"play_canvas_place", &"portal_place", &"fountain_place":
			changed = ports._undo_placed_layout_node.call(edit.get("target"))
		&"play_canvas_delete":
			changed = ports._restore_deleted_play_canvas.call(edit)
		&"fountain_delete":
			var fountain = ports.place_ink_fountain.call(edit.get("position", Vector2.ZERO), false)
			if fountain != null:
				history.rebind(edit.get("target"), fountain)
				edit["target"] = fountain
				changed = true
		&"respawn_delete":
			var respawn = ports.place_respawn_point.call(edit.get("position", Vector2.ZERO), false)
			if respawn != null:
				history.rebind(edit.get("target"), respawn)
				edit["target"] = respawn
				changed = true
		&"ink_quota":
			changed = ports._restore_ink_quota.call(edit.get("before", {}))
		&"portal_destination":
			var portal = edit.get("target")
			if is_instance_valid(portal):
				portal.target_map = edit.get("old_destination", "")
				changed = true
		&"portal_delete":
			var portal = ports.place_portal.call(edit.get("position", Vector2.ZERO), str(edit.get("destination", "")), false)
			if portal != null:
				portal.portal_size = edit.get("size", portal.portal_size)
				portal.scale = edit.get("scale", Vector2.ONE)
				history.rebind(edit.get("target"), portal)
				edit["target"] = portal
				changed = true
	return changed

func redo(edit: Dictionary, data: Dictionary) -> bool:
	var kind: StringName = edit.get("type", &"")
	var id := str(edit.get("id", ""))
	var changed := false
	var restored: Node = null
	match kind:
		&"canvas":
			var surface: Node = _map_canvas.get_node_or_null("CanvasSurface") if _map_canvas != null else null
			changed = surface != null and surface.redo_last_edit()
		&"monster_place":
			if data.has("kind"):
				restored = ports.place_monster.call(int(data.kind), data.position, false, id, data.scale)
				changed = restored != null
		&"monster_delete":
			changed = ports._remove_monster_by_id.call(id)
		&"monster_transform":
			changed = ports._apply_monster_transform.call(id, edit.get("new_position", Vector2.ZERO),
				edit.get("new_scale", Vector2.ONE))
		&"dialogue_place":
			if data.has("lines"):
				restored = ports.place_dialogue_trigger.call(data.position, data.lines, false, id)
				if restored != null:
					restored.scale = data.scale
					changed = true
		&"dialogue_delete":
			changed = ports._remove_dialogue_trigger_by_id.call(id)
		&"text_place":
			if data.has("text"):
				restored = ports.place_map_text.call(data.position, data.text, false, id)
				if restored != null:
					restored.scale = data.scale
					changed = true
		&"text_delete":
			changed = ports._remove_map_text_by_id.call(id)
		&"layout_move", &"object_transform":
			var target = edit.get("target")
			if is_instance_valid(target) and data.has("position"):
				target.global_position = data.position
				target.scale = data.scale
				if target.has_method("sync_physics_from_node"):
					target.sync_physics_from_node(true)
				ports._refresh_layout_overlay.call()
				changed = true
		&"respawn_place":
			if data.has("position"):
				restored = ports.place_respawn_point.call(data.position, false)
				changed = restored != null
		&"play_canvas_place":
			if data.has("position"):
				restored = ports.place_play_canvas.call(data.position + Vector2(data.size) * 0.5,
					false, data.size)
				if restored != null:
					changed = true
		&"play_canvas_delete":
			changed = ports.delete_play_canvas.call(edit.get("target"), false)
		&"portal_place":
			if data.has("position"):
				restored = ports.place_portal.call(data.position, str(data.get("destination", "")), false)
				if restored != null:
					restored.portal_size = data.size
					restored.scale = data.scale
					changed = true
		&"fountain_place":
			if data.has("position"):
				restored = ports.place_ink_fountain.call(data.position, false)
				changed = restored != null
		&"fountain_delete", &"portal_delete", &"image_delete", &"respawn_delete":
			changed = ports._undo_placed_layout_node.call(edit.get("target"))
		&"portal_destination":
			var portal = edit.get("target")
			if is_instance_valid(portal) and data.has("destination"):
				portal.target_map = data.destination
				changed = true
		&"ink_quota":
			changed = ports._restore_ink_quota.call(edit.get("after", {}))
	if not changed:
		return false
	if restored != null:
		history.rebind(edit.get("target"), restored)
		edit["target"] = restored
	return true

func _capture_redo_data(edit: Dictionary) -> Dictionary:
	var data := {}
	var kind: StringName = edit.get("type", &"")
	var id := str(edit.get("id", ""))
	var node: Node = null
	match kind:
		&"monster_place":
			node = _find_editor_node(ports._ensure_monster_container.call(), id)
			if node is Node2D:
				data = {"kind": int(node.get("kind")), "position": node.global_position,
					"scale": node.scale}
		&"dialogue_place":
			node = _find_editor_node(ports._ensure_dialogue_container.call(), id)
			if node is Node2D:
				data = {"position": node.global_position, "scale": node.scale,
					"lines": PackedStringArray(node.get("lines"))}
		&"text_place":
			node = _find_editor_node(ports._ensure_text_container.call(), id)
			if node is Label:
				data = {"position": node.global_position, "scale": node.scale, "text": node.text}
		&"layout_move", &"object_transform", &"respawn_place", &"play_canvas_place", \
		&"portal_place", &"fountain_place":
			node = edit.get("target")
			if is_instance_valid(node) and (node is Node2D or node is Control):
				data = {"position": node.global_position, "scale": node.scale}
				if kind == &"play_canvas_place":
					data["size"] = node.get("canvas_size")
				elif kind == &"portal_place":
					data["destination"] = node.target_map
					data["size"] = node.portal_size
		&"portal_destination":
			node = edit.get("target")
			if is_instance_valid(node):
				data["destination"] = node.target_map
	if node != null and kind in [&"dialogue_place", &"text_place"]:
		edit["target"] = node
	return data


## 取消最近一次撤销；与 Ctrl+Z 共用按时间排序的编辑记录。

func _find_editor_node(container: Node, editor_id: String) -> Node:
	if container == null or editor_id.is_empty():
		return null
	for child in container.get_children():
		if str(child.get("editor_id")) == editor_id:
			return child
	return null

func _dispose_history_edit(edit: Dictionary) -> void:
	if edit.get("type", &"") != &"play_canvas_delete":
		return
	var canvas = edit.get("target")
	if is_instance_valid(canvas) and canvas.get_parent() == null:
		canvas.free()
