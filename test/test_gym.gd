extends "res://test/test_collision_damage.gd"

const TEMP_CONFIG := "user://test_player_controller_config.tres"


func _run() -> void:
	var scene = MAIN.instantiate()
	var source: Resource = scene.get_node("Player").controller_config
	ResourceSaver.save(source.duplicate(true), TEMP_CONFIG)
	scene.get_node("Player").controller_config = ResourceLoader.load(
		TEMP_CONFIG, "", ResourceLoader.CACHE_MODE_IGNORE)
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	await process_frame

	var player = scene.get_node("Player")
	var feet = scene.get_node("Player/PlayerInput")
	var hand = scene.get_node("Player/Arm/Hand/HandControl")
	var gym = scene.get_node("Gym")
	_check("gym keeps all 12 controller values and adds ink tuning", gym._targets.size() > 12)
	_check("every gym row has numeric input", gym._numbers.size() == gym._targets.size()
		and gym._numbers.all(func(number): return number is SpinBox))
	_check("gym includes yellow stiffness", gym._props.count("stiffness_per_width") == 1)
	_check("gym includes six ink material property groups",
		gym._props.count("density") == 6 and gym._props.count("friction") == 6
		and gym._props.count("compress_strength") == 6
		and gym._props.count("shear_strength") == 6)
	_check("player reads controller config", is_equal_approx(
		feet.max_force, player.controller_config.foot_max_force)
		and is_equal_approx(hand.max_force, player.controller_config.hand_max_force))

	var original_force: float = feet.max_force
	gym.set_knob(0, 0.5)
	_check("slider changes runtime force", is_equal_approx(feet.max_force, original_force * 0.5))
	_check("unsaved slider leaves config unchanged", is_equal_approx(
		player.controller_config.foot_max_force, original_force))
	gym._numbers[2].value = 320.0
	_check("numeric input changes runtime value and slider", is_equal_approx(
		feet.move_speed, 320.0) and is_equal_approx(gym._sliders[2].value, 1.6))

	var original_mass: float = player.body.mass
	var original_com: Vector2 = player.body.com_world()
	gym.set_knob(11, 0.5)
	_check("mass slider refreshes actual body mass", is_equal_approx(
		player.body.mass, original_mass * 0.5))
	_check("uniform density scaling keeps center of mass", player.body.com_world().distance_to(
		original_com) < 0.001)
	_check("mass numeric input shows actual mass", is_equal_approx(
		gym._numbers[11].value, player.body.mass))

	gym._save()
	var saved: Resource = ResourceLoader.load(TEMP_CONFIG, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check("save persists runtime values", is_equal_approx(saved.foot_max_force,
		original_force * 0.5) and is_equal_approx(saved.foot_move_speed, 320.0)
		and is_equal_approx(saved.body_density_scale, 0.5))
	_check("save rebases sliders", is_equal_approx(gym._sliders[0].value, 1.0)
		and is_equal_approx(gym._sliders[11].value, 1.0))

	_release(scene.world)
	scene.queue_free()
	await process_frame
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_CONFIG))
	print("[Gym] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
