extends Node
## 游戏模拟协调层：把物理帧交给规则接口，再把规则产生的通用效果交回 PhysicsStep。
## 本脚本只依赖能力接口，不判断红、黄、蓝等具体颜色。

#region 状态与依赖
@onready var _physics = $PhysicsStep
@onready var _feet = $"../Player/PlayerInput"
@onready var _forces = get_node_or_null("../debugHUD/ForceDebug")
@onready var _camera: Camera2D = $"../Camera2D"

var _elapsed: float = 0.0
var _main = null
var _player = null
var _protected: Array = []
var _extensions: Array = []
var _contact_rules: Array = []
var _fixed_rules: Array = []
var _services: Dictionary = {}
var _reaction_scale: float = 1.0
var profile_enabled: bool = false
var _profile: Dictionary = {}
#endregion


#region 生命周期
## 等待关卡和玩家完成初始化，再接管固定步，避免世界在同一帧被推进两次。
func _ready() -> void:
	call_deferred("_start")


## 收集规则接口、注册服务并初始化纯物理边界。
func _start() -> void:
	_main = get_parent()
	_player = _main.get_node("Player")
	_protected = [_player.get_node("Arm").body, _player.get_node("Arm/Hand").body]
	_discover_extensions()
	_physics.setup(_main, _player, _protected, _camera)
	process_physics_priority = _main.process_physics_priority + 1


## 按能力而非脚本类型发现规则；新增颜色只需实现相应接口并挂为子节点。
func _discover_extensions() -> void:
	_extensions.clear()
	_contact_rules.clear()
	_fixed_rules.clear()
	_services.clear()
	for child in get_children():
		if child == _physics:
			continue
		_extensions.append(child)
		if child.has_method("observe_fracture") and not _physics.body_fractured.is_connected(child.observe_fracture):
			_physics.body_fractured.connect(child.observe_fracture)
		if child.has_method("service_name"):
			var name: StringName = child.service_name()
			if not name.is_empty():
				_services[name] = child
		if child.has_method("resolve_contacts"):
			_contact_rules.append(child)
		if child.has_method("resolve_fixed"):
			_fixed_rules.append(child)
#endregion


#region 帧调度
## 累积渲染帧时间，按关卡固定步推进模拟并统一同步渲染。
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
			commit(_main.world, result.removals, result.get("bursts", {}), true)
			_physics.sync_after_commit(nodes)
		_physics.apply_radial_impulses(result.get("impulses", []))
		_physics.flush_blast_dust()
		_elapsed -= _main.fixed_dt
		steps += 1
	if _elapsed > _main.fixed_dt * _main.max_substeps:
		_elapsed = 0.0
	if is_instance_valid(_forces):
		_forces.finish(delta)
	_physics.sync_render()
	if profile_enabled:
		_profile.physics_us = _profile.get("physics_us", 0) + Time.get_ticks_usec() - profile_start
		_profile.physics_calls = _profile.get("physics_calls", 0) + 1


## 推进一个完整固定步：先处理各物理子步的接触规则，再处理跨 tick 的固定步规则。
func _step(delta: float) -> Dictionary:
	var start: int = Time.get_ticks_usec() if profile_enabled else 0
	var count: int = _physics.prepare_fixed(delta)
	_reaction_scale = 1.0
	var result: Dictionary = _empty_result()
	for i in count:
		_physics.advance_substep(delta / count)
		_merge_result(result, calculate(_main.world, _player.body, _protected))
	for rule in _fixed_rules:
		var rule_start: int = Time.get_ticks_usec() if profile_enabled else 0
		_merge_result(result, rule.resolve_fixed(_context()))
		if profile_enabled:
			_profile.rule_resolve_us = _profile.get("rule_resolve_us", 0) + Time.get_ticks_usec() - rule_start
	if profile_enabled:
		_profile.step_us = _profile.get("step_us", 0) + Time.get_ticks_usec() - start
	return result


## 生成规则共享的只读上下文；服务表用于规则间依赖接口，不暴露具体脚本类型。
func _context() -> Dictionary:
	return {"world": _main.world, "player_body": _player.body,
		"protected_bodies": _protected, "services": _services}


## 创建统一效果包，所有规则都通过这些通用字段向物理层提交结果。
func _empty_result() -> Dictionary:
	return {"removals": {}, "player_damage": 0.0, "bursts": {}, "impulses": []}


## 合并多个规则的伤害、删除、分片和冲量效果，并保留最低连锁反应倍率。
func _merge_result(target: Dictionary, source: Dictionary) -> void:
	target.player_damage += source.get("player_damage", 0.0)
	if not source.get("impulses", []).is_empty():
		target.impulses.append_array(source.impulses)
		_reaction_scale = minf(_reaction_scale, source.get("reaction_scale", 1.0))
	for body in source.get("bursts", {}):
		target.bursts[body] = maxf(target.bursts.get(body, 0.0), source.bursts[body])
	for body in source.get("removals", {}):
		if not target.removals.has(body):
			target.removals[body] = source.removals[body]
			continue
		for shape in source.removals[body]:
			if not target.removals[body].has(shape):
				target.removals[body][shape] = source.removals[body][shape]
			else:
				target.removals[body][shape].merge(source.removals[body][shape], true)
#endregion


#region 规则接口
## 读取当前子步接触、更新支撑和调试力，再依次调用所有接触规则。
func calculate(world, player_body = null, protected_bodies: Array = []) -> Dictionary:
	var contacts: Array = _contacts(world)
	return _resolve_contacts(world, contacts, player_body, protected_bodies)


## 对一组已经读取的接触执行规则，避免多个规则重复查询底层引擎。
func _resolve_contacts(world, contacts: Array, player_body = null,
		protected_bodies: Array = []) -> Dictionary:
	var start: int = Time.get_ticks_usec() if profile_enabled else 0
	if player_body == null:
		player_body = _player.body
	if protected_bodies.is_empty():
		protected_bodies = _protected
	if is_instance_valid(_forces):
		_forces.sample_contacts(contacts, _main.fixed_dt / world.last_substeps)
	if is_instance_valid(_feet):
		_feet.update_support(contacts)
	var context: Dictionary = {"world": world, "player_body": player_body,
		"protected_bodies": protected_bodies, "services": _services}
	var result: Dictionary = _empty_result()
	for rule in _contact_rules:
		_merge_result(result, rule.resolve_contacts(context, contacts))
	if profile_enabled:
		_profile.contacts_us = _profile.get("contacts_us", 0) + Time.get_ticks_usec() - start
		_profile.contact_pairs = _profile.get("contact_pairs", 0) + contacts.size()
	return result


## 提交删除前通知所有观察规则，再由 PhysicsStep 一次性分片。
func commit(world, removals: Dictionary, bursts: Dictionary = {},
		defer_dust: bool = false) -> Dictionary:
	for body in removals:
		for extension in _extensions:
			if extension.has_method("observe_removals"):
				extension.observe_removals(_context(), body, removals[body], _reaction_scale)
	return _physics.commit(world, removals, bursts, defer_dust)


## 提供给测试与诊断工具的接触读取入口，仍由 PhysicsStep 完成引擎查询。
func _contacts(world) -> Array:
	return _physics.contacts(world)


## 把通用径向冲量事件交给物理边界应用。
func apply_radial_impulses(events: Array) -> void:
	_physics.apply_radial_impulses(events)


## 将本轮降级碎片交给视觉灰尘层。
func flush_blast_dust() -> void:
	_physics.flush_blast_dust()
#endregion


#region Profiling
## 同时开关协调层、物理层和各玩法扩展的计时。
func set_profile_enabled(enabled: bool) -> void:
	profile_enabled = enabled
	_profile.clear()
	_physics.set_profile_enabled(enabled)
	for extension in _extensions:
		if extension.has_method("set_profile_enabled"):
			extension.set_profile_enabled(enabled)


## 汇总协调层、物理层和各玩法扩展的计时并清空旧样本。
func take_profile() -> Dictionary:
	var result: Dictionary = _profile.duplicate()
	result.physics_step = _physics.take_profile()
	var extensions: Dictionary = {}
	for extension in _extensions:
		if extension.has_method("take_profile"):
			extensions[extension.name] = extension.take_profile()
	if not extensions.is_empty():
		result.extensions = extensions
	_profile.clear()
	return result
#endregion
