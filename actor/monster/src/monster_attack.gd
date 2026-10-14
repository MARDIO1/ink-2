extends RefCounted
## 攻击阶段只提供关节目标；命中与普通碰撞伤害分开结算。
const Bomb := preload("res://actor/monster/src/red_ink_bomb.gd")
const Query := preload("res://addons/pixel_destruction/physics/query.gd")
enum Phase { IDLE, WINDUP, ACTIVE, RECOVERY }
var phase := Phase.IDLE
var elapsed := 0.0
var cooldown := 0.8
var facing := -1
var striking_arm := "RightArm"
var aim := Vector2.ZERO
var hit := false
var released := false
var windup := 0.3
var active := 0.3
var recovery := 0.45


func busy() -> bool:
	return phase != Phase.IDLE


func cancel(monster: Node2D) -> void:
	phase = Phase.IDLE
	elapsed = 0.0
	cooldown = maxf(cooldown, 0.6)
	_tag_bodies(monster, false)
	_set_bomb_visible(monster, true)


func update(monster: Node2D, delta: float) -> void:
	var level: Node2D = monster._find_physics_world()
	var player := monster.get_tree().get_first_node_in_group(&"player") as Node2D
	if not monster.attacks_enabled or monster._editor_physics_paused or monster._dead \
			or monster._ragdoll == null or level == null or player == null:
		cancel(monster)
		return
	var death := player.get_node_or_null("FallDeath")
	var health := player.get_node_or_null("InkHealth")
	if health == null or not health.damage_enabled or (death != null and death._dead):
		cancel(monster)
		return
	var upright: float = level.world.gravity.angle() - PI * 0.5 if not level.world.gravity.is_zero_approx() else 0.0
	if monster._hit_recovery > 0.0 or absf(wrapf(monster.body.rotation - upright, -PI, PI)) > 0.5 \
			or monster._ragdoll.recovery_strength < 0.95:
		cancel(monster)
		return
	cooldown = maxf(0.0, cooldown - delta)
	if phase == Phase.IDLE:
		if cooldown > 0.0:
			return
		var center: Vector2 = monster.body.com_world()
		var target: Vector2 = player.body.com_world()
		var size: float = maxf(absf(monster.global_scale.x), 0.1)
		var reach: float = monster.body.aabb.size.x * 0.5 + player.body.aabb.size.x * 0.5 + 75.0 * size
		if monster.kind == monster.Kind.SHIELD_SOLDIER and monster._ragdoll.shield_body != null:
			var shield_bounds: Rect2 = monster._ragdoll.shield_body.aabb
			reach = maxf(reach, absf(shield_bounds.get_center().x - center.x)
				+ shield_bounds.size.x * 0.5 + player.body.aabb.size.x * 0.5 + 25.0 * size)
		if monster.kind == monster.Kind.BOMB_SIDE:
			reach = 650.0 * size
		if absf(target.x - center.x) > reach or absf(target.y - center.y) > 180.0 * size:
			return
		if not clear_path(level.world, center, target, monster):
			cooldown = 0.2
			return
		facing = -1 if target.x < center.x else 1
		monster.face_direction(facing)
		if monster.kind != monster.Kind.BOMB_SIDE:
			var front := -INF
			for part in monster._ragdoll.parts:
				if not str(part.bone.name).ends_with("Arm"):
					continue
				var projection: float = part.body.position.x * facing
				if projection > front:
					front = projection
					striking_arm = str(part.bone.name)
		aim = target # 抬手时锁定落点，不在飞行中追踪。
		windup = 0.7 if monster.kind == monster.Kind.BOMB_SIDE else (0.55 if monster.kind == monster.Kind.SHIELD_SOLDIER else 0.3)
		active = 0.4 if monster.kind == monster.Kind.BOMB_SIDE else (0.35 if monster.kind == monster.Kind.SHIELD_SOLDIER else 0.45)
		recovery = 0.8 if monster.kind == monster.Kind.BOMB_SIDE else (0.9 if monster.kind == monster.Kind.SHIELD_SOLDIER else 0.45)
		phase = Phase.WINDUP
		elapsed = 0.0
		hit = false
		released = false
		_tag_bodies(monster, true)
		return
	elapsed += delta
	if phase == Phase.WINDUP and elapsed >= windup:
		phase = Phase.ACTIVE
		elapsed = 0.0
	elif phase == Phase.ACTIVE:
		if monster.kind == monster.Kind.BOMB_SIDE:
			if not released and elapsed >= 0.18:
				_throw(monster, level)
		elif not hit and elapsed >= 0.12:
			_melee(monster, player, level)
		if elapsed >= active:
			phase = Phase.RECOVERY
			elapsed = 0.0
	elif phase == Phase.RECOVERY and elapsed >= recovery:
		cancel(monster)
		cooldown = 1.0 if monster.kind == monster.Kind.BOMB_SIDE else 0.5


func desired_angle(monster: Node2D, part: Dictionary, baseline: float) -> float:
	if not busy() or not str(part.bone.name).ends_with("Arm"):
		return baseline
	var holder: bool = monster.kind == monster.Kind.SHIELD_SOLDIER and not monster.shield_broken \
		and part == monster._ragdoll.shield_holder
	if monster.kind == monster.Kind.SHIELD_SOLDIER and monster._ragdoll.shield_body != null and not monster.shield_broken and not holder:
		return baseline
	var arm_name := "RightArm" if monster.kind == monster.Kind.BOMB_SIDE else striking_arm
	if not holder and str(part.bone.name) != arm_name:
		return baseline
	var blend := smoothstep(0.0, windup, elapsed) if phase == Phase.WINDUP else 1.0
	if phase == Phase.RECOVERY:
		blend = 1.0 - smoothstep(0.0, recovery, elapsed)
	if holder:
		# 齐地大盾只小幅度前推，不能将盾底插进地面。
		var shove := -0.10 if phase == Phase.WINDUP else 0.22
		return baseline + shove * blend * (-1.0 if facing > 0 else 1.0)
	if monster.kind == monster.Kind.BOMB_SIDE:
		var animation: Animation = monster._animation.get_animation("throw")
		var track := animation.find_track(NodePath(str(part.control.bone) + ":rotation"), Animation.TYPE_VALUE)
		var clock := elapsed / windup * 0.4 if phase == Phase.WINDUP else (0.4 + elapsed / active * 0.4)
		if phase == Phase.RECOVERY:
			clock = 0.8 + elapsed / recovery * 0.4
		return baseline + clampf(wrapf(float(animation.value_track_interpolate(track, clock)) - baseline, -PI, PI), -1.3, 1.3)
	var direction := Vector2(-facing * 0.4, 0.75) if phase == Phase.WINDUP else Vector2(facing, -0.1)
	var local: Vector2 = part.bone.get_parent().global_transform.basis_xform_inv(direction)
	var target: float = local.angle() - Vector2(part.control.rest_direction).angle()
	return baseline + clampf(wrapf(target - baseline, -PI, PI), -1.25, 1.25) * blend


func _melee(monster: Node2D, player: Node2D, level: Node2D) -> void:
	var source = null
	if monster.kind == monster.Kind.SHIELD_SOLDIER and not monster.shield_broken:
		source = monster._ragdoll.shield_body
	if source == null:
		for part in monster._ragdoll.parts:
			if str(part.bone.name) == striking_arm:
				source = part.body
	if source == null:
		return
	var padding: float = 12.0 * absf(monster.global_scale.x)
	if not source.aabb.grow(padding).intersects(player.body.aabb):
		return
	var target: Vector2 = player.body.com_world()
	if (target.x - monster.body.com_world().x) * facing < -padding:
		return
	if not clear_path(level.world, source.com_world(), target, monster):
		return
	hit = true
	var amount := 600.0
	if monster.kind == monster.Kind.SHIELD_SOLDIER:
		amount = 700.0 if monster.shield_broken else 900.0
	damage_player(player, amount, Vector2(facing * 65.0, -12.0))


func _throw(monster: Node2D, level: Node2D) -> void:
	released = true
	monster._ragdoll.update_pose(false)
	var art := monster._visual.get_node("Skeleton2D/BodyHead/RightArm/BombArt") as Sprite2D
	var projectile = Bomb.spawn(level, art, monster, aim)
	if projectile != null:
		art.visible = false


func _set_bomb_visible(monster: Node2D, visible: bool) -> void:
	if monster.kind != monster.Kind.BOMB_SIDE or monster._visual == null:
		return
	var art := monster._visual.get_node_or_null("Skeleton2D/BodyHead/RightArm/BombArt") as Sprite2D
	if art != null:
		art.visible = visible


func _tag_bodies(monster: Node2D, enabled: bool) -> void:
	if monster._body == null:
		return
	var bodies: Array = [monster._body]
	if monster._ragdoll != null:
		for part in monster._ragdoll.parts:
			bodies.append(part.body)
		if monster._ragdoll.shield_body != null:
			bodies.append(monster._ragdoll.shield_body)
	for body in bodies:
		if enabled:
			body.tags["scripted_attack"] = true
		else:
			body.tags.erase("scripted_attack")


static func damage_player(player: Node2D, amount: float, velocity: Vector2) -> void:
	var health := player.get_node_or_null("InkHealth")
	var death := player.get_node_or_null("FallDeath")
	if health == null or not health.damage_enabled or (death != null and death._dead):
		return
	health.damage(amount)
	var body = player.get("body")
	if body != null:
		body.apply_central_impulse(velocity * body.mass)
		body.awake = true
		body.sleep_timer = 0.0


static func clear_path(world, start: Vector2, end: Vector2, owner: Node2D = null) -> bool:
	var ray := end - start
	var distance := ray.length()
	if distance < 1.0:
		return true
	var bounds := Rect2(start, Vector2.ZERO).expand(end).grow(2.0)
	for body in world.bodies_in(bounds):
		if body.collision_layer == 0 or body.tags.has("living") or body.tags.has("monster_projectile"):
			continue
		var receiver: WeakRef = body.tags.get("monster_receiver")
		if receiver != null and receiver.get_ref() == owner:
			continue
		for step in range(0, ceili(distance), 2):
			if Query.solid_at(body, start + ray * (float(step) / distance)):
				return false
	return true
