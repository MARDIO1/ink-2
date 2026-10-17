extends SceneTree

const Settings := preload("res://sound/src/audio_settings.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[AudioSettings] %s %s" % ["PASS" if ok else "FAIL", label])

func volume(bus: StringName) -> float:
	return db_to_linear(AudioServer.get_bus_volume_db(AudioServer.get_bus_index(bus)))

func _run() -> void:
	var settings := root.get_node("AudioSettings")
	var original_path: String = settings.config_path
	var original_music: float = settings.music_volume
	var original_sfx: float = settings.sfx_volume
	# 使用独立测试文件，绝不覆盖用户音量偏好。
	var test_path := "user://test_audio_settings_%d.cfg" % Time.get_ticks_usec()
	settings.config_path = test_path
	settings.load_settings()
	check("missing preferences preserve original full-volume mix", settings.music_volume == 1.0 and settings.sfx_volume == 1.0)
	var master_volume := AudioServer.get_bus_volume_db(0)
	var app = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	await process_frame
	var music := app.get_node("Music") as AudioStreamPlayer
	check("menu background music routes to BGM", music.bus == &"BGM" and music.playing)
	var level = app.load_level(load("res://test/fixtures/maps/base_level.tscn"))
	level.auto_step = false
	app._set_screen(load("res://ui/game_ui.tscn").instantiate())
	await process_frame
	var runtime: Node = level.get_node("SimulationRuntime")
	check("collision sounds route to SFX", runtime.get_node("HitFeedback")._voices.all(func(voice): return voice.bus == &"SFX"))
	check("explosion sounds route to SFX", runtime.get_node("RedInk")._explosion_voices.all(func(voice): return voice.bus == &"SFX"))
	check("spring sounds route to SFX", runtime.get_node("YellowInk")._spring_voices.all(func(voice): return voice.bus == &"SFX"))
	check("hurt and death sounds route to SFX", level.get_node("Player/FallDeath/HurtSound").bus == &"SFX"
		and level.get_node("Player/FallDeath/DeathSound").bus == &"SFX")
	var esc = get_first_node_in_group(&"esc_menu")
	esc.open_menu()
	await process_frame
	var panel: Control = esc.get_node("Center/Panel")
	check("pause menu fits game viewport", root.get_visible_rect().encloses(panel.get_global_rect()))
	esc.get_node("Center/Panel/Buttons/SoundButton").pressed.emit()
	await process_frame
	check("sound button opens subpage without resuming", paused and esc.sound_page.visible
		and not esc.get_node("Center/Panel/Buttons").visible)
	check("sound subpage fits game viewport", root.get_visible_rect().encloses(panel.get_global_rect()))
	var player_volume: float = music.volume_db
	esc.music_slider.value = 25.0
	check("BGM slider updates only music immediately", is_equal_approx(settings.music_volume, 0.25)
		and is_equal_approx(volume(&"BGM"), 0.25) and is_equal_approx(volume(&"SFX"), 1.0)
		and music.volume_db == player_volume and music.playing)
	check("music label reflects slider percent", esc.get_node("Center/Panel/SoundPage/MusicRow/Value").text == "25%")
	esc.sfx_slider.value = 0.0
	check("zero SFX fully mutes effects without muting BGM", AudioServer.is_bus_mute(AudioServer.get_bus_index(&"SFX"))
		and not AudioServer.is_bus_mute(AudioServer.get_bus_index(&"BGM")))
	esc.sfx_slider.value = 40.0
	check("raising SFX restores sound and its own volume", not AudioServer.is_bus_mute(AudioServer.get_bus_index(&"SFX"))
		and is_equal_approx(volume(&"SFX"), 0.4) and is_equal_approx(volume(&"BGM"), 0.25))
	check("SFX label reflects slider percent", esc.get_node("Center/Panel/SoundPage/SfxRow/Value").text == "40%")
	var escape := InputEventAction.new()
	escape.action = &"escape"
	escape.pressed = true
	esc._unhandled_input(escape)
	check("ESC returns from sound page while keeping game paused", paused and esc.visible
		and not esc.sound_page.visible and esc.get_node("Center/Panel/Buttons").visible)
	var saved := ConfigFile.new()
	check("return persists both independent settings", saved.load(test_path) == OK
		and is_equal_approx(saved.get_value("audio", "bgm_volume"), 0.25)
		and is_equal_approx(saved.get_value("audio", "sfx_volume"), 0.4))
	esc._unhandled_input(escape)
	check("second ESC closes pause menu and resumes", not paused and not esc.visible)
	var restored := Settings.new()
	restored.config_path = test_path
	root.add_child(restored)
	check("preferences reload in a fresh settings instance", is_equal_approx(restored.music_volume, 0.25)
		and is_equal_approx(restored.sfx_volume, 0.4))
	restored.queue_free()
	esc.open_menu()
	esc.get_node("Center/Panel/Buttons/SoundButton").pressed.emit()
	check("reopened page displays saved values", esc.music_slider.value == 25.0 and esc.sfx_slider.value == 40.0)
	esc.music_slider.value = 0.0
	check("BGM can mute independently", AudioServer.is_bus_mute(AudioServer.get_bus_index(&"BGM"))
		and not AudioServer.is_bus_mute(AudioServer.get_bus_index(&"SFX")))
	esc._on_continue_button_pressed()
	check("closing directly from subpage resumes and saves", not paused and not esc.visible
		and saved.load(test_path) == OK and saved.get_value("audio", "bgm_volume") == 0.0)
	saved.set_value("audio", "bgm_volume", 20.0)
	saved.set_value("audio", "sfx_volume", "invalid")
	saved.save(test_path)
	settings.load_settings()
	check("invalid preferences clamp or restore safe defaults", settings.music_volume == 1.0 and settings.sfx_volume == 1.0)
	check("volume controls leave Master unchanged", AudioServer.get_bus_volume_db(0) == master_volume)
	settings.config_path = original_path
	settings.set_music_volume(original_music)
	settings.set_sfx_volume(original_sfx)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(test_path))
	app.queue_free()
	for frame in 5:
		await process_frame
	print("[AudioSettings] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
