extends SceneTree

var failures := 0
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("%s %s" % ["PASS" if condition else "FAIL", label])


func _run() -> void:
	var app := preload("res://root/root.tscn").instantiate()
	root.add_child(app)
	await process_frame
	var music := app.get_node("Music") as AudioStreamPlayer
	_check("menu music starts and loops", music.playing
		and music.stream.resource_path.ends_with("Miniature Parade.ogg")
		and music.stream is AudioStreamOggVorbis
		and (music.stream as AudioStreamOggVorbis).loop)

	var level: Node = app.load_level(preload("res://map/asset/imported/main.tscn"))
	await process_frame
	_check("level music switches and loops", music.playing
		and music.stream.resource_path.ends_with("Cartoon Spy Groove.ogg")
		and (music.stream as AudioStreamOggVorbis).loop)

	var runtime: Node = level.get_node("SimulationRuntime")
	var feedback = runtime.get_node("HitFeedback")
	var red = runtime.get_node("RedInk")
	var yellow = runtime.get_node("YellowInk")
	var death = level.get_node("Player/FallDeath")
	var hurt_sound := death.get_node("HurtSound") as AudioStreamPlayer
	var death_sound := death.get_node("DeathSound") as AudioStreamPlayer
	_check("all four gameplay sounds are assigned", feedback.impact_stream != null
		and red.explosion_stream != null and yellow.tension_stream != null
		and yellow.release_stream != null)
	_check("player hurt and death sounds are assigned", hurt_sound.stream != null
		and death_sound.stream != null and death.hurt_sound_threshold > 0.0)
	_check("gameplay sounds have no long preroll", feedback.impact_stream.get_length() < 0.5
		and red.explosion_stream.get_length() < 1.1
		and yellow.tension_stream.get_length() < 0.8
		and yellow.release_stream.get_length() < 1.0)
	_check("player sounds have no long preroll", hurt_sound.stream.get_length() < 1.3
		and death_sound.stream.get_length() < 1.7)
	_check("music sits clearly below strong sound effects", app.music_volume_db <= -20.0
		and feedback.maximum_volume_db - app.music_volume_db >= 18.0
		and red.loud_explosion_db - app.music_volume_db >= 18.0)
	_check("impact loudness has an obvious range",
		feedback.volume_db_for_impulse(feedback.full_volume_impulse)
		- feedback.volume_db_for_impulse(feedback.minimum_impulse + 1.0) > 18.0)
	_check("explosion loudness has an obvious range",
		red.explosion_volume_db(red.event_chunk_size * red.event_chunk_size)
		- red.explosion_volume_db(1.0) > 15.0)
	_check("spring tension uses three audible bands", yellow.spring_load_band(0.15) == 1
		and yellow.spring_load_band(0.55) == 2 and yellow.spring_load_band(1.0) == 3
		and yellow.spring_volume_db(1.0) - yellow.spring_volume_db(1.0 / 3.0) > 5.0)

	app.queue_free()
	for _frame in 5:
		await process_frame
	print("[AudioIntegration] %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
