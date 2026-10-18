extends RefCounted
## 小怪的**文档操作**：查找、计数、编辑器物理暂停。
##
## 只管容器里的节点；容器的创建/命名仍由 `creative` 负责（那属于编辑器装配）。
## 撤销、选中、拖动都不在这里。

const MapMonsterScript := preload("res://actor/monster/src/map_monster.gd")


static func count(container) -> int:
	return container.get_child_count() if container != null else 0


## 从后往前找：后放的在上层，点选时优先命中最上面那个。
static func find_at(container, world_position: Vector2, margin: float) -> Node2D:
	if container == null:
		return null
	var children: Array = container.get_children()
	for index in range(children.size() - 1, -1, -1):
		var child = children[index]
		if not child is Node2D or not child.is_in_group(MapMonsterScript.GROUP):
			continue
		if child.editor_contains_point(world_position, margin):
			return child
	return null


## 编辑器里暂停小怪物理（拖动、放置时避免它们乱跑）。
static func set_physics_paused(container, paused: bool) -> void:
	if container == null:
		return
	for child in container.get_children():
		if child.has_method("set_editor_physics_paused"):
			child.set_editor_physics_paused(paused)


## 建节点、入容器、摆位置、同步物理。**不设 id、不记历史、不选中**——那些是编辑器的事。
static func create(container, scene: PackedScene, node_name: String,
		world_position: Vector2, monster_scale: Vector2) -> Node2D:
	if container == null or scene == null:
		return null
	var monster := scene.instantiate() as Node2D
	if monster == null:
		return null
	monster.name = node_name
	monster.scale = monster_scale
	container.add_child(monster, true)
	monster.global_position = world_position
	if monster.has_method("sync_physics_from_node"):
		monster.sync_physics_from_node(true)
	return monster


static func remove(container, monster) -> void:
	if monster == null or not is_instance_valid(monster):
		return
	if container != null and monster.get_parent() == container:
		container.remove_child(monster)
	monster.queue_free()


## 撤销恢复时按 `editor_id` 找人。
static func find_by_id(container, monster_id: String) -> Node2D:
	if container == null or monster_id.is_empty():
		return null
	for child in container.get_children():
		if child is Node2D and str(child.get("editor_id")) == monster_id:
			return child
	return null


static func apply_transform(container, monster_id: String, position: Vector2, scale: Vector2) -> bool:
	var monster := find_by_id(container, monster_id)
	if monster == null:
		return false
	monster.global_position = position
	monster.scale = scale
	if monster.has_method("sync_physics_from_node"):
		monster.sync_physics_from_node(true)
	return true
