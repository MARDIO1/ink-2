extends RefCounted
## 地图文字的**文档操作**：建节点、拾取、按 id 删除。
##
## 容器创建、字体加载、id 计数器与撤销记录仍由 `creative` 负责——
## 这里只碰"节点怎么建、怎么找、怎么删"，不持有编辑器状态。

const MapTextScript := preload("res://ui/map_text/src/map_text_label.gd")


## 建一个地图文字 Label 并挂进容器；`text_id` 为空时由调用方先分配。
## `font` 可为 null（沿用主题默认字体）。**不设 owner、不记历史**——那是装配与命令层的事。
static func create(container, world_position: Vector2, content: String, text_id: String,
		font: Font = null) -> Label:
	if container == null or content.is_empty():
		return null
	var label := MapTextScript.new() as Label
	label.name = "MapText"
	label.text = content
	if font != null:
		label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", 48)
	label.add_theme_color_override("font_color", Color(0.035, 0.031, 0.024, 1.0))
	label.add_theme_color_override("font_shadow_color", Color.TRANSPARENT)
	# 地图文字始终盖在地面和固化墨迹上，避免被关卡实体遮住。
	label.z_index = 20
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.set("editor_id", text_id)
	container.add_child(label, true)
	label.global_position = world_position
	label.reset_size()
	return label


## 从后往前找：后放的在上层，点选时优先命中最上面那个。
static func find_at(container, world_position: Vector2, radius: float) -> Label:
	if container == null:
		return null
	var children: Array = container.get_children()
	for index in range(children.size() - 1, -1, -1):
		var child = children[index]
		if child is Label and child.is_in_group(MapTextScript.GROUP) \
		and child.contains_world_point(world_position, radius):
			return child as Label
	return null


static func find_by_id(container, text_id: String) -> Label:
	if container == null or text_id.is_empty():
		return null
	for child in container.get_children():
		if str(child.get("editor_id")) == text_id:
			return child as Label
	return null


static func remove_by_id(container, text_id: String) -> bool:
	var label = find_by_id(container, text_id)
	if label == null:
		return false
	container.remove_child(label)
	label.queue_free()
	return true


## 分配一个未被占用的 text id；返回 {"id": String, "next": int}，计数器由调用方保存。
static func allocate_id(container, counter: int) -> Dictionary:
	while true:
		var candidate := "text_%d" % counter
		counter += 1
		if find_by_id(container, candidate) == null:
			return {"id": candidate, "next": counter}
		if counter > 1_000_000:
			return {"id": "", "next": counter}
	return {"id": "", "next": counter}
