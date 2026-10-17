extends SceneTree
const Effect := preload("res://actor/general/effects/character_death.gd")
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(label: String, condition: bool) -> void:
	print("[DeathEffect] ", label, ": ", condition)
	if not condition:
		failures += 1


func _run() -> void:
	var level := (load("res://test/fixtures/maps/base_level.tscn") as PackedScene).instantiate()
	level.get_node("Creative").auto_save_edits = false
	level.get_node("Creative").auto_save_on_exit = false
	root.add_child(level)
	level.get_node("debugHUD").process_mode = Node.PROCESS_MODE_DISABLED
	await process_frame
	await physics_frame
	var creative = level.get_node("Creative")
	creative.set_active(true)
	var effects: Array = []
	for kind in [1, 3, 2]:
		var monster = creative.place_monster(kind, Vector2(400 * kind, 200), false)
		await process_frame
		monster._editor_physics_paused = false
		creative.active = false
		var owned: Array = [monster.body]
		for part in monster._ragdoll.parts:
			owned.append(part.body)
		if monster._ragdoll.shield_body != null:
			owned.append(monster._ragdoll.shield_body)
		monster.global_rotation = PI if kind == 3 else (PI * 0.5 if kind == 2 else 0.0)
		var expected_foot := Effect.sprites_foot_position(Effect.visible_sprites(monster.get_node("Visual")), monster.global_position)
		monster.apply_damage(monster.max_health)
		var reference: WeakRef = weakref(monster)
		await process_frame
		await process_frame
		_check("dead actor removed while effect survives", reference.get_ref() == null)
		var released := true
		for body in owned:
			released = released and not level.world.bodies.has(body) and body.rapier_id == 0
		_check("no corpse colliders or motors", released)
		var effect = get_nodes_in_group(&"character_death_effect").back()
		effects.append(effect)
		_check("five part snapshot and held item preserved", effect.pieces.size() == (5 if kind == 1 else 6))
		if kind == 2:
			var bomb_mask_valid := false
			for piece in effect.pieces:
				if piece.sprite.name == "BombArt":
					bomb_mask_valid = piece.mask == piece.sprite.texture
			_check("held bomb uses its own solid mask", bomb_mask_valid)
		_check("enemy death uses visible lower edge when rotated", effect._origin.distance_to(expected_foot) < 0.01)
		_check("enemy death has no extra draw effects", not effect.has_method("_draw")
			and effect.get_children().all(func(child): return child is Sprite2D))
		_check("effect is not a saved ink/monster node", effect.owner == null
			and not effect.is_in_group("ink_item") and not effect.is_in_group("map_monster"))
		creative.active = true
	creative.set_active(false)
	# 进入地图编辑器会把可回收实体还原进画布；玩家死亡验收需要一个独立可抓取道具，
	# 因此在编辑器回收了基准 Box 时重新装配一份干净关卡。
	if not level.has_node("Box"):
		level.queue_free()
		await process_frame
		level = (load("res://test/fixtures/maps/base_level.tscn") as PackedScene).instantiate()
		level.get_node("Creative").auto_save_edits = false
		level.get_node("Creative").auto_save_on_exit = false
		root.add_child(level)
		level.get_node("debugHUD").process_mode = Node.PROCESS_MODE_DISABLED
		await process_frame
		await physics_frame
	var player = level.get_node("Player")
	var death = player.get_node("FallDeath")
	var hand = player.get_node("Arm/Hand/HandControl")
	# 玩家抓住普通道具时死亡，不能把道具连带冻结或禁用碰撞。
	var prop = level.get_node("Box")
	hand._begin_grab(prop.body, prop.body.com_world())
	var prop_layer: int = prop.body.collision_layer
	var prop_frozen: bool = prop.body.frozen
	death._die()
	await process_frame
	_check("player death releases grab", hand.grabbed_body == null and hand.arm_joint == null)
	_check("player collider temporarily disabled", player.body.collision_layer == 0 and player.body.frozen)
	_check("grabbed prop stays independent", prop.body.collision_layer == prop_layer and prop.body.frozen == prop_frozen)
	_check("player visual replaced, controls stopped", not player.get_node("Visual").visible
		and player.get_node("PlayerInput").process_mode == Node.PROCESS_MODE_DISABLED)
	_check("player effect has bottle cap and death face", death._death_effect.pieces.any(func(p): return p.role == "Cap"))
	_check("player effect has no extra rope", death._death_effect.find_children("*", "Line2D", true, false).is_empty())
	_check("player effect has no extra draw effects", not death._death_effect.has_method("_draw"))
	var body_visual: Sprite2D = player.get_node("Visual")
	for angle in [0.0, PI * 0.5, PI, -PI * 0.5]:
		body_visual.global_rotation = angle
		var bounds: Rect2 = body_visual.global_transform * body_visual.get_rect()
		_check("rotated death anchor stays at visual lower edge", is_equal_approx(Effect.foot_position(body_visual).y, bounds.end.y))
	death._respawn()
	await process_frame
	_check("respawn restores body and input", player.body.collision_layer != 0 and not player.body.frozen
		and player.get_node("PlayerInput").process_mode != Node.PROCESS_MODE_DISABLED)
	_check("respawn preserves full health", player.get_node("InkHealth").ink_of(1) == 20000.0)
	await create_timer(0.35).timeout
	_check("revive visual restores original sprites", player.get_node("Visual").visible and death._revive_effect == null)
	death._die(true)
	await process_frame
	_check("fall death uses dissolve only", death._death_effect.dissolve_only)
	death._respawn()
	await create_timer(1.7).timeout
	_check("all temporary effects expire", get_nodes_in_group(&"character_death_effect").is_empty())
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
