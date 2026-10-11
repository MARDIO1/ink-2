class_name ImpactSoundProfile
extends Resource
## 音源表的一行；材质 0 是通配符，材质对不区分先后顺序。

@export var material_a: int = 0
@export var material_b: int = 0
@export var light: Array[AudioStream] = []
@export var medium: Array[AudioStream] = []
@export var heavy: Array[AudioStream] = []
@export_range(-24.0, 12.0, 0.5) var volume_db: float = 0.0
@export_range(0.5, 2.0, 0.01) var pitch_scale: float = 1.0


func match_score(a: int, b: int) -> int:
	var direct := _side_matches(material_a, a) and _side_matches(material_b, b)
	var reverse := _side_matches(material_a, b) and _side_matches(material_b, a)
	if not direct and not reverse:
		return -1
	return int(material_a != 0) + int(material_b != 0)


func pick_stream(intensity: float) -> AudioStream:
	var choices: Array[AudioStream] = light if intensity < 0.34 else (medium if intensity < 0.72 else heavy)
	if choices.is_empty():
		choices = medium if not medium.is_empty() else (light if not light.is_empty() else heavy)
	return null if choices.is_empty() else choices[randi() % choices.size()]


func _side_matches(expected: int, actual: int) -> bool:
	return expected == 0 or expected == actual
