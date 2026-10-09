extends Node
## 游戏侧物理总调度：引擎参数、固定步、接触读取与破坏提交都收口在这里。
## 颜色规则是子节点；底层像素物理插件不依赖玩法。

const PBody = preload("res://addons/pixel_destruction/physics/pbody.gd")
const DebrisDust = preload("res://map/src/debris_dust.gd")
const InkPalette := preload("res://Ink/src/ink_palette.gd")
const Query = preload("res://addons/pixel_destruction/physics/query.gd")
const RedInk = preload("res://Ink/src/red_ink.gd")
const ANCHOR_TAG := "static_anchor_points"

var _elapsed: float = 0.0
var _main = null
var _player = null
var _protected: Array = []
@onready var _feet = $"../Player/PlayerInput"
@onready var _forces = get_node_or_null("../debugHUD/ForceDebug")
@onready var _camera: Camera2D = $"../Camera2D"
@onready var _damage = $ImpactDamage
var _ink_rules: Array = []
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

var _dust = null
## 上一次固定步被 _clamp_speeds 收口的次数（诊断用）。
var last_speed_clamped: int = 0
## 上一次固定步被 _apply_substep_budget 压掉的子步数（诊断用，0 = 没压）。
var last_substeps_capped: int = 0
var profile_enabled: bool = false
var _profile: Dictionary = {}
var _reaction_scale: float = 1.0
var _pending_dust: Array = []
var _defer_dust: bool = false

#region 世界步进
func _ready() -> void:
	# 等父世界及 Player 完成初始化，再接管步进，避免同一帧推进两次。
	call_deferred("_start")


## 停止场景时解除形状与刚体的引用环，避免每次编辑器运行都残留物理资源。
func _exit_tree() -> void:
	if _main == null or _main.world == null:
		return
	for body in _main.world.bodies.duplicate():
		for shape in body.shapes:
			shape.owner_body = null
		_main.world.remove_body(body)
		body.shapes.clear()
	_main.world._rp = null


func _start() -> void:
	_main = get_parent()
	_player = _main.get_node("Player")
	_protected = [_player.get_node("Arm").body, _player.get_node("Arm/Hand").body]
	for child in get_children():
		if child.has_method("observe_removals") and child.has_method("resolve"):
			_ink_rules.append(child)
	_main.set_physics_process(false)
	_main.world.contact_events_enabled = false
	# CCD 总闸与 Rapier 子步均开启；逐体模式使用固定 3 个求解子步。
	# 游戏侧预算仍可能在 _step() 中把实际子步数进一步压低。
	var world = _main.world
	world.ccd_enabled = true
	world.rp_ccd_substeps = 1
	world.rp_soft_ccd_prediction = ccd_soft_prediction
	_push_knob(world, "ccd_per_body_only", true)
	_push_knob(world, "ccd_fixed_substeps", 3)
	# 自动逐体 CCD 只影响动态/运动学目标；静态目标由 Rapier 的自动扫掠处理。
	_push_knob(world, "ccd_per_body", true)
	_push_knob(world, "ccd_auto", true)
	# max_substeps 仅供非逐体模式回退；min_driver_thickness 仍参与自动 bullet 判定。
	_push_knob(world, "ccd_max_substeps", 4)
	_push_knob(world, "ccd_min_driver_thickness", 3.0)
	_push_knob(world, "max_surface_speed", max_surface_speed)
	# 玩家及手移到独立层，但保留原 mask；隔离碎片因此不会与它们碰撞。
	if _player != null and _player.body != null:
		_player.body.collision_layer = PLAYER_LAYER
	for pb in _protected:
		# layer 0 表示禁用碰撞，保持调用方设置。
		if pb != null and pb.collision_layer != 0:
			pb.collision_layer = PLAYER_LAYER
	# 降级阈值由引擎 fracture_pixels 应用，结果通过 downgraded 返回。
	_push_knob(world, "min_fragment_thickness", debris_max_thickness)
	_push_knob(world, "min_fragment_pixels_downgrade", debris_max_pixels)
	# renderer 延迟创建；DebrisDust 会在后续帧解析它。
	_dust = DebrisDust.new()
	_dust.name = "DebrisDust"
	add_child(_dust)
	_dust.setup(_main)
	process_physics_priority = _main.process_physics_priority + 1


## 设置可选的引擎参数；部署快照缺少参数时记录警告并继续运行。
func _push_knob(world, name: String, value) -> bool:
	if not (name in world):
		push_warning("[CCD] 引擎没有 %s —— 这一道闸门失效（需要本仓库的引擎快照）" % name)
		return false
	world.set(name, value)
	return true


func _physics_process(delta: float) -> void:
	if _main == null or not _main.auto_step:
		return
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	_elapsed += delta
	var steps: int = 0
	while _elapsed >= _main.fixed_dt and steps < _main.max_substeps:
		var result: Dictionary = _step(_main.fixed_dt)
		_player.apply_collision_damage(result.player_damage)
		_defer_dust = true
		if not result.removals.is_empty():
			var nodes: Array = _main._body_nodes.duplicate()
			commit(_main.world, result.removals, result.get("bursts", {}))
			var sync_start: int = Time.get_ticks_usec() if profile_enabled else 0
			_main.sync_world_bodies()
			if profile_enabled:
				_profile.sync_us = _profile.get("sync_us", 0) + Time.get_ticks_usec() - sync_start
			var live: Dictionary = {}
			for body in _main.world.bodies:
				live[body] = true
			for node in nodes:
				if is_instance_valid(node) and not live.has(node.body):
					node.queue_free()
		apply_blast_impulses(result.get("impulses", []))
		flush_blast_dust()
		_defer_dust = false
		_elapsed -= _main.fixed_dt
		steps += 1
	if _elapsed > _main.fixed_dt * _main.max_substeps:
		_elapsed = 0.0
	if is_instance_valid(_forces):
		_forces.finish(delta)
	if _main.auto_render and _main.renderer != null:
		var render_start: int = Time.get_ticks_usec() if profile_enabled else 0
		# 非内部渲染刚体必须移除旧贴图，避免残留在旧位姿。
		_main.renderer.prune(_main._live_ids())
		# _body_nodes 与 world.bodies 必须按下标对齐；直接增删 PBody 后统一校正。
		_main.realign_body_nodes()
		for i in _main.world.bodies.size():
			var body = _main.world.bodies[i]
			var node = _main._body_nodes[i] if i < _main._body_nodes.size() else null
			if not _main.uses_internal_render(node):
				_main.renderer.forget(body.id)
				continue
			if body.is_static or body.frozen:
				continue
			_main.renderer.sync(body)
		if profile_enabled:
			_profile.render_sync_us = _profile.get("render_sync_us", 0) + Time.get_ticks_usec() - render_start
	if profile_enabled:
		_profile.physics_us = _profile.get("physics_us", 0) + Time.get_ticks_usec() - profile_start
		_profile.physics_calls = _profile.get("physics_calls", 0) + 1


func set_profile_enabled(enabled: bool) -> void:
	profile_enabled = enabled
	_profile.clear()
	for rule in _ink_rules:
		if rule.has_method("set_profile_enabled"):
			rule.set_profile_enabled(enabled)


func take_profile() -> Dictionary:
	var result: Dictionary = _profile.duplicate()
	var rules: Dictionary = {}
	for rule in _ink_rules:
		if rule.has_method("take_profile"):
			rules[rule.name] = rule.take_profile()
	if not rules.is_empty():
		result.rules = rules
	_profile.clear()
	return result


## 接触点必须匹配该子步的位姿；删除并集留到固定步末，避免重复重建。
func _step(delta: float) -> Dictionary:
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var physics = _main.world
	# 用当前可见画面扩大范围，整组关节冻结；玩家连接的物体持续受力。
	var size: Vector2 = _camera.get_viewport_rect().size / _camera.zoom * freeze_view_scale
	physics.cull_freeze(Rect2(_camera.get_screen_center_position() - size * 0.5, size), [_player.body])
	for body in physics.bodies:
		body.refresh_com()
	# 本节点接管世界步进，因此显式执行 PWorld.step() 原本负责的高速轻碎片清理。
	var culled: int = physics.cull_fast_debris()
	physics.last_debris_removed = culled
	if culled > 0:
		_drop_culled_nodes()
	# 先按原始速度清理轻碎片，再执行全局速度钳制。
	last_speed_clamped = _clamp_speeds(physics)
	var count: int = physics._compute_substeps(delta)
	var capped: int = _apply_substep_budget(physics, count)
	last_substeps_capped = count - capped
	count = capped
	physics.last_substeps = count
	if profile_enabled:
		_profile.fixed_steps = _profile.get("fixed_steps", 0) + 1
		_profile.substeps = _profile.get("substeps", 0) + count
	_reaction_scale = 1.0
	var result: Dictionary = {"removals": {}, "player_damage": 0.0, "bursts": {}, "impulses": []}
	for i in count:
		physics.contacts.clear()
		var native_start: int = Time.get_ticks_usec() if profile_enabled else 0
		physics._substep_rapier(delta / count)
		if profile_enabled:
			_profile.native_us = _profile.get("native_us", 0) + Time.get_ticks_usec() - native_start
		var impact: Dictionary = calculate(physics, _player.body, _protected)
		_merge_result(result, impact)
	# 两轮爆炸射线之间只提交破坏，不插入运动，保持发射点与方向一致。
	for rule in _ink_rules:
		var rule_start: int = Time.get_ticks_usec() if profile_enabled else 0
		_merge_result(result, rule.resolve(physics, _damage, _player.body, _protected))
		if profile_enabled:
			_profile.ink_resolve_us = _profile.get("ink_resolve_us", 0) + Time.get_ticks_usec() - rule_start
	if profile_enabled:
		_profile.step_us = _profile.get("step_us", 0) + Time.get_ticks_usec() - profile_start
	return result


func _merge_result(target: Dictionary, source: Dictionary) -> void:
	target.player_damage += source.player_damage
	if not source.get("impulses", []).is_empty():
		target.impulses.append_array(source.impulses)
		_reaction_scale = minf(_reaction_scale, source.get("reaction_scale", 1.0))
	for body in source.get("bursts", {}):
		target.bursts[body] = maxf(target.bursts.get(body, 0.0), source.bursts[body])
	for body in source.removals:
		if not target.removals.has(body):
			target.removals[body] = source.removals[body]
			continue
		for shape in source.removals[body]:
			if not target.removals[body].has(shape):
				target.removals[body][shape] = source.removals[body][shape]
			else:
				target.removals[body][shape].merge(source.removals[body][shape], true)


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

#region 接触边界
## 引擎接触只在总调度中读取；规则脚本只接收普通接触数组。
func calculate(world, player_body: PBody = null, protected_bodies: Array = []) -> Dictionary:
	var contacts_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var contacts: Array = _contacts(world)
	if profile_enabled:
		_profile.contacts_us = _profile.get("contacts_us", 0) + Time.get_ticks_usec() - contacts_start
		_profile.contact_pairs = _profile.get("contact_pairs", 0) + contacts.size()
		for contact in contacts:
			_profile.max_approach = maxf(_profile.get("max_approach", 0.0), contact.approach)
			var impulse: float = 0.0
			for point in contact.points:
				impulse += maxf(point.impulse, 0.0)
			_profile.max_contact_impulse = maxf(_profile.get("max_contact_impulse", 0.0), impulse)
			if contact.approach > _damage.min_approach:
				if not _profile.has("impacts"):
					_profile.impacts = []
				_profile.impacts.append({"a": contact.a.id, "b": contact.b.id,
					"approach": contact.approach, "impact": _damage._impact(contact.points)})
	if is_instance_valid(_forces):
		_forces.sample_contacts(contacts, _main.fixed_dt / world.last_substeps)
	if is_instance_valid(_feet):
		_feet.update_support(contacts)
	var damage_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var result: Dictionary = _damage.calculate(world, contacts, player_body, protected_bodies)
	if profile_enabled:
		_profile.damage_us = _profile.get("damage_us", 0) + Time.get_ticks_usec() - damage_start
	return result

#region 接触面
## 只查询冲量，避免接触事件逐像素计算宽度与应力。
func _contacts(world) -> Array:
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


#endregion

#region 现有破坏接口
## 每个受损物体提交一次掩码，分片由引擎负责。
func commit(physics, removals: Dictionary, bursts: Dictionary = {}) -> Dictionary:
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var changed: Array = []
	var removed: int = 0
	var fragments: int = 0
	var replacements: Dictionary = {}
	for body in removals:
		for rule in _ink_rules:
			rule.observe_removals(body, removals[body], _reaction_scale)
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
	if not _defer_dust:
		flush_blast_dust()
	return {"changed": changed, "calls": removals.size(), "replacements": replacements}


## 第二轮只查破坏后的几何并施力，不生成伤害、不搜索旧体对应的最近碎片。
func apply_blast_impulses(blasts: Array) -> void:
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
			var hit = RedInk.raycast_candidates(candidates, blast.origin, direction, blast.radius)
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


func _anchor_map(body: PBody, points: Dictionary) -> Dictionary:
	var anchors: Dictionary = {}
	for shape in body.shapes:
		for point: Vector2i in points:
			if shape.get_pixel(point.x, point.y) == InkPalette.nail_material_id():
				if not anchors.has(shape):
					anchors[shape] = {}
				anchors[shape][point] = true
	return anchors


func _update_anchors(body: PBody, points: Dictionary) -> void:
	var live: Dictionary = {}
	for shape in body.shapes:
		for point: Vector2i in points:
			if shape.get_pixel(point.x, point.y) == InkPalette.nail_material_id():
				live[point] = true
	if live.is_empty():
		body.tags.erase(ANCHOR_TAG)
	else:
		body.tags[ANCHOR_TAG] = live
#endregion
