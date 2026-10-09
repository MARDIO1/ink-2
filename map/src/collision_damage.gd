#region 依赖与规则
extends Node
## 世界级碰撞结算。每个固定步先算双方，再统一删像素、分片和重建。
## 不保存像素余量；碎片只需 PBody，不需要额外挂载脚本。

const PBody = preload("res://addons/pixel_destruction/physics/pbody.gd")
const DebrisDust = preload("res://map/src/debris_dust.gd")
## 材质定义统一从 InkPalette 读取。
const InkPalette := preload("res://Ink/src/ink_palette.gd")
const ANCHOR_TAG := "static_anchor_points"

## 以抓住 32×32 物块抬起再下砸校准：普通落下不删像素，完整下砸约一层。
## 碰撞冲量转为破坏预算的倍率；越大越容易删像素。
@export var damage_scale: float = 0.012
## 触发损坏的最小接近速度，单位 px/s；低于该值不结算，避免静态压力损坏。
@export var min_approach: float = 300.0
## 厚度支撑累加上限，以表面材料强度归一化；超过后不再增加减伤。
@export var support_max: float = 64.0
## 厚度对数减伤系数；越大，同样厚度下的损坏越小。
@export var thickness_scale: float = 0.5
## 厚度修正的最低倍率；即使支撑很厚也保留该比例的破坏预算。
@export_range(0.0, 1.0, 0.01) var min_thickness_factor: float = 0.2
## 强度 0 表示不删像素；作为攻击方及玩家伤害的参考抗性仍需有限值。
@export var reference_strength: float = 100.0
## 单次撞击最多生成的主裂纹数；实际数量仍由可破坏像素预算决定。
@export_range(1, 4, 1) var crack_max_count: int = 4
## 每增加一条主裂纹需要的等效可破坏像素数；越大越难出现多条裂纹。
@export_range(1.0, 32.0, 0.5) var crack_pixels_per_branch: float = 6.0
## 主裂纹围绕受力进入方向的最大展开角；实际角度带确定性扰动，不形成整齐扇形。
@export_range(0.0, 80.0, 1.0) var crack_spread_degrees: float = 35.0
## 每段裂纹的最大随机转角；越大越接近闪电或树根，越小越接近玻璃直裂纹。
@export_range(0.0, 30.0, 1.0) var crack_turn_degrees: float = 10.0
## 裂纹前进多少像素后重新取一次转角；越小折线越密。
@export_range(1, 16, 1) var crack_turn_pixels: int = 4
var _elapsed: float = 0.0
var _main = null
var _player = null
var _protected: Array = []
@onready var _feet = $"../Player/PlayerInput"
@onready var _forces = get_node_or_null("../debugHUD/ForceDebug")
@onready var _camera: Camera2D = $"../Camera2D"
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
var profile_enabled: bool = false
var _profile: Dictionary = {}
#endregion


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
func _push_knob(world, name: String, value) -> void:
	if not (name in world):
		push_warning("[CCD] 引擎没有 %s —— 这一道闸门失效（需要本仓库的引擎快照）" % name)
		return
	world.set(name, value)


func _physics_process(delta: float) -> void:
	if _main == null or not _main.auto_step:
		return
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	_elapsed += delta
	var steps: int = 0
	while _elapsed >= _main.fixed_dt and steps < _main.max_substeps:
		var result: Dictionary = _step(_main.fixed_dt)
		_player.apply_collision_damage(result.player_damage)
		if not result.removals.is_empty():
			var nodes: Array = _main._body_nodes.duplicate()
			commit(_main.world, result.removals)
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


func take_profile() -> Dictionary:
	var result: Dictionary = _profile.duplicate()
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
	_clamp_speeds(physics)
	var count: int = physics._compute_substeps(delta)
	count = _apply_substep_budget(physics, count)
	physics.last_substeps = count
	if profile_enabled:
		_profile.fixed_steps = _profile.get("fixed_steps", 0) + 1
		_profile.substeps = _profile.get("substeps", 0) + count
	var result: Dictionary = {"removals": {}, "player_damage": 0.0}
	for i in count:
		physics.contacts.clear()
		var native_start: int = Time.get_ticks_usec() if profile_enabled else 0
		physics._substep_rapier(delta / count)
		if profile_enabled:
			_profile.native_us = _profile.get("native_us", 0) + Time.get_ticks_usec() - native_start
		var impact: Dictionary = calculate(physics, _player.body, _protected)
		result.player_damage += impact.player_damage
		for body in impact.removals:
			if not result.removals.has(body):
				result.removals[body] = impact.removals[body]
				continue
			for shape in impact.removals[body]:
				if not result.removals[body].has(shape):
					result.removals[body][shape] = impact.removals[body][shape]
				else:
					result.removals[body][shape].merge(impact.removals[body][shape], true)
	if profile_enabled:
		_profile.step_us = _profile.get("step_us", 0) + Time.get_ticks_usec() - profile_start
	return result


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


#region 碰撞结算
## 返回 {removals: {PBody: {PixelShape: {Vector2i: true}}}, player_damage: float}。
## 重叠删除取并集；每条 lane 独立消费预算，未满一个像素的余量舍弃。
func calculate(world, player_body: PBody = null, protected_bodies: Array = []) -> Dictionary:
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var result: Dictionary = {"removals": {}, "player_damage": 0.0}
	var contacts_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var contacts: Array = _contacts(world)
	if profile_enabled:
		_profile.contacts_us = _profile.get("contacts_us", 0) + Time.get_ticks_usec() - contacts_start
		_profile.contact_pairs = _profile.get("contact_pairs", 0) + contacts.size()
	if is_instance_valid(_forces):
		_forces.sample_contacts(contacts, _main.fixed_dt / world.last_substeps)
	if is_instance_valid(_feet):
		_feet.update_support(contacts)
	# 轻碎片豁免：一个子步只建一次集合，别在每对接触上重建（见 _dust_bodies）。
	var dust: Dictionary = _dust_bodies(world, player_body, protected_bodies)
	for contact in contacts:
		if contact.approach <= min_approach:
			continue
		# 两头都是灰尘：两侧都被豁免，连冲量合成都不必算。
		if dust.has(contact.a) and dust.has(contact.b):
			continue
		var impact: Dictionary = _impact(contact.points)
		if impact.is_empty():
			continue
		var point: Vector2 = impact.position
		var normal: Vector2 = impact.normal
		var a_origin: Vector2 = point - normal * 0.001
		var b_origin: Vector2 = point + normal * (maxf(impact.dist, 0.0) + 0.001)
		var a_material: int = _material_at(contact.a, a_origin)
		var b_material: int = _material_at(contact.b, b_origin)
		if a_material == 0 or b_material == 0:
			continue
		for side in [[contact.a, a_origin, -normal, a_material, b_material, -1.0],
				[contact.b, b_origin, normal, b_material, a_material, 1.0]]:
			var body: PBody = side[0]
			if protected_bodies.has(body) or dust.has(body):
				continue
			var strength: float = world.material_strength(side[3]).x
			if strength <= 0.0 and body != player_body:
				continue
			strength = strength if strength > 0.0 else reference_strength
			var attacker: float = world.material_strength(side[4]).x
			attacker = attacker if attacker > 0.0 else reference_strength
			var budget: float = damage_scale * impact.impulse * attacker / strength
			if body != player_body and budget < strength:
				continue  # 连第一层都删不掉，不必扫描厚度。
			var path: Array = _trace(body, side[1], side[2], world, 0.0 if body == player_body else budget, body == player_body)
			var seed: int = hash(Vector3i(roundi(point.x * 16.0), roundi(point.y * 16.0), roundi(impact.impulse)))
			_damage_side(world, body, path, side[4], impact.impulse, player_body,
				protected_bodies, result, side[1], side[2], seed, side[5])
	if profile_enabled:
		_profile.damage_us = _profile.get("damage_us", 0) + Time.get_ticks_usec() - profile_start
	return result


## 轻碎片豁免：阈值直接用世界的 ccd_ignore_mass（0 = 关，引擎默认），与引擎
## _exempt_bodies()（pworld.gd:1488）是同一个「灰尘」定义 —— 引擎既然不为「质量 <= 它」
## 的刚体做防穿（一个 2x2 碎片就能逼全世界跑 334 子步，pworld.gd:93-103），也就不必为
## 它们跑 _trace()/_damage_side() 那趟逐层厚度扫描；calculate() 是每个子步跑一次的
## （_step 的子步循环里），碎块一多这趟扫描就是纯开销。
## 豁免只针对「被撞的一方」；玩家、手臂/手、抓着的、挂关节的一律不在集合里
## （与引擎 _exempt_bodies() 末尾 erase(_interactive_bodies()) 同义）。
func _dust_bodies(world, player_body: PBody, protected_bodies: Array) -> Dictionary:
	var out: Dictionary = {}
	var limit: float = world.ccd_ignore_mass
	if limit <= 0.0:
		return out
	var interactive: Dictionary = world._interactive_bodies()
	for body: PBody in world.bodies:
		if body == player_body or protected_bodies.has(body):
			continue
		if body.is_static or body.frozen:
			continue
		if body.mass <= limit and not interactive.has(body):
			out[body] = true
	return out


func _damage_side(world, body: PBody, path: Array, attacker_material: int,
		impulse: float, player_body: PBody, protected_bodies: Array, result: Dictionary,
		origin: Vector2 = Vector2.INF, direction: Vector2 = Vector2.ZERO, seed: int = 0,
		mirror: float = 1.0) -> void:
	if protected_bodies.has(body) or path.is_empty():
		return
	var surface_strength: float = world.material_strength(path[0].material).x
	if surface_strength <= 0.0:
		if body != player_body:
			return
		surface_strength = reference_strength
	var attacker_strength: float = world.material_strength(attacker_material).x
	if attacker_strength <= 0.0:
		attacker_strength = reference_strength
	var support: float = 0.0
	for pixel in path:
		var strength: float = world.material_strength(pixel.material).x
		if body == player_body and strength <= 0.0:
			strength = reference_strength
		# 不可破坏的内层提供最大支撑，且逐层消耗时会阻挡贯穿。
		support = minf(support_max, support + (strength / surface_strength if strength > 0.0 else support_max))
		if support >= support_max:
			break
	var factor: float = min_thickness_factor + (1.0 - min_thickness_factor) / (1.0 + thickness_scale * log(1.0 + support))
	var budget: float = damage_scale * impulse * attacker_strength / surface_strength * factor
	if body == player_body:
		result.player_damage += budget
		return
	if not origin.is_finite() or direction.is_zero_approx():
		_consume_path(world, body, path, budget, result)
		return
	var count: int = _crack_count(budget / surface_strength)
	var branch_budget: float = budget / float(count)
	for i in count:
		var spread: float = 0.0 if count == 1 else remap(float(i), 0.0, float(count - 1), -1.0, 1.0)
		var jitter: float = (_noise(seed, i) * 2.0 - 1.0) * crack_turn_degrees
		var angle: float = deg_to_rad((spread * crack_spread_degrees + jitter) * mirror)
		var crack: Array = _crack_path(body, origin, direction.rotated(angle), world,
			branch_budget, seed + i * 97, mirror)
		_consume_path(world, body, crack, branch_budget, result)


func _crack_count(pixel_budget: float) -> int:
	return clampi(1 + floori(maxf(0.0, pixel_budget - 1.0) / crack_pixels_per_branch), 1, crack_max_count)


func _consume_path(world, body: PBody, path: Array, budget: float, result: Dictionary) -> void:
	for pixel in path:
		var cost: float = world.material_strength(pixel.material).x
		if cost <= 0.0 or budget < cost:
			break
		budget -= cost
		if not result.removals.has(body):
			result.removals[body] = {}
		if not result.removals[body].has(pixel.shape):
			result.removals[body][pixel.shape] = {}
		result.removals[body][pixel.shape][pixel.position] = true
#endregion


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


## 同一碰撞对只形成一次撞击；多接触点按各自冲量合成，避免 N 个点产生 N 份伤害。
func _impact(points: Array) -> Dictionary:
	var total: float = 0.0
	var position: Vector2 = Vector2.ZERO
	var normal: Vector2 = Vector2.ZERO
	var dist: float = 0.0
	for point in points:
		if point.impulse <= 0.0:
			continue
		total += point.impulse
		position += point.position * point.impulse
		normal += point.normal * point.impulse
		dist += point.dist * point.impulse
	if total <= 0.0 or normal.is_zero_approx():
		return {}
	normal = normal.normalized()
	var tangent: Vector2 = Vector2(-normal.y, normal.x)
	var first: float = INF
	var last: float = -INF
	for point in points:
		if point.impulse > 0.0:
			first = minf(first, point.position.dot(tangent))
			last = maxf(last, point.position.dot(tangent))
	var width: int = maxi(1, ceili(last - first))
	return {"position": position / total, "normal": normal, "dist": dist / total,
		"impulse": total / float(width), "total_impulse": total}
#endregion


#region 像素路径
func _material_at(body: PBody, point: Vector2) -> int:
	var cell: Vector2i = Vector2i(body.to_local(point).floor())
	for shape in body.shapes:
		var material: int = shape.get_pixel(cell.x, cell.y)
		if material != 0:
			return material
	return 0


## 局部网格 DDA：每个进入的像素只访问一次；第一处空洞停止，跨材料继续。
## 支撑已饱和且累计像素成本覆盖未经减伤的预算时，后续深度不再影响结果。
func _trace(body: PBody, origin: Vector2, direction: Vector2, world = null,
		budget: float = INF, player: bool = false) -> Array:
	var point: Vector2 = body.to_local(origin)
	var ray: Vector2 = direction.rotated(-body.rotation)
	var cell: Vector2i = Vector2i(floori(point.x), floori(point.y))
	var step: Vector2i = Vector2i(int(signf(ray.x)), int(signf(ray.y)))
	var delta: Vector2 = Vector2(INF if ray.x == 0.0 else absf(1.0 / ray.x), INF if ray.y == 0.0 else absf(1.0 / ray.y))
	var edge: Vector2 = Vector2(cell) + Vector2(1.0 if ray.x > 0.0 else 0.0, 1.0 if ray.y > 0.0 else 0.0)
	var next: Vector2 = Vector2(INF if ray.x == 0.0 else (edge.x - point.x) / ray.x, INF if ray.y == 0.0 else (edge.y - point.y) / ray.y)
	var path: Array = []
	var support: float = 0.0
	var cost: float = 0.0
	var surface: float = 0.0
	while true:
		var hit = null
		for shape in body.shapes:
			var material: int = shape.get_pixel(cell.x, cell.y)
			if material != 0:
				hit = {"shape": shape, "position": cell, "material": material}
				break
		if hit == null:
			return path
		path.append(hit)
		if world != null:
			var strength: float = world.material_strength(hit.material).x
			if player and strength <= 0.0:
				strength = reference_strength
			if surface == 0.0:
				surface = strength
			support += strength / surface if strength > 0.0 else support_max
			cost += strength if strength > 0.0 else INF
			if support >= support_max and cost >= budget:
				return path
		# 正好经过格点时同时跨两轴，不把仅触碰角点的邻格算作实体层。
		if is_equal_approx(next.x, next.y):
			cell += step
			next += delta
		elif next.x < next.y:
			cell.x += step.x
			next.x += delta.x
		else:
			cell.y += step.y
			next.y += delta.y
	return path


## 半像素步进保证不跨格；每段只改变方向，不增加破坏预算。
func _crack_path(body: PBody, origin: Vector2, direction: Vector2, world,
		budget: float, seed: int, mirror: float = 1.0) -> Array:
	var point: Vector2 = body.to_local(origin)
	var base: Vector2 = direction.rotated(-body.rotation).normalized()
	var ray: Vector2 = base
	var last: Vector2i = Vector2i(1 << 30, 1 << 30)
	var path: Array = []
	var cost: float = 0.0
	var turn: int = 0
	while true:
		var cell: Vector2i = Vector2i(point.floor())
		if cell != last:
			last = cell
			var hit = null
			for shape in body.shapes:
				var material: int = shape.get_pixel(cell.x, cell.y)
				if material != 0:
					hit = {"shape": shape, "position": cell, "material": material}
					break
			if hit == null:
				return path
			path.append(hit)
			var strength: float = world.material_strength(hit.material).x
			if strength <= 0.0:
				return path
			cost += strength
			if cost >= budget:
				return path
			if path.size() % crack_turn_pixels == 0:
				var angle: float = (_noise(seed, turn + 31) * 2.0 - 1.0) * crack_turn_degrees * mirror
				ray = base.rotated(deg_to_rad(angle))
				turn += 1
		point += ray * 0.5
	return path


func _noise(seed: int, index: int) -> float:
	var value: int = absi(seed % 2147483647)
	value = (value + (index + 1) * 48271) % 2147483647
	value = (value * 1103515245 + 12345) % 2147483647
	return float(value) / 2147483647.0


#endregion


#region 现有破坏接口
## 每个受损物体提交一次掩码，分片由引擎负责。
func commit(physics, removals: Dictionary) -> Dictionary:
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var removed: int = 0
	var fragments: int = 0
	for body in removals:
		var anchor_points: Dictionary = body.tags.get(ANCHOR_TAG, {})
		var result: Dictionary = physics.fracture_pixels(body, removals[body], 0.0, true,
			_anchor_map(body, anchor_points))
		removed += result.removed
		fragments += result.fragments.size()
		# 中等薄度的默认层碎片改用隔离碰撞层。
		_isolate_debris(result.fragments)
		# 引擎降级的碎片交给纯视觉灰尘层。
		if _dust != null:
			_dust.spawn(result.get("downgraded", []))
		if result.removed > 0:
			for changed_body in [body] + result.fragments:
				_update_anchors(changed_body, anchor_points)
	if profile_enabled:
		_profile.commit_us = _profile.get("commit_us", 0) + Time.get_ticks_usec() - profile_start
		_profile.commit_calls = _profile.get("commit_calls", 0) + removals.size()
		_profile.removed_pixels = _profile.get("removed_pixels", 0) + removed
		_profile.fragments = _profile.get("fragments", 0) + fragments
	return {"calls": removals.size()}


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
