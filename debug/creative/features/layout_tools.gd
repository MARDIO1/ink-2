extends RefCounted
## 布局物件（画布 / 复活点 / 传送门 / 墨泉）的**文档操作**。
##
## 只负责在关卡里「找、建、删」。**不做撤销、不碰叠加层、不碰输入**——
## 历史与界面由调用方（`creative.gd`）负责。这样这块逻辑可以脱离编辑器单独验证。
##
## 常量在这里定义一份，`creative` 用别名引用，避免两处漂移。

const RESPAWN_PREFIX := "RespawnPoint"
const RESPAWN_GROUP := &"respawn_point"
const PORTAL_PREFIX := "Portal"
const FOUNTAIN_PREFIX := "InkFountain"
const RespawnPoint := preload("res://map/src/respawn_point.gd")

const MapPortalScene := preload("res://actor/portal/map_portal.tscn")
const MapPortalScript := preload("res://actor/portal/src/map_portal.gd")
const InkFountainScene := preload("res://actor/fountain/ink_fountain.tscn")
const InkFountainScript := preload("res://actor/fountain/src/ink_fountain.gd")


static func collect(root: Node) -> Array:
	var result: Array = []
	for child in root.get_children():
		result.append(child)
		result.append_array(collect(child))
	return result


## 同名节点自动加序号，避免 `add_child` 触发 Godot 的改名。
static func unique_name(level, prefix: String) -> String:
	if level == null:
		return prefix
	var suffix := 1
	var candidate := prefix
	while level.get_node_or_null(NodePath(candidate)) != null:
		suffix += 1
		candidate = "%s%d" % [prefix, suffix]
	return candidate


## 复活点：分组优先，兼容仅有命名前缀的旧地图。
static func respawn_points(level, spawn_point) -> Array:
	var result: Array = []
	if level == null:
		return result
	for node in collect(level):
		if node is Marker2D and node != spawn_point \
		and (node.is_in_group(RESPAWN_GROUP) or String(node.name).begins_with(RESPAWN_PREFIX)):
			if not node.is_in_group(RESPAWN_GROUP):
				node.add_to_group(RESPAWN_GROUP, true)
			if node.get_script() == null:
				node.set_script(RespawnPoint)
			result.append(node)
	return result


static func portals(level) -> Array:
	var result: Array = []
	if level == null:
		return result
	for child in level.get_children():
		if child.is_in_group(MapPortalScript.GROUP):
			result.append(child)
	return result


static func ink_fountains(level) -> Array:
	var result: Array = []
	if level == null:
		return result
	for node in collect(level):
		if node.is_in_group(InkFountainScript.GROUP):
			result.append(node)
	return result


static func create_respawn_point(level, world_position: Vector2) -> Marker2D:
	if level == null:
		return null
	var point := RespawnPoint.new()
	point.name = unique_name(level, RESPAWN_PREFIX)
	level.add_child(point)
	point.global_position = world_position
	point.add_to_group(RESPAWN_GROUP, true)
	point.owner = level
	return point


## 删除恢复和放置重做共用完整配置，不能丢失独立的触发区域。
static func capture_respawn_point(point: Marker2D) -> Dictionary:
	return {"rotation": point.global_rotation, "scale": point.scale,
		"activation_size": point.activation_size if point is RespawnPoint else RespawnPoint.DEFAULT_ACTIVATION_SIZE,
		"activation_offset": point.activation_offset if point is RespawnPoint else Vector2.ZERO}


static func restore_respawn_point(point: Marker2D, settings: Dictionary) -> void:
	if settings.is_empty():
		return
	point.global_rotation = settings.rotation
	point.scale = settings.scale
	point.activation_size = settings.activation_size
	point.activation_offset = settings.activation_offset


static func create_portal(level, world_position: Vector2, destination := "") -> Node2D:
	if level == null:
		return null
	var portal := MapPortalScene.instantiate() as Node2D
	portal.name = unique_name(level, PORTAL_PREFIX)
	portal.target_map = destination
	level.add_child(portal)
	portal.global_position = world_position
	portal.owner = level
	return portal


static func create_ink_fountain(level, world_position: Vector2) -> Node2D:
	if level == null:
		return null
	var fountain := InkFountainScene.instantiate() as Node2D
	fountain.name = unique_name(level, FOUNTAIN_PREFIX)
	level.add_child(fountain)
	fountain.global_position = world_position
	# 固定尺寸只存在于打包场景内部，编辑器永远不修改根节点 scale。
	fountain.scale = Vector2.ONE
	fountain.owner = level
	return fountain


## 从关卡里摘掉并释放。撤销/重做由调用方通过历史记录负责重建。
static func destroy(node) -> void:
	if node == null or not is_instance_valid(node):
		return
	var parent = node.get_parent()
	if parent != null:
		parent.remove_child(node)
	node.queue_free()


#region 拾取
## 候选项与半径由调用方给，模块不认识视口/相机。
static func pick_respawn_point(points: Array, position: Vector2, radius: float) -> Marker2D:
	var nearest: Marker2D = null
	var nearest_distance := radius
	for point in points:
		var distance: float = point.global_position.distance_to(position)
		if distance <= nearest_distance:
			nearest = point
			nearest_distance = distance
	return nearest


static func pick_play_canvas(canvases: Array, position: Vector2) -> Node2D:
	for index in range(canvases.size() - 1, -1, -1):
		var canvas = canvases[index]
		if Rect2(Vector2.ZERO, Vector2(canvas.get("canvas_size"))).has_point(canvas.to_local(position)):
			return canvas
	return null


static func pick_portal(portals: Array, position: Vector2) -> Node2D:
	for index in range(portals.size() - 1, -1, -1):
		if portals[index].contains_world_point(position):
			return portals[index]
	return null


static func pick_ink_fountain(fountains: Array, position: Vector2) -> Node2D:
	for index in range(fountains.size() - 1, -1, -1):
		if fountains[index].contains_world_point(position):
			return fountains[index]
	return null
#endregion


#region 拖动状态
## 开始拖一个布局对象。只改 `session`，不碰相机/怪物视图——那属于编辑器输入层。
static func begin_drag(session, target, world_position: Vector2) -> void:
	session.layout_drag_target = target
	session.layout_drag_offset = target.global_position - world_position
	session.layout_drag_start = target.global_position
	session.layout_drag_start_scale = target.scale
	session.layout_drag_resizing = false


## 结束拖动：返回"应当记录的编辑"，没有实际变化就返回空字典。
## 无论是否记录，拖动态总是被清空——避免中途切换工具时留下悬挂的拖动目标。
static func finish_drag(session) -> Dictionary:
	var target = session.layout_drag_target
	var start: Vector2 = session.layout_drag_start
	var start_scale: Vector2 = session.layout_drag_start_scale
	cancel_drag(session)
	if target == null or not is_instance_valid(target):
		return {}
	if target.global_position.is_equal_approx(start) and target.scale.is_equal_approx(start_scale):
		return {}
	return {
		"type": &"object_transform",
		"target": target,
		"old_position": start,
		"old_scale": start_scale,
	}


static func cancel_drag(session) -> void:
	session.layout_drag_target = null
	session.layout_drag_offset = Vector2.ZERO
	session.layout_drag_start = Vector2.ZERO
	session.layout_drag_start_scale = Vector2.ONE
	session.layout_drag_resizing = false
#endregion
