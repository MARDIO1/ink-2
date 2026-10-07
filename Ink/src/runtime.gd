extends Node
## 编辑器重扫可能清空扩展缓存；游戏启动时确保物理内核已注册。
## 顺带把墨水色表塞进每个像素材质世界 —— 场景里不用手写 materials。

const InkPalette := preload("res://Ink/src/ink_palette.gd")


func _enter_tree() -> void:
	if not ClassDB.class_exists("RapierPhys"):
		var status: int = GDExtensionManager.load_extension("res://addons/pixel_destruction/native/fastphys.gdextension")
		if status != GDExtensionManager.LOAD_STATUS_OK and status != GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
			push_error("无法加载像素物理扩展，状态：%d" % status)
			get_tree().quit(1)


func _ready() -> void:
	#编辑器里不注入：那会把用户正在编辑的场景标脏（场景里已有的材质表照旧够预览）。
	if Engine.is_editor_hint():
		return
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
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
