extends Node
## 用户音量乘在独立总线上，保留每段音乐/每次碰撞原有的相对响度。
const BGM_BUS := &"BGM"
const SFX_BUS := &"SFX"
var config_path := "user://audio_settings.cfg"
var music_volume := 1.0
var sfx_volume := 1.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_bus(BGM_BUS)
	_ensure_bus(SFX_BUS)
	load_settings()

func _ensure_bus(bus: StringName) -> void:
	if AudioServer.get_bus_index(bus) >= 0:
		return
	var index := AudioServer.bus_count
	AudioServer.add_bus(index)
	AudioServer.set_bus_name(index, bus)
	AudioServer.set_bus_send(index, &"Master")

func _valid_volume(value: Variant) -> float:
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)):
		return 1.0
	return clampf(float(value), 0.0, 1.0)

func set_music_volume(value: float) -> void:
	music_volume = _valid_volume(value)
	_apply(BGM_BUS, music_volume)

func set_sfx_volume(value: float) -> void:
	sfx_volume = _valid_volume(value)
	_apply(SFX_BUS, sfx_volume)

func _apply(bus: StringName, volume: float) -> void:
	_ensure_bus(bus)
	var index := AudioServer.get_bus_index(bus)
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(volume, 0.0001)))
	AudioServer.set_bus_mute(index, volume <= 0.0)

func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(config_path) != OK:
		set_music_volume(1.0)
		set_sfx_volume(1.0)
		return
	set_music_volume(_valid_volume(config.get_value("audio", "bgm_volume", 1.0)))
	set_sfx_volume(_valid_volume(config.get_value("audio", "sfx_volume", 1.0)))

func save_settings() -> Error:
	var config := ConfigFile.new()
	config.set_value("audio", "bgm_volume", music_volume)
	config.set_value("audio", "sfx_volume", sfx_volume)
	var result := config.save(config_path)
	if result != OK:
		push_warning("无法保存声音设置 (%d)" % result)
	return result
