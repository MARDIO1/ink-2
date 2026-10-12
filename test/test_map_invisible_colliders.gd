extends SceneTree
var _valid := true


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_audit_saved_maps()
	for path in ["res://map/asset/imported/平路.tscn", "res://map/asset/imported/平路（新）.tscn"]:
		var level := (load(path) as PackedScene).instantiate()
		var creative = level.get_node("Creative")
		creative.auto_save_edits = false
		creative.auto_save_on_exit = false
		level.get_node("debugHUD").process_mode = Node.PROCESS_MODE_DISABLED
		level.get_node("SimulationRuntime").process_mode = Node.PROCESS_MODE_DISABLED
		root.add_child(level)
		await process_frame
		await process_frame
		level.realign_body_nodes()
		print("[InvisibleAudit] map: ", path)
		for index in level.world.bodies.size():
			var body = level.world.bodies[index]
			if body.internal_render:
				continue
			var node = level._body_nodes[index]
			var materials: Dictionary = {}
			for shape in body.shapes:
				var bounds: Rect2i = shape.local_aabb()
				for y in range(bounds.position.y, bounds.end.y):
					for x in range(bounds.position.x, bounds.end.x):
						var material: int = shape.get_pixel(x, y)
						if material != 0:
							materials[material] = int(materials.get(material, 0)) + 1
			print("[InvisibleAudit] node=", node.get_path() if node != null else "<no node>",
				" pos=", body.position, " aabb=", body.aabb, " materials=", materials,
				" living=", body.tags.has("living"), " monster=", body.tags.has("map_monster"),
				" native=", body.rapier_id)
		if path.ends_with("平路（新）.tscn"):
			# 只在内存中重现保存准备，不导出、不改地图文件。
			var monster = creative.place_monster(3, Vector2(1000, 230), false)
			await process_frame
			var shield = monster._ragdoll.shield_body
			level.get_node("MapCanvas/CanvasSolid").sync_serializable_bodies(level)
			var shield_index: int = level.world.bodies.find(shield)
			var saved_node = level._body_nodes[shield_index]
			var excluded: bool = saved_node == null
			_valid = _valid and excluded
			print("[InvisibleAudit] export excludes held shield: ", excluded)
		level.queue_free()
		await process_frame
	quit(0 if _valid else 1)


## 不运行、不覆盖地图；检查预置墨水节点的显示开关与透明材质。
func _audit_saved_maps() -> void:
	for filename in DirAccess.get_files_at("res://map/asset/imported"):
		if not filename.ends_with(".tscn"):
			continue
		var scene := (load("res://map/asset/imported/" + filename) as PackedScene).instantiate()
		var suspects := 0
		for node in scene.find_children("*", "", true, false):
			if not node.is_in_group("ink_item"):
				continue
			var transparent_pixels := 0
			for child in node.get_children():
				if child.get_script() == null or not child.get_script().resource_path.ends_with("pixel_shape_2d.gd"):
					continue
				var paint: Image = child.get("paint")
				if paint != null and paint.get_format() == Image.FORMAT_R8:
					for material in paint.get_data():
						if material == 6:
							transparent_pixels += 1
			if not node.internal_render or not node.visible or transparent_pixels > 0:
				suspects += 1
				print("[InvisibleAudit] suspect: ", filename, "/", node.name,
					" transparent material pixels=", transparent_pixels)
		print("[InvisibleAudit] saved map ", filename, ": suspicious ink nodes=", suspects)
		_valid = _valid and suspects == 0
		scene.free()
