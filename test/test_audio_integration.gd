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

	var level: Node = app.load_level(preload("res://map/main.tscn"))
	await process_frame
	_check("level music switches and loops", music.playing
		and music.stream.resource_path.ends_with("Cartoon Spy Groove.ogg")
		and (music.stream as AudioStreamOggVorbis).loop)

	var runtime: Node = level.get_node("SimulationRuntime")
	var feedback = runtime.get_node("HitFeedback")
	var red = runtime.get_node("RedInk")
	var yellow = runtime.get_node("YellowInk")
	_check("all four gameplay sounds are assigned", feedback.impact_stream != null
		and red.explosion_stream != null and yellow.tension_stream != null
		and yellow.release_stream != null)
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
