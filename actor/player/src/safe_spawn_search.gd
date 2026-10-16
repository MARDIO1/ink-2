extends RefCounted
## 有界、分帧的只读落点搜索。复用已烘焙的精确像素矩形，不重建碰撞体。
const Collide := preload("res://addons/pixel_destruction/physics/collide.gd")
const Query := preload("res://addons/pixel_destruction/physics/query.gd")
const MAX_CANDIDATES := 192
const MAX_PAIRS := 30000
const FRAME_BUDGET_US := 2000
const SEARCH_RADII := [192.0, 384.0, 768.0, 1536.0]
const MAX_EXPANDED_CANDIDATES := MAX_CANDIDATES * 4
var owner: Node
var world
var player_body
var hand: Node
var excluded: Array = []
var candidates_checked := 0
var pairs_checked := 0
var frames_yielded := 0
var _frame_start := 0
var _sat := Collide.Sat.new()
var _pair_limit := MAX_PAIRS

func setup(controller: Node, physics_world, body, hand_control: Node) -> void:
	owner = controller
	world = physics_world
	player_body = body
	hand = hand_control
	excluded = [body]
	if hand != null:
		excluded.append_array([hand.body, hand.arm_body])
	_frame_start = Time.get_ticks_usec()

func _yield_if_needed() -> void:
	if Time.get_ticks_usec() - _frame_start >= FRAME_BUDGET_US:
		frames_yielded += 1
		await owner.get_tree().process_frame
		_frame_start = Time.get_ticks_usec()

func _obb(rect: Rect2, position: Vector2, rotation: float, margin := 0.0):
	var box := Collide.OBB.new()
	box.center = position + rect.get_center().rotated(rotation)
	box.u = Vector2.from_angle(rotation)
	box.v = Vector2(-box.u.y, box.u.x)
	box.h = rect.size * 0.5 + Vector2.ONE * margin
	return box

func _bounds(box) -> Rect2:
	var size: Vector2 = box.u.abs() * box.h.x + box.v.abs() * box.h.y
	return Rect2(box.center - size, size * 2.0)

func _pose_boxes(position: Vector2, rotation: float, actual_hand := false) -> Array:
	var result: Array = []
	for rect in player_body.rects:
		result.append(_obb(rect, position, rotation, 0.5))
	if hand != null:
		var offset: Vector2 = hand.rest_offset.limit_length(hand.max_reach - hand.reach_solver_margin)
		var hand_rotation: float = rotation
		var hand_position: Vector2 = position + player_body.local_com.rotated(rotation) \
			+ offset.rotated(rotation) - hand.body.local_com.rotated(hand_rotation)
		if actual_hand:
			hand_rotation = hand.body.rotation
			hand_position = hand.body.position
		for rect in hand.body.rects:
			result.append(_obb(rect, hand_position, hand_rotation, 0.5))
	return result

func _collidable(body) -> bool:
	return not excluded.has(body) and not body.rects.is_empty() \
		and (body.collision_layer & player_body.collision_mask) != 0 \
		and (player_body.collision_layer & body.collision_mask) != 0

func _nearby(bounds: Rect2) -> Array:
	var result: Array = []
	var count := 0
	for body in world.bodies:
		if _collidable(body) and bounds.intersects(body.aabb):
			result.append(body)
		count += 1
		if count % 128 == 0:
			await _yield_if_needed()
	return result

func pose_safe(position: Vector2, rotation: float, nearby: Array, actual_hand := false) -> bool:
	var boxes := _pose_boxes(position, rotation, actual_hand)
	if boxes.is_empty():
		return false
	for box in boxes:
		var bounds := _bounds(box)
		for obstacle in nearby:
			if not bounds.intersects(obstacle.aabb):
				continue
			for rect in obstacle.rects:
				if pairs_checked >= _pair_limit:
					return false
				pairs_checked += 1
				var other = Collide.obb_from_local_rect(obstacle, rect)
				if bounds.intersects(_bounds(other)):
					Collide.sat_signed_into(box, other, _sat)
					if _sat.sep < 0.0:
						return false
				if pairs_checked % 64 == 0:
					await _yield_if_needed()
	# 只接受下方 96 像素内有支撑的落点，不传送到空中深坑。
	var feet: Rect2 = _bounds(boxes[0])
	for rect in player_body.rects:
		feet = feet.merge(_bounds(_obb(rect, position, rotation)))
	for fraction in [0.25, 0.5, 0.75]:
		var origin := Vector2(feet.position.x + feet.size.x * fraction, feet.end.y + 0.6)
		var probe := Rect2(origin - Vector2(1, 0), Vector2(2, 96))
		for obstacle in nearby:
			if not probe.intersects(obstacle.aabb):
				continue
			var hit = Query._ray_vs_body(obstacle, origin, Vector2.DOWN, 96.0, 0.0)
			if hit.hit and hit.normal.y < -0.5:
				return true
			await _yield_if_needed()
	return false

func find(targets: Array, skipped: Array = [], radius := 192.0) -> Dictionary:
	var step: float = clampf(player_body.aabb.size.y * 0.25, 16.0, 32.0)
	var offsets: Array[Vector2] = []
	for vertical in [0, -1, 1, -2, 2, -3, 3, -4, 4, -6, 6]:
		for side in [0, -1, 1, -2, 2, -3, 3]:
			offsets.append(Vector2(side, vertical) * step * radius / 192.0)
	offsets.sort_custom(func(a, b):
		if a.length_squared() == b.length_squared():
			return a.y < b.y
		return a.length_squared() < b.length_squared())
	for target_index in targets.size():
		var target: Dictionary = targets[target_index]
		# 为后续经过的点保留预算，避免最近几个点占满所有候选名额。
		var target_limit := candidates_checked + maxi(1, (MAX_CANDIDATES - candidates_checked) / (targets.size() - target_index))
		var position: Vector2 = target.position
		var rotation: float = target.rotation
		var boxes := _pose_boxes(position, rotation)
		if boxes.is_empty():
			return {}
		var search_bounds := _bounds(boxes[0])
		for box in boxes:
			search_bounds = search_bounds.merge(_bounds(box))
		search_bounds = search_bounds.grow(radius)
		search_bounds.size.y += 96.0 # 最低候选位置下方的支撑也必须纳入查询。
		var nearby: Array = await _nearby(search_bounds)
		var candidates: Array = []
		for offset in offsets:
			candidates.append(position + offset)
		if radius > 192.0:
			# 直接从支撑表面生成脚下落点，避免扩大网格后漏掉窄平台。
			var feet := _bounds(_obb(player_body.rects[0], Vector2.ZERO, rotation))
			for rect in player_body.rects:
				feet = feet.merge(_bounds(_obb(rect, Vector2.ZERO, rotation)))
			for obstacle in nearby:
				for rect in obstacle.rects:
					var surface := _bounds(Collide.obb_from_local_rect(obstacle, rect))
					for x in [clampf(position.x + feet.get_center().x, surface.position.x + 1.0, surface.end.x - 1.0), surface.get_center().x]:
						var candidate := Vector2(x - feet.get_center().x, surface.position.y - feet.end.y - 2.0)
						if candidate.distance_squared_to(position) <= radius * radius:
							candidates.append(candidate)
					await _yield_if_needed()
			candidates.sort_custom(func(a, b): return a.distance_squared_to(position) < b.distance_squared_to(position))
		# 按距离由近到远覆盖上下左右；同距离优先向上避开碎屑。
		var seen: Dictionary = {}
		for candidate: Vector2 in candidates:
			if candidates_checked >= target_limit:
				break
			if candidates_checked >= MAX_CANDIDATES or pairs_checked >= MAX_PAIRS:
				return {}
			if skipped.has(candidate) or seen.has(candidate):
				continue
			seen[candidate] = true
			candidates_checked += 1
			if await pose_safe(candidate, rotation, nearby):
				return {"position": candidate, "rotation": rotation}
			await _yield_if_needed()
	return {}

## 各轮拥有独立预算，分帧扩大范围；不会把一次预算耗尽误判为整个关卡无落点。
func find_expanded(targets: Array, skipped: Array = []) -> Dictionary:
	candidates_checked = 0
	pairs_checked = 0
	for radius in SEARCH_RADII:
		var batch = get_script().new()
		batch.setup(owner, world, player_body, hand)
		var result: Dictionary = await batch.find(targets, skipped, radius)
		candidates_checked += batch.candidates_checked
		pairs_checked += batch.pairs_checked
		frames_yielded += batch.frames_yielded
		if not result.is_empty():
			return result
	return {}

func verify(position: Vector2, rotation: float) -> bool:
	# 复查独享预算，不继承搜索已经消耗掉的比较额度。
	_pair_limit = pairs_checked + MAX_PAIRS
	var boxes := _pose_boxes(position, rotation, true)
	if boxes.is_empty():
		return false
	var bounds := _bounds(boxes[0])
	for box in boxes:
		bounds = bounds.merge(_bounds(box))
	return await pose_safe(position, rotation, await _nearby(bounds.grow(100.0)), true)
