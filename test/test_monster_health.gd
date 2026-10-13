extends SceneTree
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, ok: bool) -> void:
	print("[MonsterHealth] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _run() -> void:
	var level: Node = load("res://map/asset/imported/main.tscn").instantiate()
	root.add_child(level)
	await process_frame
	var creative: Node = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.set_active(true)
	var monsters: Array = []
	for spec in [[1, 5000.0], [3, 10000.0], [2, 2500.0]]:
		var monster: Node2D = creative.place_monster(spec[0], Vector2(500 * spec[0], 100), false)
		monsters.append(monster)
		_check("placed monster initial health", monster.health == spec[1] and monster.max_health == spec[1])
		_check("placed monster has full UI", monster._health_bar.visible and monster._health_bar._material.get_shader_parameter("health_ratio") == 1.0)
		_check("editor damage disabled", monster.apply_damage(100) == 0.0 and monster.health == spec[1])
	# 冻结模拟但开放伤害接口，避免测试中怪物互相碰撞影响断言。
	paused = true
	creative.active = false
	for monster in monsters:
		monster._editor_physics_paused = false
	var shield = monsters[1]
	_check("shield protects owner HP", shield.apply_damage(400, shield._ragdoll.shield_body) == 0.0 and shield.health == 10000.0)
	shield.receive_contact_impact(shield.body.com_world(), Vector2(100000, 0), shield._ragdoll.shield_body)
	_check("contact hitting shield never reduces HP", shield.health == 10000.0)
	shield._hit_cooldown = 0.0
	shield.receive_contact_impact(shield.body.com_world(), Vector2(100000, 0), shield.body)
	_check("contact hitting body reduces HP", shield.health == 9900.0)
	shield._hit_cooldown = 0.0
	shield.receive_contact_impact(shield.body.com_world(), Vector2(100000, 0), shield.body, false)
	_check("static collisions do not reduce HP", shield.health == 9900.0)
	var damage: Node = load("res://root/src/impact_damage.gd").new()
	root.add_child(damage)
	damage.apply_impulse_damage(level.world, shield.body, shield.body.com_world(), Vector2.RIGHT,
		100000.0, level.get_node("Player").body, [], {"removals": {}, "player_damage": 0.0})
	_check("explosion damage reaches monster HP", shield.health == 9800.0)
	damage.queue_free()
	var soldier = monsters[0]
	_check("body damage updates health", soldier.apply_damage(500) == 500.0 and soldier.health == 4500.0)
	_check("UI ratio follows actual health", is_equal_approx(soldier._health_bar._material.get_shader_parameter("health_ratio"), 0.9))
	_check("invalid damage rejected", soldier.apply_damage(-100) == 0.0 and soldier.apply_damage(INF) == 0.0)
	var bomb = monsters[2]
	bomb.receive_contact_impact(bomb.body.com_world(), Vector2(100000, 0), bomb.body)
	_check("bomb physical contact reduces health", bomb.health == 2400.0)
	bomb.receive_contact_impact(bomb.body.com_world(), Vector2(100000, 0), bomb.body)
	_check("held attack cooldown avoids duplicate damage", bomb.health == 2400.0)
	var reference: WeakRef = weakref(soldier)
	soldier.apply_damage(10000)
	_check("health zero queues safe death", soldier.health == 0.0 and soldier._dead and not soldier._health_bar.visible)
	await process_frame
	await process_frame
	_check("dead monster removed", reference.get_ref() == null)
	paused = false
	level.queue_free()
	await process_frame
	if OS.get_cmdline_user_args().has("--preview"):
		await _preview()
	quit(1 if failures else 0)

func _preview() -> void:
	root.content_scale_size = Vector2i(960, 540)
	root.size = Vector2i(960, 540)
	var bg := ColorRect.new()
	bg.size = Vector2(960, 540)
	bg.color = Color(0.94, 0.92, 0.87)
	root.add_child(bg)
	for i in 3:
		var bar: Sprite2D = load("res://actor/monster/src/monster_health_bar.gd").new()
		root.add_child(bar)
		bar.position = Vector2(480, 140 + i * 120)
		bar.update_health([1000.0, 500.0, 100.0][i], 1000.0, 700.0)
		bar.global_scale.y *= 4.0
	await process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("D:/Ink/output")
	root.get_texture().get_image().save_png("D:/Ink/output/monster_health_preview.png")
