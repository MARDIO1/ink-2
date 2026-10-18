extends RefCounted
## 齿轮轴承的明确放置、回收与迁移。
##
## 这里的每个函数只处理“已经明确存在”的轴承：
## 工具点击、撤销恢复、蓝图放置或旧存档连接。绝不因为某个中心存在就补轴承。
const SelectionMask := preload("res://actor/canvas/src/selection_mask.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Stroke := preload("res://ink/yellow/src/stroke.gd")
const GearCenters := preload("res://actor/canvas/src/gear_centers.gd")
const Axle := preload("res://ink/yellow/src/axle.gd")
const AxleScene := preload("res://ink/yellow/axle.tscn")


static func host_of(surface):
	var canvas = surface.get_parent()
	return canvas.world if canvas != null else null


static func resolve_target(surface, point: Vector2, options: Dictionary = {}) -> Dictionary:
	var host = host_of(surface)
	if host == null:
		return {}
	var snap_enabled: bool = bool(options.get("snap", true))
	var target: Dictionary = {}
	if snap_enabled:
		target = GearCenters.query(surface, host, point)
	else:
		target = GearCenters.body_at(surface, host, point)
		if target.is_empty() and surface._inside(point):
			var material: int = surface.material_at(int(point.x), int(point.y))
			if material != 0:
				target = {"kind": "draft", "record": GearCenters.make(point, GearCenters.DEFAULT_RADIUS, material, -1),
					"position": point, "world_position": surface.to_global(point)}
	if target.is_empty():
		return {}
	if target.kind == "draft":
		var record: Dictionary = target.record
		var local := GearCenters.position_of(record)
		for pending in surface.draft_bearings:
			if Vector2(pending.position).distance_squared_to(local) < 0.25:
				target["error"] = "这个轴心已经装有轴承"
				return target
		var on_yellow: bool = surface.rod_layer != null \
			and surface.rod_layer.pixels.get_pixelv(Vector2i(local.floor())).a > 0.5
		var candidates := GearCenters.support_candidates(host, null, target.world_position)
		var count: int = candidates.size() + int(on_yellow)
		target["support_count"] = count
		var choice := _support_index(candidates, options, on_yellow)
		if choice == -2:
			target["error"] = "选中支座已失效，请重新选择"
			return target
		if count > 1 and choice < 0:
			target["error"] = "多个支座重叠，按 Tab 选择支座后再放置"
			return target
		var selected := posmod(choice, count) if choice >= 0 and count > 0 else 0
		target["fixed_to_world"] = count == 0
		target["support"] = null
		target["wheel_local"] = local
		target["wheel_material"] = GearCenters.material_of(record)
		target["support_position"] = local
		target["support_material"] = Palette.YELLOW.id if on_yellow and selected == 0 else 0
		if count > 0 and not (on_yellow and selected == 0):
			var support: Dictionary = candidates[selected - int(on_yellow)]
			target["support"] = support.body
			target["support_local"] = support.local
			target["support_position"] = surface.to_local(support.body.to_world(support.local))
			target["support_material"] = int(support.material)
		return target
	var wheel = target.body
	if wheel == null:
		return {}
	var local: Vector2 = target.local
	var wheel_material: int = 0
	for shape in wheel.shapes:
		wheel_material = shape.get_pixel(int(floorf(local.x)), int(floorf(local.y)))
		if wheel_material != 0:
			break
	if wheel_material == 0:
		return {}
	target["wheel_material"] = wheel_material
	target["wheel_local"] = local
	if existing_at(host, wheel, local) != null:
		target["error"] = "这个轴心已经装有轴承"
		return target
	var candidates := GearCenters.support_candidates(host, wheel, target.world_position)
	target["support_count"] = candidates.size()
	var choice := _support_index(candidates, options)
	if choice == -2:
		target["error"] = "选中支座已失效，请重新选择"
		return target
	if candidates.size() > 1 and choice < 0:
		target["error"] = "多个支座重叠，按 Tab 选择支座后再放置"
		return target
	if not candidates.is_empty():
		# 多支座必须由用户选择；预览与点击使用同一索引。
		var support: Dictionary = candidates[posmod(choice, candidates.size()) if choice >= 0 else 0]
		target["support"] = support.body
		target["support_cell"] = support.cell
		target["support_local"] = support.local
		target["support_material"] = int(support.material)
		target["support_position"] = surface.to_local(support.body.to_world(Vector2(support.cell) + Vector2.ONE * 0.5))
		target["fixed_to_world"] = false
	else:
		target["support"] = null
		target["support_position"] = target.position
		target["support_material"] = 0
		target["fixed_to_world"] = true
	return target


## 用户选中的支座以对象身份保持；候选排序变化不能改变实际连接目标。
static func _support_index(candidates: Array, options: Dictionary, draft_yellow := false) -> int:
	if bool(options.get("draft_support", false)):
		return 0 if draft_yellow else -2
	if options.get("support_body") != null:
		for index in candidates.size():
			if candidates[index].body == options.support_body:
				return index + int(draft_yellow)
		return -2
	return int(options.get("support_index", -1))


static func install(surface, target: Dictionary) -> bool:
	if target.is_empty() or target.has("error"):
		return false
	var host = host_of(surface)
	if host == null:
		return false
	if target.kind == "draft":
		var record: Dictionary = target.record
		var position := GearCenters.position_of(record)
		var support_position := Vector2(target.get("support_position", position))
		var fixed: bool = bool(target.get("fixed_to_world", true))
		if surface.add_draft_bearing(position, fixed, support_position,
				int(target.get("support_material", 0)), int(record.get("id", -1))):
			var pending: Dictionary = surface.draft_bearings.back()
			pending["wheel_material"] = int(target.get("wheel_material", 0))
			if target.get("support") != null:
				var node = GearCenters.node_for_body(host, target.support)
				if node != null:
					pending["support_path"] = host.get_path_to(node)
			return true
		surface.notice_requested.emit("这个轴心已经装有轴承")
		return false
	var wheel = target.body
	if wheel == null or existing_at(host, wheel, target.wheel_local) != null:
		surface.notice_requested.emit("这个轴心已经装有轴承")
		return false
	var support = target.get("support")
	if support != null and support == wheel:
		surface.notice_requested.emit("支座不能是轮体自身")
		return false
	return _spawn(surface, host, target.position, target.wheel_local, wheel,
		int(target.get("wheel_material", 0)), support, target.get("support_local", Vector2.ZERO),
		int(target.get("support_material", 0)), bool(target.get("fixed_to_world", true)))


static func existing_at(host, wheel, local: Vector2):
	if host == null:
		return null
	for child in host.get_children():
		if not child is Axle or child.is_queued_for_deletion() or child.yellow_anchor.is_empty():
			continue
		if child.yellow_anchor.body != wheel:
			continue
		var anchor_local: Vector2 = child.yellow_anchor.get("local", Vector2.INF)
		if anchor_local.distance_squared_to(local) <= 0.25:
			return child
	return null


## 回收画布矩形内的轴承为草稿记录；不碰中心、轮体或黄杆。
static func reclaim(surface, host, rect: Rect2i, mask: Dictionary = {},
		preserved: Dictionary = {}) -> Array:
	var out: Array = []
	if host == null:
		return out
	for child in host.get_children().duplicate():
		if not child is Axle or child.is_queued_for_deletion() or child.yellow_anchor.is_empty():
			continue
		if preserved.has(child.yellow_anchor.body):
			continue
		if not child.black_anchor.is_empty() and preserved.has(child.black_anchor.body):
			continue
		var wheel_point: Vector2 = surface.to_local(host.to_global(
			Stroke.anchor_world(child.yellow_anchor)))
		var cell := Vector2i(wheel_point.floor())
		if not rect.has_point(cell) or not SelectionMask.contains(mask, cell):
			continue
		var record := _record(surface, host, child)
		child.remove_joint()
		host.remove_child(child)
		child.queue_free()
		if not _has_record_near(surface.draft_bearings, record.position):
			surface.draft_bearings.append(record)
		out.append(record)
	return out


## 框选移动/旋转前取走轴承，返回的记录带原始刚体引用，供新刚体立刻接回。
static func take(surface, host, rect: Rect2i, mask: Dictionary = {}, skip_bodies: Dictionary = {}) -> Array:
	var out: Array = []
	if host == null:
		return out
	for child in host.get_children().duplicate():
		if not child is Axle or child.is_queued_for_deletion() or child.yellow_anchor.is_empty():
			continue
		if skip_bodies.has(child.yellow_anchor.body):
			continue
		var wheel_point: Vector2 = surface.to_local(host.to_global(
			Stroke.anchor_world(child.yellow_anchor)))
		var cell := Vector2i(wheel_point.floor())
		if not rect.has_point(cell) or not SelectionMask.contains(mask, cell):
			continue
		var record := _record(surface, host, child)
		if not child.black_anchor.is_empty():
			record["support_body"] = child.black_anchor.body
		out.append(record)
		child.remove_joint()
		host.remove_child(child)
		child.queue_free()
	return out


## 把草稿/迁移记录重新接到世界里。返回无法恢复的记录（支座缺失时不偷偷连世界）。
static func restore(surface, records: Array) -> Array:
	var host = host_of(surface)
	var leftovers: Array = []
	if host == null:
		return records.duplicate(true)
	for raw in records:
		var record: Dictionary = raw.duplicate()
		var position := Vector2(record.get("position", Vector2.ZERO))
		if not GearCenters.inside(position, surface.canvas_size):
			leftovers.append(record)
			continue
		var wheel := GearCenters.find_wheel(host, surface.to_global(position), 4.0,
			int(record.get("wheel_material", 0)))
		if wheel.is_empty():
			leftovers.append(record)
			continue
		var support = record.get("support_body")
		var path: NodePath = record.get("support_path", NodePath())
		if support == null and not path.is_empty():
			var node: Node = host.get_node_or_null(path)
			if node == null or node.get("body") == null:
				leftovers.append(record)
				continue
			support = node.body
		if support != null and (not is_instance_valid(support) or not host.world.bodies.has(support)):
			support = null
		var fixed: bool = bool(record.get("fixed_to_world", true))
		var support_local := Vector2(record.get("support_local", Vector2.ZERO))
		if support != null:
			support_local = support.to_local(surface.to_global(Vector2(record.get("support_position", position))))
		var support_material := int(record.get("support_material", 0))
		if not fixed and support == null:
			var support_position := Vector2(record.get("support_position", position))
			var matches: Array = GearCenters.support_candidates(host, wheel.body, surface.to_global(support_position))
			matches = matches.filter(func(candidate): return support_material == 0 or int(candidate.material) == support_material)
			if matches.size() == 1:
				var found: Dictionary = matches[0]
				support = found.body
				support_local = found.local
				support_material = int(found.material)
		if not fixed and support == null:
			leftovers.append(record)
			continue
		if existing_at(host, wheel.body, wheel.local) != null:
			continue
		if not _spawn(surface, host, position, wheel.local, wheel.body, int(wheel.material),
			support, support_local, support_material, fixed):
			leftovers.append(record)
	for pending in leftovers:
		if not _has_record_near(surface.draft_bearings, pending.position):
			surface.draft_bearings.append(pending)
	return leftovers


## 黄色橡皮点击：删除附近真实轴承或草稿轴承，保留中心标记。
static func erase_at(surface, point: Vector2, radius := 6.5) -> bool:
	var host = host_of(surface)
	if host == null:
		return false
	var removed := false
	for child in host.get_children().duplicate():
		if not child is Axle or child.is_queued_for_deletion() or child.yellow_anchor.is_empty():
			continue
		var wheel_point: Vector2 = surface.to_local(host.to_global(
			Stroke.anchor_world(child.yellow_anchor)))
		if wheel_point.distance_to(point) > radius:
			continue
		child.remove_joint()
		host.remove_child(child)
		child.queue_free()
		removed = true
	var keep: Array = []
	for record in surface.draft_bearings:
		if Vector2(record.get("position", Vector2.ZERO)).distance_to(point) > radius:
			keep.append(record)
		else:
			removed = true
	surface.draft_bearings = keep
	return removed


static func _spawn(surface, host, canvas_point: Vector2, wheel_local: Vector2, wheel,
		wheel_material: int, support, support_local: Vector2, support_material: int,
		fixed_to_world: bool) -> bool:
	if wheel == null or not GearCenters.body_has_pixel(wheel, Vector2i(wheel_local.floor())):
		return false
	if not fixed_to_world and (support == null or support == wheel or not GearCenters.body_has_pixel(support, Vector2i(support_local.floor()))):
		return false
	var world_point: Vector2 = surface.to_global(canvas_point)
	var axle = AxleScene.instantiate()
	axle.explicit = true
	axle.gear_material = wheel_material
	axle.yellow_position = host.to_local(world_point)
	axle.black_position = axle.yellow_position
	axle.yellow_anchor = {"body": wheel, "cell": Vector2i(wheel_local.floor()),
		"local": wheel_local}
	axle.fixed_to_world = fixed_to_world
	# 手动安装的轴承必须可见，即使它连接的是黄墨支座。
	axle.hide_bearing = false
	var wheel_node = GearCenters.node_for_body(host, wheel)
	if not fixed_to_world and support != null:
		axle.support_material = support_material
		axle.black_anchor = {"body": support, "cell": Vector2i(support_local.floor()),
			"local": support_local}
		axle.black_position = host.to_local(support.to_world(support_local))
	elif not fixed_to_world:
		return false
	host.add_child(axle)
	axle.owner = host
	if wheel_node != null:
		axle.wheel_path = axle.get_path_to(wheel_node)
	if not fixed_to_world and support != null:
		var support_node = GearCenters.node_for_body(host, support)
		if support_node != null:
			axle.support_path = axle.get_path_to(support_node)
	axle.connect_joint()
	axle._process(0.0)
	return true


static func _record(surface, host, child) -> Dictionary:
	var wheel_point: Vector2 = surface.to_local(host.to_global(
		Stroke.anchor_world(child.yellow_anchor)))
	var support_point := wheel_point
	var support_material := 0
	var support_local := Vector2.ZERO
	if not child.black_anchor.is_empty():
		support_point = surface.to_local(host.to_global(
			Stroke.anchor_world(child.black_anchor)))
		support_local = Vector2(child.black_anchor.get("local", Vector2.ZERO))
		support_material = (child.support_material if child.black_anchor.body != child.yellow_anchor.body
			else 0)
	return {"position": wheel_point,
		"fixed_to_world": bool(child.fixed_to_world),
		"wheel_material": int(child.gear_material),
		"support_position": support_point,
		"support_local": support_local,
		"support_material": support_material,
		"legacy": not bool(child.explicit)}


static func _has_record_near(records: Array, point: Vector2) -> bool:
	for record in records:
		if Vector2(record.get("position", Vector2.ZERO)).distance_squared_to(point) < 0.25:
			return true
	return false
