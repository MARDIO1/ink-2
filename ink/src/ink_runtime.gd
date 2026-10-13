extends Node
## 编辑器重扫可能清空扩展缓存；游戏启动时确保物理内核已注册。
## 顺带把墨水色表塞进每个像素材质世界 —— 场景里不用手写 materials。

const InkPalette := preload("res://ink/src/ink_palette.gd")


func _enter_tree() -> void:
	if not ClassDB.class_exists("RapierPhys"):
		var status: int = GDExtensionManager.load_extension("res://addons/pixel_destruction/native/fastphys.gdextension")
		if status != GDExtensionManager.LOAD_STATUS_OK and status != GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
			push_error("无法加载像素物理扩展，状态：%d" % status)
			get_tree().quit(1)


func _ready() -> void:
	# 编辑器里不注入，避免把用户正在编辑的场景标脏。
	if Engine.is_editor_hint():
		return
	get_tree().node_added.connect(_on_node_added)
	_scan_worlds.call_deferred(get_tree().root)

func _scan_worlds(node: Node) -> void:
	_inject_world(node)
	for child in node.get_children():
		_scan_worlds(child)


func _on_node_added(node: Node) -> void:
	# PackedScene 装载时 node_added 可能早于脚本赋值；下一拍再识别世界。
	_inject_world.call_deferred(node)

func _inject_world(node: Node) -> void:
	if not is_instance_valid(node):
		return
	var script: Script = node.get_script()
	if script == null or not script.resource_path.ends_with("nodes/pixel_world.gd"):
		return
	inject_materials(node)


## 把色表里的材质按 id 并进世界的 materials（同 id 覆盖，缺的追加）。
func inject_materials(world: Node) -> void:
	var materials: Array = world.get("materials")
	if materials == null:
		return
	for material in InkPalette.all_materials():
		var found: int = -1
		for i in materials.size():
			if materials[i] != null and materials[i].id == material.id:
				found = i
				break
		if found >= 0:
			materials[found] = material
		else:
			materials.append(material)
	# 显式写回导出表，确保新增材质进入后续烘焙。
	world.set("materials", materials)
	# 惰性烘焙可能已经建好世界，只刷新材质表，保留所有实体与破坏状态。
	var physics = world.get("world")
	if physics != null:
		for material in InkPalette.all_materials():
			physics.set_material_density(material.id, material.density)
			physics.set_material_friction(material.id, material.friction)
			physics.set_material_restitution(material.id, material.restitution)
			physics.set_material_strength(material.id, material.compress_strength, material.resolved_shear())
			world.renderer.set_material_color(material.id, material.color)
		world.renderer.mark_all_dirty()
		# 静态体不会逐帧 sync；材质变化后立即刷新，排除玩家自有视觉。
		world.realign_body_nodes()
		for index in physics.bodies.size():
			var node = world._body_nodes[index] if index < world._body_nodes.size() else null
			if world.uses_internal_render(node):
				world.renderer.sync(physics.bodies[index])
