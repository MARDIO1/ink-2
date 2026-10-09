extends Node

@export_range(1.0, 6.0, 0.1) var period := 2.6
@export_range(0.0, 0.2, 0.005) var horizontal_amplitude := 0.08
@export_range(0.0, 0.2, 0.005) var vertical_amplitude := 0.11
@export var skeleton_path := NodePath("../Skeleton2D")
@export var targets_path := NodePath("../Targets")

var _elapsed := 0.0
var _skeleton: Node2D
var _targets: Node2D
var _skeleton_scale := Vector2.ONE
var _targets_scale := Vector2.ONE
var _targets_position := Vector2.ZERO


func _ready() -> void:
	process_priority = -10
	if "--validate-rig" in OS.get_cmdline_user_args():
		set_process(false)
		return
	_skeleton = get_node_or_null(skeleton_path) as Node2D
	_targets = get_node_or_null(targets_path) as Node2D
	if _skeleton == null:
		set_process(false)
		return
	_skeleton_scale = _skeleton.scale
	if _targets != null:
		_targets_scale = _targets.scale
		_targets_position = _targets.position


func _process(delta: float) -> void:
	_elapsed = fmod(_elapsed + delta, period)
	var pulse := sin(_elapsed * TAU / maxf(period, 0.01))
	var factor := Vector2(
		1.0 + pulse * horizontal_amplitude,
		1.0 + pulse * vertical_amplitude
	)
	_skeleton.scale = _skeleton_scale * factor
	if _targets != null:
		var pivot := _skeleton.position
		_targets.position = pivot + (_targets_position - pivot) * factor
		_targets.scale = _targets_scale * factor
