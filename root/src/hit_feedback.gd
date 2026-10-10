extends Node
## 统一打击反馈入口。当前只播放碰撞音效；粒子、闪光和抖屏以后继续放在这里，
## 不让伤害规则或具体 Actor 持有表现节点。

#region 音效参数
## 低于该接近速度的接触视为挤压/静置，不播放撞击声。
@export var minimum_approach: float = 300.0
## 总冲量低于此值时不播放，避免微小碎片持续沙沙响。
@export var minimum_impulse: float = 120.0
## 达到该冲量时取最大音量；中间使用对数曲线。
@export var full_volume_impulse: float = 24000.0
@export_range(-80.0, 0.0, 0.5) var minimum_volume_db: float = -28.0
@export_range(-20.0, 6.0, 0.5) var maximum_volume_db: float = -2.0
## 同一对刚体在多个物理子步持续接触时，只响一次。
@export_range(0.0, 0.5, 0.01) var pair_cooldown_seconds: float = 0.08
@export_range(1, 16, 1) var voice_count: int = 6
@export_range(0.0, 0.25, 0.005) var sound_duration: float = 0.075
@export var audio_bus: StringName = &"Master"
#endregion


#region 状态
var _voices: Array[AudioStreamPlayer] = []
var _next_voice: int = 0
var _last_pair_time_ms: Dictionary = {}
var _impact_stream: AudioStreamWAV
#endregion


func _ready() -> void:
	_impact_stream = _build_impact_stream()
	for i in voice_count:
		var voice := AudioStreamPlayer.new()
		voice.name = "ImpactVoice%d" % i
		voice.stream = _impact_stream
		voice.bus = audio_bus
		add_child(voice)
		_voices.append(voice)


## SimulationRuntime 会在每个物理子步明确调用本接口；返回空效果包，不修改物理结果。
func resolve_contacts(_context: Dictionary, contacts: Array) -> Dictionary:
	var now_ms: int = Time.get_ticks_msec()
	var candidates: Array[Dictionary] = []
	for contact in contacts:
		if float(contact.approach) < minimum_approach:
			continue
		var total_impulse := _total_impulse(contact.points)
		if total_impulse < minimum_impulse:
			continue
		var pair_key := _pair_key(contact.a, contact.b)
		var previous_ms: int = int(_last_pair_time_ms.get(pair_key, -1000000))
		if now_ms - previous_ms < roundi(pair_cooldown_seconds * 1000.0):
			continue
		candidates.append({"pair": pair_key, "impulse": total_impulse})
	# 同一子步只保留最强的有限几次碰撞，避免碎裂瞬间把声道全部塞满。
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.impulse) > float(b.impulse))
	var play_count: int = mini(candidates.size(), voice_count)
	for i in play_count:
		var candidate: Dictionary = candidates[i]
		_last_pair_time_ms[candidate.pair] = now_ms
		_play_impulse(float(candidate.impulse))
	if _last_pair_time_ms.size() > 256:
		_prune_pair_history(now_ms)
	return {}


## 对数曲线更接近人耳响度：小冲量仍听得见，大冲量逐渐趋近上限而不会炸音。
func intensity_for_impulse(impulse: float) -> float:
	if impulse <= minimum_impulse:
		return 0.0
	var span: float = maxf(full_volume_impulse - minimum_impulse, 0.001)
	var normalized: float = clampf((impulse - minimum_impulse) / span, 0.0, 1.0)
	return log(1.0 + normalized * 15.0) / log(16.0)


func volume_db_for_impulse(impulse: float) -> float:
	return lerpf(minimum_volume_db, maximum_volume_db, intensity_for_impulse(impulse))


func _play_impulse(impulse: float) -> void:
	if _voices.is_empty():
		return
	var voice := _take_voice()
	var intensity := intensity_for_impulse(impulse)
	voice.volume_db = volume_db_for_impulse(impulse)
	# 轻碰略尖、重击略沉；微小随机量避免连续撞击完全像复制粘贴。
	voice.pitch_scale = lerpf(1.12, 0.88, intensity) * randf_range(0.96, 1.04)
	voice.play()


func _take_voice() -> AudioStreamPlayer:
	for voice in _voices:
		if not voice.playing:
			return voice
	var voice: AudioStreamPlayer = _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	return voice


func _total_impulse(points: Array) -> float:
	var total: float = 0.0
	for point in points:
		total += maxf(float(point.get("impulse", 0.0)), 0.0)
	return total


func _pair_key(a, b) -> String:
	var a_id: int = int(a.id) if a != null else -1
	var b_id: int = int(b.id) if b != null else -1
	return "%d:%d" % [mini(a_id, b_id), maxi(a_id, b_id)]


func _prune_pair_history(now_ms: int) -> void:
	var keep_ms: int = maxi(roundi(pair_cooldown_seconds * 2000.0), 1000)
	for key in _last_pair_time_ms.keys():
		if now_ms - int(_last_pair_time_ms[key]) > keep_ms:
			_last_pair_time_ms.erase(key)


## 生成无外部版权依赖的短促“墨块撞击”声：低频下坠 + 高频噪声，统一交给音量映射。
func _build_impact_stream() -> AudioStreamWAV:
	const MIX_RATE := 44100
	var duration: float = maxf(sound_duration, 0.02)
	var sample_count: int = maxi(1, roundi(duration * MIX_RATE))
	var data := PackedByteArray()
	data.resize(sample_count * 2)
	var noise_state: int = 17321
	for i in sample_count:
		var time: float = float(i) / MIX_RATE
		var progress: float = time / duration
		var envelope: float = pow(1.0 - progress, 3.0)
		noise_state = (noise_state * 1103515245 + 12345) & 0x7fffffff
		var noise: float = float(noise_state & 0xffff) / 32767.5 - 1.0
		var thud: float = sin(TAU * lerpf(155.0, 72.0, progress) * time)
		var click_envelope: float = pow(1.0 - progress, 10.0)
		var sample: float = clampf((thud * 0.72 * envelope + noise * 0.28 * click_envelope) * 0.9, -1.0, 1.0)
		var value: int = clampi(roundi(sample * 32767.0), -32768, 32767)
		data[i * 2] = value & 0xff
		data[i * 2 + 1] = (value >> 8) & 0xff
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.data = data
	return stream
