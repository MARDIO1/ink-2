extends SceneTree
const Attack := preload("res://actor/monster/src/monster_attack.gd")
const Bomb := preload("res://actor/monster/src/red_ink_bomb.gd")
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(label: String, condition: bool) -> void:
	print("[MonsterAttack] ", label, ": ", "PASS" if condition else "FAIL")
	if not condition:
		failures += 1


func _run() -> void:
	var level := (load("res://test/fixtures/maps/base_level.tscn") as PackedScene).instantiate()
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	root.add_child(level)
	await process_frame
	creative.set_active(true)
	var player = level.get_node("Player")
	var health = player.get_node("InkHealth")
	var game_ui := preload("res://ui/game_ui.tscn").instantiate()
	level.add_child(game_ui)
	var hud = game_ui.get_node("Hud")
	var actors: Array = []
	for kind in [1, 3, 2]:
		actors.append(creative.place_monster(kind, Vector2(1000 + kind * 500, -500), false))
	await process_frame
	creative.set_active(false)
	level.process_mode = Node.PROCESS_MODE_DISABLED
	health.damage_enabled = true
	for actor in get_nodes_in_group(&"map_monster"):
		actor.attacks_enabled = false
	for monster in actors:
		monster.attacks_enabled = true
		monster._editor_physics_paused = false
		monster._ragdoll.recovery_strength = 1.0
		monster._hit_recovery = 0.0
		var attack = monster._attack
		attack.cooldown = 0.0
		player.body.position = monster.body.com_world() + Vector2(-80, 0) - player.body.local_com
		player.body.refresh_com()
		player.body.update_aabb()
		var before: float = health.ink_of(1)
		attack.update(monster, 0.01)
		_check("windup starts for kind " + str(monster.kind), attack.phase == Attack.Phase.WINDUP)
		_check("windup has no damage", health.ink_of(1) == before)
		var old_facing: int = monster._current_facing
		player.body.position.x += 160
		player.body.refresh_com()
		player.body.update_aabb()
		monster._update_walk_state(not attack.busy())
		_check("facing locked while winding up", monster._current_facing == old_facing)
		attack.elapsed = attack.windup * 0.8
		var pose_changed := false
		for part in monster._ragdoll.parts:
			var desired: float = attack.desired_angle(monster, part, part.rest_angle)
			pose_changed = pose_changed or absf(wrapf(desired - part.rest_angle, -PI, PI)) > 0.05
		_check("attack changes arm motor target", pose_changed)
		monster._hit_recovery = 0.1
		attack.update(monster, 0.01)
		_check("hit cancels attack", not attack.busy() and not monster.body.tags.has("scripted_attack"))
		monster._hit_recovery = 0.0
		if monster.kind != 2:
			attack.phase = Attack.Phase.ACTIVE
			attack.elapsed = 0.15
			attack.facing = -1
			attack.hit = false
			var striking = monster._ragdoll.shield_body
			if striking == null:
				for part in monster._ragdoll.parts:
					if str(part.bone.name) == attack.striking_arm:
						striking = part.body
			player.body.position = monster.body.com_world() + Vector2(-40, 0) - player.body.local_com
			player.body.refresh_com()
			player.body.update_aabb()
			striking.position = player.body.com_world() - striking.local_com
			striking.refresh_com()
			striking.update_aabb()
			before = health.ink_of(1)
			attack.update(monster, 0.05)
			var amount: float = 900.0 if monster.kind == 3 else 600.0
			_check("melee damages once", is_equal_approx(before - health.ink_of(1), amount))
			_check("damage updates both HUD meters immediately", is_equal_approx(hud.health_bar.value, health.ratio_of(1) * 100.0)
				and hud.health_bar.value == hud.bottle_fill.value)
			attack.update(monster, 0.05)
			_check("no repeated damage in active window", is_equal_approx(before - health.ink_of(1), amount))
			if monster.kind == 3:
				attack.cancel(monster)
				monster.shield_broken = true
				attack.phase = Attack.Phase.ACTIVE
				attack.elapsed = 0.15
				attack.hit = false
				for part in monster._ragdoll.parts:
					if str(part.bone.name) == attack.striking_arm:
						part.body.position = player.body.com_world() - part.body.local_com
						part.body.refresh_com()
						part.body.update_aabb()
				before = health.ink_of(1)
				attack.update(monster, 0.05)
				_check("broken shield falls back to punch", is_equal_approx(before - health.ink_of(1), 700.0))
		attack.cancel(monster)
		monster.attacks_enabled = false
	var bomber = actors.back()
	bomber.attacks_enabled = true
	var art: Sprite2D = bomber._visual.get_node("Skeleton2D/BodyHead/RightArm/BombArt")
	_check("held and thrown bomb size is 75 percent of previous scale", art.scale.is_equal_approx(Vector2(0.3, 0.3)))
	var transform := art.global_transform
	var body_count: int = level.world.bodies.size()
	var joint_count: int = level.world.joints.size()
	bomber._attack.phase = Attack.Phase.ACTIVE
	bomber._attack.elapsed = 0.2
	bomber._attack.aim = bomber.body.com_world() + Vector2(-250, 0)
	bomber._attack._throw(bomber, level)
	var bomb = get_nodes_in_group(&"monster_projectile").back()
	var projectile_body = bomb.body
	_check("throw hides held bomb", not art.visible)
	_check("projectile uses same sprite and transform", bomb.art.texture == art.texture
		and bomb.art.global_transform.is_equal_approx(transform))
	_check("physical projectile registered with CCD", level.world.bodies.size() == body_count + 1
		and projectile_body.ccd and projectile_body.internal_render and not bomb.art.visible)
	_check("same canvas red ink density and destruction flags", projectile_body.shapes.all(func(shape): return shape.density_scale == 1.0)
		and not projectile_body.tags.has("living") and not projectile_body.tags.has("scripted_attack"))
	var red_pixels := 0
	var only_red := true
	for shape in projectile_body.shapes:
		red_pixels += shape.pixel_count()
		for chunk in shape.chunks.values():
			for material in chunk.mat:
				only_red = only_red and material in [0, 8]
	_check("projectile consists of actual red material pixels", only_red and red_pixels > 0)
	_check("ballistic launch upward toward locked aim", projectile_body.linear_velocity.x < 0.0 and projectile_body.linear_velocity.y < 0.0)
	_check("projectile excludes shooter contacts", bomb.exclusions.size() == 5
		and bomb.exclusions.all(func(joint): return not joint.contacts_enabled))
	bomber._attack.cancel(bomber)
	_check("held bomb replenished after recovery", art.visible)
	player.body.position = projectile_body.com_world() - player.body.local_com
	player.body.refresh_com()
	player.body.update_aabb()
	var before: float = health.ink_of(1)
	var red = level.get_node("SimulationRuntime/RedInk")
	var pending_count: int = red._pending.size()
	for second in 20:
		bomb._physics_process(1.0)
	_check("idle grenade never auto ignites or expires", level.world.bodies.has(projectile_body)
		and red._pending.size() == pending_count and health.ink_of(1) == before)
	_check("no demo explosion or timed detonation entry", not bomb.has_method("detonate")
		and not bomb.get_script().get_source_code().contains("func _draw"))
	var saved_position: Vector2 = projectile_body.position
	projectile_body.position += Vector2(5000, 0)
	projectile_body.refresh_com()
	projectile_body.update_aabb()
	bomb._physics_process(0.0)
	_check("separated grenade restores ordinary shooter collision", bomb.exclusions.is_empty()
		and level.world.joints.size() == joint_count)
	projectile_body.position = saved_position
	projectile_body.refresh_com()
	projectile_body.update_aabb()
	# 用普通破坏提交模拟裂纹触及红墨；游戏手雷本身不再提交点火计划。
	var removals: Dictionary = {}
	for ink_shape in projectile_body.shapes:
		var cells: Dictionary = {}
		var bounds: Rect2i = ink_shape.local_aabb()
		for y in range(bounds.position.y, bounds.end.y):
			for x in range(bounds.position.x, bounds.end.x):
				if ink_shape.get_pixel(x, y) == 8:
					cells[Vector2i(x, y)] = true
		removals[ink_shape] = cells
	var runtime = level.get_node("SimulationRuntime")
	var previous_nodes: Array = level._body_nodes.duplicate()
	var committed: Dictionary = runtime.commit(level.world, {projectile_body: removals}, {}, true)
	level.get_node("SimulationRuntime/PhysicsStep").sync_after_commit(previous_nodes, committed.changed)
	var queued_count: int = red._pending.size()
	_check("ordinary damage queues shared red ink reaction", queued_count > pending_count and health.ink_of(1) == before)
	var energy := 0.0
	for event in red._pending.slice(pending_count):
		energy += float(event.energy)
	_check("shared blast energy equals actual red pixel count", is_equal_approx(energy, red_pixels))
	bomb._physics_process(1.0)
	_check("grenade cleanup cannot enqueue another explosion", red._pending.size() == queued_count)
	_check("explosion clears native collider and exclusion joints", projectile_body.rapier_id == 0
		and level.world.bodies.size() == body_count and level.world.joints.size() == joint_count)
	_check("projectile shape owner cycle cleared", projectile_body.shapes.all(func(shape): return shape.owner_body == null))
	var context: Dictionary = level.get_node("SimulationRuntime")._context()
	var reaction: Dictionary = red.resolve_fixed(context)
	_check("red ink resolves ordinary sound/damage/radial impulse pipeline", not reaction.impulses.is_empty()
		and reaction.impulses.size() == queued_count and reaction.player_damage > 0.0)
	player.apply_collision_damage(reaction.player_damage, reaction.get("player_impacts", []))
	var blast_lost: float = before - health.ink_of(1)
	print("[MonsterAttack] blast damage=%.1f lost=%.1f max=%.1f dead=%s" % [
		reaction.player_damage, blast_lost, health.max_of(1), str(player.get_node("FallDeath")._dead)])
	_check("blast drains a large share of health without one-shotting",
		blast_lost >= health.max_of(1) * 0.4 and blast_lost < health.max_of(1)
		and not player.get_node("FallDeath")._dead
		and is_equal_approx(hud.health_bar.value, 100.0 * health.ink_of(1) / health.max_of(1)))
	await process_frame
	_check("explosion sprite expires", get_nodes_in_group(&"monster_projectile").is_empty())
	# 实心墙必须挡住攻击和爆炸，不能隔墙扣血。
	var wall := PBody.new()
	var shape := Shape.new()
	shape.fill_rect(Rect2i(-5, -100, 10, 200), 1)
	wall.make_static()
	wall.position = Vector2(5000, -500)
	level.world.add_body(wall, [shape])
	_check("wall blocks line of attack", not Attack.clear_path(level.world, Vector2(4950, -500), Vector2(5050, -500)))
	level.world.remove_body(wall)
	shape.owner_body = null
	level.realign_body_nodes()
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
