extends Node
## 统一碰撞反馈入口：从同一份 ImpactEvent 驱动空间音效，并为闪光、抖屏、粒子保留直接调用点。

const ContactImpact = preload("res://root/src/contact_impact.gd")
const ImpactSoundProfile = preload("res://root/src/impact_sound_profile.gd")

#region 音效参数
@export var minimum_approach: float = 300.0
@export var minimum_impulse: float = 120.0
@export var full_volume_impulse: float = 24000.0
@export var minimum_energy: float = 100000.0
@export var full_volume_energy: float = 50000000.0
@export_range(-80.0, 0.0, 0.5) var minimum_volume_db: float = -28.0
@export_range(-20.0, 6.0, 0.5) var maximum_volume_db: float = -2.0
@export_range(-40.0, 0.0, 0.5) var debris_maximum_volume_db: float = -18.0
@export_range(0.0, 0.5, 0.01) var pair_cooldown_seconds: float = 0.08
@export_range(1, 16, 1) var voice_count: int = 6
@export_range(64.0, 10000.0, 1.0) var max_distance: float = 2400.0
@export_range(0.1, 8.0, 0.1) var attenuation: float = 1.0
@export var sound_duration: float = 0.075
@export var audio_bus: StringName = &"Master"
@export var impact_stream: AudioStream
@export var sound_profiles: Array[ImpactSoundProfile] = []
#endregion


#region 状态
var _voices: Array[AudioStreamPlayer2D] = []
var _next_voice := 0
var _last_pair_time_ms: Dictionary = {}
var _fallback_stream: AudioStream
#endregion


#region 生命周期
func _ready() -> void:
	_fallback_stream = impact_stream if impact_stream != null else _build_impact_stream()
	for i in voice_count:
		var voice := AudioStreamPlayer2D.new()
		voice.name = "ImpactVoice%d" % i
		voice.bus = audio_bus
		voice.max_distance = max_distance
		voice.attenuation = attenuation
		add_child(voice)
		_voices.append(voice)
#endregion


#region 接触入口
## SimulationRuntime 每个物理子步明确调用；不广播，也不修改物理或伤害结果。
func resolve_contacts(context: Dictionary, contacts: Array) -> Dictionary:
	var now_ms := Time.get_ticks_msec()
	var dust := ContactImpact.dust_bodies(context.world, context.player_body, context.protected_bodies)
	var candidates: Array[Dictionary] = []
	for contact in contacts:
		if float(contact.approach) < minimum_approach:
			continue
		var event := ContactImpact.build_event(contact)
		if event.is_empty() or event.total_impulse < minimum_impulse:
			continue
		event["is_debris"] = dust.has(event.a_body) or dust.has(event.b_body)
		event["pair"] = _pair_key(event.a_body, event.b_body)
		event["intensity"] = intensity_for_event(event)
		event["score"] = _audible_score(event, context.get("camera"))
		if event.intensity <= 0.0 or _on_cooldown(event.pair, now_ms):
			continue
		candidates.append(event)
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.score) > float(b.score))
	for i in mini(candidates.size(), voice_count):
		var event := candidates[i]
		_last_pair_time_ms[event.pair] = now_ms
		_play_audio(event)
		_flash_contact(event, context)
		_request_camera_shake(event, context)
		_emit_particles(event, context)
	if _last_pair_time_ms.size() > 256:
		_prune_pair_history(now_ms)
	return {}
#endregion


#region 强度
func intensity_for_event(event: Dictionary) -> float:
	return minf(intensity_for_impulse(event.total_impulse), intensity_for_energy(event.energy))


func intensity_for_impulse(impulse: float) -> float:
	return _log_curve(impulse, minimum_impulse, full_volume_impulse)


func intensity_for_energy(energy: float) -> float:
	return _log_curve(energy, minimum_energy, full_volume_energy)


func volume_db_for_event(event: Dictionary) -> float:
	var volume := lerpf(minimum_volume_db, maximum_volume_db, intensity_for_event(event))
	return minf(volume, debris_maximum_volume_db) if event.get("is_debris", false) else volume


func volume_db_for_impulse(impulse: float) -> float:
	return lerpf(minimum_volume_db, maximum_volume_db, intensity_for_impulse(impulse))


func _log_curve(value: float, minimum: float, maximum: float) -> float:
	if value <= minimum:
		return 0.0
	var normalized := clampf((value - minimum) / maxf(maximum - minimum, 0.001), 0.0, 1.0)
	return log(1.0 + normalized * 15.0) / log(16.0)


func _audible_score(event: Dictionary, camera) -> float:
	if camera == null:
		return event.intensity
	var distance: float = Vector2(event.position).distance_to(camera.get_screen_center_position())
	return event.intensity * clampf(1.0 - distance / max_distance, 0.0, 1.0)
#endregion


#region 音源表与播放
func _play_audio(event: Dictionary) -> void:
	if _voices.is_empty():
		return
	var voice := _take_voice()
	var profile: ImpactSoundProfile = _profile_for(event.a_material, event.b_material)
	voice.stream = profile.pick_stream(event.intensity) if profile != null else _fallback_stream
	if voice.stream == null:
		voice.stream = _fallback_stream
	voice.global_position = event.position
	var volume := volume_db_for_event(event) + (profile.volume_db if profile != null else 0.0)
	voice.volume_db = minf(volume, debris_maximum_volume_db) if event.is_debris else volume
	voice.pitch_scale = lerpf(1.12, 0.88, event.intensity) \
		* (profile.pitch_scale if profile != null else 1.0) * randf_range(0.96, 1.04)
	voice.play()


func _profile_for(a_material: int, b_material: int) -> ImpactSoundProfile:
	var best: ImpactSoundProfile = null
	var best_score := -1
	for profile in sound_profiles:
		if profile == null:
			continue
		var score: int = profile.match_score(a_material, b_material)
		if score > best_score:
			best = profile
			best_score = score
	return best


func _take_voice() -> AudioStreamPlayer2D:
	for voice in _voices:
		if not voice.playing:
			return voice
	var voice := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	return voice
#endregion


#region 后续表现接口
## 这些是同步直调接口；下一步实现只操作接触刚体，不做全屏闪光。
func _flash_contact(_event: Dictionary, _context: Dictionary) -> void:
	pass


## 后续实现要求总冲量与动能同时过高门槛，再按镜头距离衰减。
func _request_camera_shake(_event: Dictionary, _context: Dictionary) -> void:
	pass


func _emit_particles(_event: Dictionary, _context: Dictionary) -> void:
	pass
#endregion


#region 冷却与兜底音源
func _pair_key(a, b) -> String:
	var a_id: int = int(a.id) if a != null else -1
	var b_id: int = int(b.id) if b != null else -1
	return "%d:%d" % [mini(a_id, b_id), maxi(a_id, b_id)]


func _on_cooldown(pair: String, now_ms: int) -> bool:
	return now_ms - int(_last_pair_time_ms.get(pair, -1000000)) \
		< roundi(pair_cooldown_seconds * 1000.0)


func _prune_pair_history(now_ms: int) -> void:
	var keep_ms := maxi(roundi(pair_cooldown_seconds * 2000.0), 1000)
	for key in _last_pair_time_ms.keys():
		if now_ms - int(_last_pair_time_ms[key]) > keep_ms:
			_last_pair_time_ms.erase(key)


func _total_impulse(points: Array) -> float:
	var total := 0.0
	for point in points:
		total += maxf(float(point.get("impulse", 0.0)), 0.0)
	return total


func _build_impact_stream() -> AudioStreamWAV:
	const MIX_RATE := 44100
	var duration := maxf(sound_duration, 0.02)
	var sample_count := maxi(1, roundi(duration * MIX_RATE))
	var data := PackedByteArray()
	data.resize(sample_count * 2)
	var noise_state := 17321
	for i in sample_count:
		var time := float(i) / MIX_RATE
		var progress := time / duration
		var envelope := pow(1.0 - progress, 3.0)
		noise_state = (noise_state * 1103515245 + 12345) & 0x7fffffff
		var noise := float(noise_state & 0xffff) / 32767.5 - 1.0
		var thud := sin(TAU * lerpf(155.0, 72.0, progress) * time)
		var sample := clampf((thud * 0.72 * envelope + noise * 0.28 \
			* pow(1.0 - progress, 10.0)) * 0.9, -1.0, 1.0)
		var value := clampi(roundi(sample * 32767.0), -32768, 32767)
		data.encode_s16(i * 2, value)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.data = data
	return stream
#endregion
