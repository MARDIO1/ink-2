extends "res://test/test_collision_damage.gd"
## 玩家生命值只认黑墨；其他颜色独立记账，黑墨归零复用现有死亡/复活流程。

const InkPalette := preload("res://ink/src/ink_palette.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene = MAIN.instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	await process_frame
	var player = scene.get_node("Player")
	var health = player.get_node("InkHealth")
	var death = player.get_node("FallDeath")
	var black_id: int = InkPalette.material_id_of(InkPalette.BLACK)
	var grey_id: int = InkPalette.material_id_of(InkPalette.GREY)
	var game_ui := preload("res://ui/game_ui.tscn").instantiate()
	scene.add_child(game_ui)
	await process_frame
	var hud = game_ui.get_node("Hud")

	var black_before: float = health.ink_of(black_id)
	health.reduce(grey_id, 1234.0)
	_check("ink colors keep separate ledgers", health.ink_of(black_id) == black_before
		and health.ink_of(grey_id) == health.max_of(grey_id) - 1234.0)
	_check("HUD reads black health only", is_equal_approx(hud.bottle_fill.value, 100.0)
		and hud.ink_meter.text == "黑墨 20000 px")

	death._body = player.body
	health.reduce(black_id, health.max_of(black_id))
	_check("empty black ink triggers death", death._dead and health.ink_of(black_id) == 0.0)
	death._respawn()
	_check("respawn refills only black health", not death._dead
		and health.ink_of(black_id) == health.max_of(black_id)
		and health.ink_of(grey_id) == health.max_of(grey_id) - 1234.0)

	scene.get_node("Player/Arm/Hand/HandControl")._release_grab()
	scene.get_node("Player/Arm/Hand/HandControl")._remove_arm()
	_release(scene.world)
	scene.queue_free()
	await process_frame
	print("[PlayerHealth] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
