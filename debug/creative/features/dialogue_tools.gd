extends RefCounted
## 地图对话触发器的**文档操作**：建节点、拾取、按 id 查找/删除。
##
## 容器创建、id 计数器、选中与撤销记录仍由 `creative` 负责。

const TriggerScript := preload("res://map/src/map_dialogue_trigger.gd")


## 建一个触发器并挂进容器。**不设 owner、不记历史**——那是装配与命令层的事。
static func create(container, world_position: Vector2, lines: PackedStringArray,
		trigger_id: String) -> Node2D:
	if container == null or lines.is_empty():
		return null
	var trigger := TriggerScript.new() as Node2D
	trigger.name = "DialogueTrigger"
	trigger.set("lines", lines.duplicate())
	trigger.set("editor_id", trigger_id)
	container.add_child(trigger, true)
	trigger.global_position = world_position
	return trigger


## 命中判定用触发器自己的触发矩形；多个重叠时取离点击点最近的一个。
static func find_at(container, world_position: Vector2) -> Node2D:
	if container == null:
		return null
	var nearest: Node2D = null
	var nearest_distance: float = INF
	for child in container.get_children():
		if not child is Node2D or not child.is_in_group(TriggerScript.GROUP):
			continue
		if not child.trigger_rect().has_point(world_position):
			continue
		var distance: float = child.global_position.distance_to(world_position)
		if distance < nearest_distance:
			nearest = child
			nearest_distance = distance
	return nearest


static func find_by_id(container, trigger_id: String) -> Node2D:
	if container == null or trigger_id.is_empty():
		return null
	for child in container.get_children():
		if str(child.get("editor_id")) == trigger_id:
			return child as Node2D
	return null


static func remove_by_id(container, trigger_id: String) -> bool:
	var trigger := find_by_id(container, trigger_id)
	if trigger == null:
		return false
	container.remove_child(trigger)
	trigger.queue_free()
	return true


## 分配一个未被占用的 dialogue id；返回 {"id", "next"}，计数器由调用方保存。
static func allocate_id(container, counter: int) -> Dictionary:
	while counter <= 1_000_000:
		var candidate := "dialogue_%d" % counter
		counter += 1
		if find_by_id(container, candidate) == null:
			return {"id": candidate, "next": counter}
	return {"id": "", "next": counter}
