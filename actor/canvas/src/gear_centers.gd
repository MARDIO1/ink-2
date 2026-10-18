extends RefCounted
## 齿轮中心记录的唯一真源。
##
## 中心只回答“这里有一个可吸附的轴心”，绝不隐含“这里应该有一个轴承”。
## 草稿中的 `position` 是画布局部坐标；实体上的 `position` 是所属刚体的局部坐标。
## 轴承由 `gear_bearings.gd` / `axle.gd` 单独记录，必须来自明确的放置或已有存档连接。
##
## 本模块只做记录归一化、坐标转换、查询与归属转移；不推进物理、不写文件、不建 UI。
const SelectionMask := preload("res://actor/canvas/src/selection_mask.gd")
const DEFAULT_RADIUS := 48.0
const MAX_SNAP := 8.0
const TAG := "gear_centers"
const _MISSING := -2147483648

static var _sequence := 0


static func _new_id() -> int:
	_sequence = maxi(_sequence + 1, int(Time.get_unix_time_from_system() * 1000000.0))
	return _sequence


## 旧记录没有 id 时用位置生成稳定值，避免每次读盘都换身份。
static func _stable_id(position: Vector2) -> int:
	var x := int(roundf(position.x * 16.0))
	var y := int(roundf(position.y * 16.0))
	return (x * 73856093) ^ (y * 19349663) ^ 0x5f3759df


static func make(position: Vector2, radius := DEFAULT_RADIUS, material := 0, id := _MISSING) -> Dictionary:
	return {
		"id": _new_id() if id == _MISSING else id,
		"position": Vector2(position),
		"radius": maxf(float(radius), 1.0),
		"material": int(material),
	}


## 把任何历史形态归一成记录数组：Vector2 / [x,y] / {position:[x,y]} / {position:Vector2}。
## 缺半径的旧记录采用保守吸附范围，不重新分析轮廓猜测尺寸。
static func normalize(raw) -> Array:
	var out: Array = []
	if raw == null:
		return out
	var items = raw
	if items is PackedVector2Array:
		items = Array(items)
	if not items is Array:
		return out
	for entry in items:
		var record := _normalize_one(entry)
		if not record.is_empty():
			out.append(record)
	return out


static func _normalize_one(entry) -> Dictionary:
	if entry is Vector2:
		return make(entry, DEFAULT_RADIUS, 0, _stable_id(entry))
	if entry is Dictionary:
		var position = entry.get("position", null)
		if position is Array and position.size() >= 2:
			position = Vector2(float(position[0]), float(position[1]))
		if not position is Vector2:
			return {}
		var radius := float(entry.get("radius", DEFAULT_RADIUS))
		if not is_finite(radius) or radius <= 0.0:
			radius = DEFAULT_RADIUS
		var id_value = entry.get("id", _MISSING)
		var id := int(id_value) if (id_value is int or id_value is float) else _stable_id(position)
		_sequence = maxi(_sequence, id)
		var material := int(entry.get("material", 0))
		return {"id": id, "position": Vector2(position), "radius": radius, "material": material}
	if entry is Array and entry.size() >= 2 and (entry[0] is float or entry[0] is int) \
	and (entry[1] is float or entry[1] is int):
		var point := Vector2(float(entry[0]), float(entry[1]))
		return make(point, DEFAULT_RADIUS, 0, _stable_id(point))
	return {}


static func positions(records: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for record: Dictionary in records:
		out.append(Vector2(record.get("position", Vector2.ZERO)))
	return out


static func position_of(record: Dictionary) -> Vector2:
	return Vector2(record.get("position", Vector2.ZERO))


static func radius_of(record: Dictionary) -> float:
	return maxf(float(record.get("radius", DEFAULT_RADIUS)), 1.0)


static func material_of(record: Dictionary) -> int:
	return int(record.get("material", 0))


## 吸附距离：世界坐标中的 8 px 与齿轮半径的 1/4 取小。
static func snap_distance(record: Dictionary) -> float:
	return minf(MAX_SNAP, radius_of(record) * 0.25)


static func inside(point: Vector2, size: Vector2i) -> bool:
	return point.x >= 0.0 and point.y >= 0.0 \
		and point.x < float(size.x) and point.y < float(size.y)


static func body_records(body) -> Array:
	if body == null:
		return []
	return normalize(body.tags.get(TAG, []))


static func set_body_records(body, records: Array) -> void:
	if body == null:
		return
	var normalized := normalize(records)
	if normalized.is_empty():
		body.tags.erase(TAG)
	else:
		body.tags[TAG] = normalized


static func body_has_pixel(body, cell: Vector2i) -> bool:
	if body == null:
		return false
	for shape in body.shapes:
		if shape.get_pixel(cell.x, cell.y) != 0:
			return true
	return false


static func record_alive(body, record: Dictionary) -> bool:
	return body_has_pixel(body, Vector2i(position_of(record).floor()))


## 轮体可能有多个（黄杆也穿过中心）；优先材质匹配，再用中心附近像素数打分。
## 不使用世界遍历顺序决定归属。
static func find_wheel(host, world_point: Vector2, radius: float, material := 0) -> Dictionary:
	if host == null or host.get("world") == null:
		return {}
	var physics = host.world
	var candidates: Array = []
	for body in physics.bodies:
		if body == null or body.tags.has("living") or body.tags.has("map_monster"):
			continue
		var local: Vector2 = body.to_local(world_point)
		var cell := Vector2i(local.floor())
		if not body_has_pixel(body, cell):
			continue
		var hit_material := 0
		for shape in body.shapes:
			hit_material = shape.get_pixel(cell.x, cell.y)
			if hit_material != 0:
				break
		candidates.append({"body": body, "local": local, "cell": cell,
			"material": hit_material, "score": _body_disk_score(body, local, maxf(radius, 4.0))})
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(a, b):
		var a_match: bool = material != 0 and int(a.material) == material
		var b_match: bool = material != 0 and int(b.material) == material
		if a_match != b_match:
			return a_match
		if int(a.score) != int(b.score):
			return int(a.score) > int(b.score)
		return a.body.get_instance_id() < b.body.get_instance_id())
	return candidates[0]


## 中心是否仍是有效吸附点；失效记录停止吸附，不再空中保留可点击目标。
static func entity_center(surface, host, record: Dictionary, body) -> Dictionary:
	if body == null or not record_alive(body, record):
		return {}
	var world_point: Vector2 = body.to_world(position_of(record))
	var local_point: Vector2 = surface.to_local(world_point)
	if not inside(local_point, surface.canvas_size):
		return {}
	return {"kind": "body", "record": record, "body": body, "local": position_of(record),
		"position": local_point, "world_position": world_point, "radius": radius_of(record)}


## 查询一个画布局部点附近的有效中心：草稿优先，其次实体；返回统一的放置目标。
static func query(surface, host, point: Vector2, max_distance := -1.0) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := INF
	var pointer: Vector2 = surface.to_global(point)
	for record in normalize(surface.gear_centers):
		var local := position_of(record)
		if not inside(local, surface.canvas_size) or surface.material_at(int(local.x), int(local.y)) == 0:
			continue
		var distance: float = pointer.distance_to(surface.to_global(local))
		var limit := max_distance if max_distance >= 0.0 else snap_distance(record)
		if distance <= limit and distance < best_distance:
			best_distance = distance
			best = {"kind": "draft", "record": record, "position": local,
				"world_position": surface.to_global(local), "radius": radius_of(record), "distance": distance}
	if host == null or host.get("world") == null:
		return best
	for body in host.world.bodies:
		if body == null or body.tags.has("living") or body.tags.has("map_monster"):
			continue
		for record in body_records(body):
			var candidate := entity_center(surface, host, record, body)
			if candidate.is_empty():
				continue
			var distance: float = pointer.distance_to(surface.to_global(candidate.position))
			var limit := max_distance if max_distance >= 0.0 else snap_distance(record)
			if distance > limit or distance > best_distance:
				continue
			candidate["distance"] = distance
			best = candidate
			best_distance = distance
	return best


## 找出包含该点的非生物刚体（Alt 偏心安装用）；材质优先，避免抓到压在上面的黄杆。
static func body_at(surface, host, point: Vector2, exclude: Array = []) -> Dictionary:
	if host == null or host.get("world") == null:
		return {}
	var desired: int = surface.material_at(int(point.x), int(point.y))
	var world_point: Vector2 = surface.to_global(point)
	var found := find_wheel(host, world_point, 4.0, desired)
	if found.is_empty() or exclude.has(found.body):
		return {}
	return {"kind": "body", "body": found.body, "local": found.local,
		"position": point, "world_position": world_point, "radius": 0.0,
		"record": make(found.local, DEFAULT_RADIUS, found.material, _stable_id(found.local))}


## 在轮体中心附近找“明确支座”：排除轮体自身、玩家和小怪。
## 返回按固定规则排序的候选，预览与点击必须共用同一结果。
static func support_candidates(host, wheel, world_point: Vector2) -> Array:
	if host == null or host.get("world") == null:
		return []
	var candidates: Array = []
	for body in host.world.bodies:
		if body == null or body == wheel or body.tags.has("living") \
		or body.tags.has("map_monster") or body.tags.has("player") or body.tags.has("hand"):
			continue
		var local: Vector2 = body.to_local(world_point)
		var cell := Vector2i(local.floor())
		var material := 0
		for shape in body.shapes:
			material = shape.get_pixel(cell.x, cell.y)
			if material != 0:
				break
		if material == 0:
			continue
		candidates.append({"body": body, "cell": cell, "local": local, "material": material})
	candidates.sort_custom(func(a, b):
		var ac: Vector2 = a.body.com_world() if a.body.has_method("com_world") else a.body.position
		var bc: Vector2 = b.body.com_world() if b.body.has_method("com_world") else b.body.position
		var ad: float = ac.distance_squared_to(world_point)
		var bd: float = bc.distance_squared_to(world_point)
		if not is_equal_approx(ad, bd):
			return ad < bd
		return a.body.get_instance_id() < b.body.get_instance_id())
	return candidates


static func _body_disk_score(body, local: Vector2, radius: float) -> int:
	var extent := mini(ceili(radius), 16)
	var score := 0
	for y in range(-extent, extent + 1):
		for x in range(-extent, extent + 1):
			if x * x + y * y > extent * extent:
				continue
			var cell := Vector2i(local) + Vector2i(x, y)
			if body_has_pixel(body, cell):
				score += 1
	return score


## 把草稿中心交给包含其有效像素的刚体；不重建轮廓、不创建轴承。
static func attach(surface, host, records: Array) -> Array:
	var attached: Array = []
	for record in normalize(records):
		var canvas_point := position_of(record)
		if not inside(canvas_point, surface.canvas_size):
			continue
		var wheel := find_wheel(host, surface.to_global(canvas_point),
			radius_of(record), material_of(record))
		if wheel.is_empty():
			continue
		var local: Vector2 = wheel.local
		var local_record := make(local, radius_of(record), int(wheel.material), int(record.id))
		_add_body_record(host, wheel.body, local_record)
		attached.append({"body": wheel.body, "record": local_record})
	return attached


## 从框选/旋转区域取出实体中心并从原刚体移除，供新刚体接管。
static func take_in_rect(surface, host, rect: Rect2i, mask: Dictionary = {}, skip_bodies: Dictionary = {}) -> Array:
	var out: Array = []
	if host == null or host.get("world") == null:
		return out
	for body in host.world.bodies:
		if body == null or body.tags.has("living") or skip_bodies.has(body):
			continue
		var keep: Array = []
		var changed := false
		for record in body_records(body):
			var world_point: Vector2 = body.to_world(position_of(record))
			var local_point: Vector2 = surface.to_local(world_point)
			var cell := Vector2i(local_point.floor())
			if record_alive(body, record) and rect.has_point(cell) \
			and SelectionMask.contains(mask, cell):
				out.append({"position": local_point, "radius": radius_of(record),
					"material": material_of(record), "id": int(record.get("id", _stable_id(local_point)))})
				changed = true
			else:
				keep.append(record)
		if changed:
			set_body_records(body, keep)
	return out


## 回收整块刚体落在画布里的中心，交给画布草稿；画布外的中心留在刚体上。
static func reclaim_body(surface, body) -> Array:
	var out: Array = []
	var keep: Array = []
	for record in body_records(body):
		if not record_alive(body, record):
			continue
		var local_point: Vector2 = surface.to_local(body.to_world(position_of(record)))
		if not inside(local_point, surface.canvas_size):
			keep.append(record)
			continue
		var draft := make(local_point, radius_of(record), material_of(record), int(record.get("id", _stable_id(local_point))))
		if not _has_center_near(surface.gear_centers, local_point):
			surface.gear_centers.append(draft)
		out.append(draft)
	set_body_records(body, keep)
	return out


## 破坏后把中心交给仍包含中心像素的碎片；没有对应像素就丢弃。
static func observe_fracture(body, pieces: Array) -> void:
	var records := body_records(body)
	if records.is_empty():
		return
	var remaining: Array = []
	for record in records:
		var cell := Vector2i(position_of(record).floor())
		var owner = null
		for piece in pieces:
			if piece != null and body_has_pixel(piece, cell):
				owner = piece
				break
		if owner == null:
			continue
		if owner == body:
			remaining.append(record)
		else:
			_add_body_record_direct(owner, record)
	set_body_records(body, remaining)


## 刚体原位蚀除后，清掉中心像素已经消失的记录。
static func prune(body) -> void:
	var records := body_records(body)
	if records.is_empty():
		return
	var keep: Array = []
	for record in records:
		if record_alive(body, record):
			keep.append(record)
	set_body_records(body, keep)


static func _add_body_record(host, body, record: Dictionary) -> void:
	_add_body_record_direct(body, record)
	var node = node_for_body(host, body)
	if node != null and node.get("gear_centers") != null:
		node.set("gear_centers", body_records(body))
		if node.has_method("ensure_gear_center_markers"):
			node.ensure_gear_center_markers()


static func _add_body_record_direct(body, record: Dictionary) -> void:
	var records := body_records(body)
	if _has_center_near(records, position_of(record)):
		return
	records.append(record)
	set_body_records(body, records)


static func _has_center_near(records: Array, point: Vector2) -> bool:
	for record in records:
		if position_of(record).distance_squared_to(point) < 0.0001:
			return true
	return false


static func node_for_body(host, body):
	if host == null or host.get("world") == null or body == null:
		return null
	host.realign_body_nodes()
	var physics = host.world
	for index in mini(host._body_nodes.size(), physics.bodies.size()):
		if physics.bodies[index] == body:
			var node = host._body_nodes[index]
			return node if is_instance_valid(node) else null
	return null
#endregion
