extends Node
## 物理引擎边界：只负责配置、推进、查询接触和应用通用物理效果。
## 本脚本不知道墨水、颜色、伤害规则或任何具体玩法类型。

#region 依赖
const PBody = preload("res://addons/pixel_destruction/physics/pbody.gd")
const DebrisDust = preload("res://map/src/debris_dust.gd")
const Query = preload("res://addons/pixel_destruction/physics/query.gd")
const ANCHOR_TAG: String = "static_anchor_points"
#endregion

#region 配置
## 活动范围相对当前可见画面的宽高倍率；4 表示宽高各四倍，完全在外的刚体冻结。
@export_range(1.0, 32.0, 0.5) var freeze_view_scale: float = 4.0

## 游戏侧子步时间预算（微秒），0 表示不限制。
## 它在引擎计算后再次压低子步数；矩形较多时可能把固定 3 子步降到 1，
## 从而改变约束刚度和碰撞结果。公式使用 PWorld.CCD_RECT_COST_US。
@export var ccd_substep_budget_us: float = 6000.0

## 全局表面速度上限（px/s），0 表示关闭。
## _clamp_speeds 会直接修改所有动态体的线速度和角速度，因此不保持动量与能量；
## 角速度上限为 max_surface_speed / bounding_radius。
@export var max_surface_speed: float = 1000.0

## Rapier 逐体 CCD 的软预测距离（px），0 表示无提前量。
@export var ccd_soft_prediction: float = 0.5

## 外接盒短边小于该值的碎片降级为纯视觉灰尘，0 表示关闭。
@export var debris_max_thickness: float = 4.0
## 外接盒短边不大于该值的默认层碎片改为 layer=2/mask=1，0 表示关闭。
## 它们仍会碰 layer 1 中的静态或动态刚体，但不碰同层碎片和玩家。
@export var debris_isolate_thickness: float = 10.0
## 像素数低于该值的碎片也降级为纯视觉灰尘，0 表示关闭。
@export var debris_max_pixels: int = 40

## 碰撞层：默认刚体=1，隔离碎片=2，玩家及手=4。
const DEBRIS_LAYER := 2
const WORLD_LAYER := 1
const PLAYER_LAYER := 4
## 只改仍使用默认过滤器的碎片，保留调用方显式设置的层和掩码。
const DEFAULT_LAYER := 1
const DEFAULT_MASK := 0xFFFFFFFF

#endregion

#region 状态
var _main = null
var _player = null
var _protected: Array = []
var _camera: Camera2D = null
var _dust = null
var _pending_dust: Array = []
var profile_enabled: bool = false
var _profile: Dictionary = {}
## 上一次固定步发生速度钳制的次数。
var last_speed_clamped: int = 0
## 上一次固定步被预算压掉的子步数。
var last_substeps_capped: int = 0
#endregion

#region 生命周期
## 注入关卡依赖并配置底层物理世界；调用方负责保证只调用一次。
func setup(main, player, protected_bodies: Array, camera: Camera2D) -> void:
	_main = main
	_player = player
	_protected = protected_bodies
	_camera = camera
	_main.set_physics_process(false)
	var world = _main.world
	world.contact_events_enabled = false
	world.ccd_enabled = true
	world.rp_ccd_substeps = 1
	world.rp_soft_ccd_prediction = ccd_soft_prediction
	_push_knob(world, "ccd_per_body_only", true)
	_push_knob(world, "ccd_fixed_substeps", 3)
	_push_knob(world, "ccd_per_body", true)
	_push_knob(world, "ccd_auto", true)
	_push_knob(world, "ccd_max_substeps", 4)
	_push_knob(world, "ccd_min_driver_thickness", 3.0)
	_push_knob(world, "max_surface_speed", max_surface_speed)
	if _player != null and _player.body != null:
		_player.body.collision_layer = PLAYER_LAYER
	for body in _protected:
		if body != null and body.collision_layer != 0:
			body.collision_layer = PLAYER_LAYER
	_push_knob(world, "min_fragment_thickness", debris_max_thickness)
	_push_knob(world, "min_fragment_pixels_downgrade", debris_max_pixels)
	_dust = DebrisDust.new()
	_dust.name = "DebrisDust"
	add_child(_dust)
	_dust.setup(_main)

## 解除形状与刚体的引用环，避免场景退出后保留物理资源。
func _exit_tree() -> void:
	if _main == null or _main.world == null:
		return
	for body in _main.world.bodies.duplicate():
		for shape in body.shapes:
			shape.owner_body = null
		_main.world.remove_body(body)
		body.shapes.clear()
	_main.world._rp = null

## 设置可选引擎参数；当前引擎快照不支持时只报警，不中止游戏。
func _push_knob(world, name: String, value) -> bool:
	if not (name in world):
		push_warning("[CCD] 引擎没有 %s —— 这一道闸门失效（需要本仓库的引擎快照）" % name)
		return false
	world.set(name, value)
	return true
#endregion

#region 固定步
## 完成一个固定步的冻结、质心刷新、碎片清理和子步预算，返回实际子步数。
func prepare_fixed(delta: float) -> int:
	var physics = _main.world
	var size: Vector2 = _camera.get_viewport_rect().size / _camera.zoom * freeze_view_scale
	physics.cull_freeze(Rect2(_camera.get_screen_center_position() - size * 0.5, size), [_player.body])
	for body in physics.bodies:
		body.refresh_com()
	var culled: int = physics.cull_fast_debris()
	physics.last_debris_removed = culled
	if culled > 0:
		_drop_culled_nodes()
	last_speed_clamped = _clamp_speeds(physics)
	var requested: int = physics._compute_substeps(delta)
	var count: int = _apply_substep_budget(physics, requested)
	last_substeps_capped = requested - count
	physics.last_substeps = count
	if profile_enabled:
		_profile.fixed_steps = _profile.get("fixed_steps", 0) + 1
		_profile.substeps = _profile.get("substeps", 0) + count
	return count

## 推进一个 Rapier 子步并返回与该子步位姿严格对应的接触数组。
func advance_substep(delta: float) -> Array:
	var physics = _main.world
	physics.contacts.clear()
	var start: int = Time.get_ticks_usec() if profile_enabled else 0
	physics._substep_rapier(delta)
	if profile_enabled:
		_profile.native_us = _profile.get("native_us", 0) + Time.get_ticks_usec() - start
	return contacts(physics)

## 从底层接触缓存构造稳定的游戏侧接触数组。
func contacts(world) -> Array:
	if not world.contacts.is_empty():
		return world.contacts
	var bodies: Dictionary = {}
	for body in world.bodies:
		bodies[body.rapier_id] = body
	var contacts: Array = []
	for i in world.contact_pair_count():
		var info: Dictionary = world.contact_info(i)
		var a = bodies.get(info.id_a)
		var b = bodies.get(info.id_b)
		if a == null or b == null or info.points.is_empty():
			continue
		var point: Dictionary = info.points[0]
		var ra: Vector2 = point.position - a.com_world()
		var rb: Vector2 = point.position - b.com_world()
		var va: Vector2 = Vector2(a.pre_vx, a.pre_vy) + Vector2(-ra.y, ra.x) * a.pre_w
		var vb: Vector2 = Vector2(b.pre_vx, b.pre_vy) + Vector2(-rb.y, rb.x) * b.pre_w
		contacts.append({"a": a, "b": b, "points": info.points,
			"approach": -(vb - va).dot(point.normal)})
	return contacts

## 同步分片后的节点数组，并回收已经失去 PBody 的节点。
func sync_after_commit(previous_nodes: Array) -> void:
	var start: int = Time.get_ticks_usec() if profile_enabled else 0
	_main.sync_world_bodies()
	var live: Dictionary = {}
	for body in _main.world.bodies:
		live[body] = true
	for node in previous_nodes:
		if is_instance_valid(node) and not live.has(node.body):
			node.queue_free()
	if profile_enabled:
		_profile.sync_us = _profile.get("sync_us", 0) + Time.get_ticks_usec() - start

## 把当前物理刚体状态同步到像素渲染器。
func sync_render() -> void:
	if not _main.auto_render or _main.renderer == null:
		return
	var start: int = Time.get_ticks_usec() if profile_enabled else 0
	_main.renderer.prune(_main._live_ids())
	_main.realign_body_nodes()
	for i in _main.world.bodies.size():
		var body = _main.world.bodies[i]
		var node = _main._body_nodes[i] if i < _main._body_nodes.size() else null
		if not _main.uses_internal_render(node):
			_main.renderer.forget(body.id)
			continue
		if not body.is_static and not body.frozen:
			_main.renderer.sync(body)
	if profile_enabled:
		_profile.render_sync_us = _profile.get("render_sync_us", 0) + Time.get_ticks_usec() - start

## cull_fast_debris() 直接删除 PBody；这里恢复节点数组对齐并回收失效节点。
## 交互体由引擎排除，渲染同步留给本固定步末尾。
func _drop_culled_nodes() -> void:
	var live: Dictionary = {}
	for body in _main.world.bodies:
		live[body] = true
	var nodes: Array = _main._body_nodes.duplicate()
	_main.realign_body_nodes()
	for node in nodes:
		if not is_instance_valid(node):
			continue
		var body = node.get("body")
		if body != null and not live.has(body):
			node.queue_free()


## 直接限制所有非静态刚体的线速度和表面角速度，返回发生钳制的次数。
## 冻结体也会被修改；该操作不守恒动量或能量。
func _clamp_speeds(physics) -> int:
	if max_surface_speed <= 0.0:
		return 0
	var vmax: float = max_surface_speed
	var clamped: int = 0
	for body in physics.bodies:
		if body.is_static:
			continue
		var v: Vector2 = body.linear_velocity
		if v.length_squared() > vmax * vmax:
			body.linear_velocity = v.normalized() * vmax
			clamped += 1
		var r: float = body.bounding_radius()
		if r > 1e-6:
			var wmax: float = vmax / r
			if absf(body.angular_velocity) > wmax:
				body.angular_velocity = clampf(body.angular_velocity, -wmax, wmax)
				clamped += 1
	return clamped


## 按总矩形数和估算单价限制实际子步数；逐体固定子步模式也会经过此限制。
func _apply_substep_budget(physics, count: int) -> int:
	if ccd_substep_budget_us <= 0.0:
		return count
	var total_rects: int = 0
	for body in physics.bodies:
		total_rects += body.rects.size()
	if total_rects <= 0:
		return count
	var cap: int = maxi(1, int(ccd_substep_budget_us / (float(total_rects) * physics.CCD_RECT_COST_US)))
	return mini(count, cap)
#endregion

#region 通用效果提交
## 每个受损物体提交一次掩码，分片由引擎负责。
func commit(physics, removals: Dictionary, bursts: Dictionary = {},
		defer_dust: bool = false) -> Dictionary:
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var changed: Array = []
	var removed: int = 0
	var fragments: int = 0
	var replacements: Dictionary = {}
	for body in removals:
		var anchor_points: Dictionary = body.tags.get(ANCHOR_TAG, {})
		var result: Dictionary = physics.fracture_pixels(body, removals[body], bursts.get(body, 0.0), true,
			_anchor_map(body, anchor_points))
		removed += result.removed
		fragments += result.fragments.size()
		replacements[body] = result.fragments.duplicate()
		if result.body_alive:
			replacements[body].append(body)
		else:
			for shape in body.shapes:
				shape.owner_body = null
			body.shapes.clear()
		for entry in result.get("downgraded", []):
			var piece = entry.shape.owner_body
			if piece != null:
				replacements[body].append(piece)
				entry["body"] = piece
			_pending_dust.append(entry)
		if profile_enabled:
			if not _profile.has("fragment_parents"):
				_profile.fragment_parents = []
			var ids: Array = []
			for piece in replacements[body]:
				ids.append(piece.id)
			_profile.fragment_parents.append({"parent": body.id, "pieces": ids})
		# 中等薄度的默认层碎片改用隔离碰撞层。
		_isolate_debris(result.fragments)
		# 引擎降级的碎片交给纯视觉灰尘层。
		if result.removed > 0:
			changed.append(body)
			changed.append_array(result.fragments)
			for changed_body in [body] + result.fragments:
				_update_anchors(changed_body, anchor_points)
	if profile_enabled:
		_profile.commit_us = _profile.get("commit_us", 0) + Time.get_ticks_usec() - profile_start
		_profile.commit_calls = _profile.get("commit_calls", 0) + removals.size()
		_profile.removed_pixels = _profile.get("removed_pixels", 0) + removed
		_profile.fragments = _profile.get("fragments", 0) + fragments
	if not defer_dust:
		flush_blast_dust()
	return {"changed": changed, "calls": removals.size(), "replacements": replacements}


## 第二轮只查破坏后的几何并施力，不生成伤害、不搜索旧体对应的最近碎片。
func apply_radial_impulses(blasts: Array) -> void:
	var start: int = Time.get_ticks_usec() if profile_enabled else 0
	var totals: Dictionary = {}
	for blast in blasts:
		var bounds: Rect2 = Rect2(blast.origin - Vector2.ONE * blast.radius,
			Vector2.ONE * blast.radius * 2.0)
		var candidates: Array = Query.aabb_bodies(bounds)
		# 降级灰尘尚未提交渲染，也作为第二轮的实际几何接收冲量。
		for entry in _pending_dust:
			var piece = entry.get("body")
			if piece != null and bounds.intersects(piece.aabb) and not candidates.has(piece):
				candidates.append(piece)
		for i in blast.ray_count:
			var direction: Vector2 = Vector2.from_angle(TAU * float(i) / float(blast.ray_count))
			var ray_start: int = Time.get_ticks_usec() if profile_enabled else 0
			var hit = _raycast_candidates(candidates, blast.origin, direction, blast.radius)
			if profile_enabled:
				_profile.impulse_rays = _profile.get("impulse_rays", 0) + 1
				_profile.impulse_raycast_us = _profile.get("impulse_raycast_us", 0) + Time.get_ticks_usec() - ray_start
			if not hit.hit or hit.body.is_static:
				continue
			var receiver = hit.body
			var impulse: Vector2 = direction * blast.impulse
			if not totals.has(receiver):
				totals[receiver] = {"linear": Vector2.ZERO, "angular": 0.0}
			totals[receiver].linear += impulse
			totals[receiver].angular += (hit.point - receiver.com_world()).cross(impulse)
			if profile_enabled:
				_profile.impulse_ray_hits = _profile.get("impulse_ray_hits", 0) + 1
	var apply_start: int = Time.get_ticks_usec() if profile_enabled else 0
	for body in totals:
		body.apply_impulse(totals[body].linear, body.com_world())
		body.apply_torque_impulse(totals[body].angular)
		if profile_enabled:
			if not _profile.has("blast_impulses"):
				_profile.blast_impulses = []
			_profile.blast_impulses.append({"body_id": body.id,
				"linear": [totals[body].linear.x, totals[body].linear.y],
				"angular": totals[body].angular})
	if profile_enabled:
		_profile.impulse_apply_us = _profile.get("impulse_apply_us", 0) + Time.get_ticks_usec() - apply_start
		_profile.impulse_us = _profile.get("impulse_us", 0) + Time.get_ticks_usec() - start
		_profile.impulse_bodies = _profile.get("impulse_bodies", 0) + totals.size()


## 把等待中的降级碎片转成交给渲染器的视觉灰尘，并释放临时 PBody 引用。
func flush_blast_dust() -> void:
	for entry in _pending_dust:
		var body = entry.get("body")
		entry["velocity"] = body.linear_velocity if body != null else Vector2.ZERO
		entry.shape.owner_body = null
		if body != null:
			body.shapes.clear()
		entry.erase("body")
	if _dust != null:
		_dust.spawn(_pending_dust)
	_pending_dust.clear()


## 将满足尺寸条件且仍使用默认过滤器的碎片改为 layer=2/mask=1。
## 它们不碰同层碎片或玩家，但仍会碰 layer 1 中的静态和动态刚体。
func _isolate_debris(fragments: Array) -> void:
	if debris_isolate_thickness <= 0.0:
		return
	for f in fragments:
		if f == null or f.is_static:
			continue
		# 显式碰撞配置由调用方负责，不能被碎片策略覆盖。
		if f.collision_layer != DEFAULT_LAYER or f.collision_mask != DEFAULT_MASK:
			continue
		if f.visible_short_side() > debris_isolate_thickness:
			continue
		f.collision_layer = DEBRIS_LAYER
		f.collision_mask = WORLD_LAYER


## 把仍落在实体像素上的锚点标签转换成 fracture_pixels 所需的逐形状掩码。
func _anchor_map(body: PBody, points: Dictionary) -> Dictionary:
	var anchors: Dictionary = {}
	for shape in body.shapes:
		for point: Vector2i in points:
			if shape.get_pixel(point.x, point.y) != 0:
				if not anchors.has(shape):
					anchors[shape] = {}
				anchors[shape][point] = true
	return anchors


## 分片后只保留仍落在实体像素上的锚点标签。
func _update_anchors(body: PBody, points: Dictionary) -> void:
	var live: Dictionary = {}
	for shape in body.shapes:
		for point: Vector2i in points:
			if shape.get_pixel(point.x, point.y) != 0:
				live[point] = true
	if live.is_empty():
		body.tags.erase(ANCHOR_TAG)
	else:
		body.tags[ANCHOR_TAG] = live

## 在候选刚体中执行精确像素射线，返回距离最近的命中。
static func _raycast_candidates(candidates: Array, origin: Vector2, direction: Vector2, max_distance: float):
	var best = Query.Hit.new()
	best.distance = max_distance
	for body in candidates:
		var near: float = 0.0
		var far: float = best.distance
		for axis in 2:
			var lo: float = body.aabb.position[axis]
			var hi: float = body.aabb.end[axis]
			if absf(direction[axis]) < 0.000001:
				if origin[axis] < lo or origin[axis] > hi:
					far = -1.0
					break
				continue
			var a: float = (lo - origin[axis]) / direction[axis]
			var b: float = (hi - origin[axis]) / direction[axis]
			near = maxf(near, minf(a, b))
			far = minf(far, maxf(a, b))
		if far < near:
			continue
		var offset: float = maxf(0.0, near - 0.001)
		var hit = Query._ray_vs_body(body, origin + direction * offset, direction,
			minf(far + 0.001, best.distance) - offset, 0.0)
		if hit.hit and hit.distance + offset < best.distance:
			hit.distance += offset
			best = hit
	return best
#endregion

#region Profiling
## 开关底层物理计时并清空旧样本。
func set_profile_enabled(enabled: bool) -> void:
	profile_enabled = enabled
	_profile.clear()

## 取出并清空自上次读取以来的底层物理计时。
func take_profile() -> Dictionary:
	var result: Dictionary = _profile.duplicate()
	_profile.clear()
	return result
#endregion
