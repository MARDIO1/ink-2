extends CanvasLayer
## 调试值来自执行器；不把重力、摩擦等外力计入主动功率。
@onready var hand = $"../Player/Arm/Hand/HandControl"
@onready var feet = $"../Player/PlayerInput"
@onready var world = $".."
@onready var label: Label = $Stats
@onready var forces = $ForceDebug
@onready var damage = $"../CollisionDamage"
## 1% low 帧率的滚动采样窗口，单位秒；增大后统计更平稳、响应更慢。
@export var low_window: float = 10.0
var elapsed: float = 0.5
var frame_times: PackedFloat64Array = PackedFloat64Array()
var first: int = 0
var history_time: float = 0.0
var previous_tick: int = 0

#region 低帧记录
## F1 开关；只写低于 24 FPS 的帧，不查询额外接触、不复制像素地图。
var low_log: FileAccess = null
var log_path: String = ""
var log_cost_us: int = 0
var logged_frames: int = 0
## 连续达到该帧耗时时保存现场并退出；用于避免物理追帧把实例拖到无法关闭。
@export var hang_frame_ms: float = 500.0
@export_range(1, 10, 1) var hang_frames: int = 2
var hang_count: int = 0

func _toggle_log() -> void:
	if low_log != null:
		damage.set_profile_enabled(false)
		forces.set_profile_enabled(false)
		low_log.close()
		low_log = null
		print("低帧录制停止：", logged_frames, " 帧，", ProjectSettings.globalize_path(log_path))
	else:
		var stamp: String = Time.get_datetime_string_from_system().replace(":", "-")
		log_path = "res://test/low_frames_%s_%d.jsonl" % [stamp, Time.get_ticks_usec()]
		low_log = FileAccess.open(log_path, FileAccess.WRITE)
		if low_log == null:
			push_error("低帧日志打开失败：%s，错误 %d" % [log_path, FileAccess.get_open_error()])
			return
		logged_frames = 0
		damage.set_profile_enabled(true)
		forces.set_profile_enabled(true)
		print("低帧录制开始：", ProjectSettings.globalize_path(log_path))
	log_cost_us = 0
	previous_tick = Time.get_ticks_usec()
	elapsed = 0.5

func _record_low_frame(tick: int, duration_us: int, physics_profile: Dictionary, force_profile: Dictionary) -> void:
	# 按实际渲染间隔筛选；记录自身开销另列，便于区分日志带来的耗时。
	var game_us: int = duration_us - log_cost_us
	var previous_cost: int = log_cost_us
	log_cost_us = 0
	if duration_us <= 1000000.0 / 24.0:
		return
	var start: int = Time.get_ticks_usec()
	var bodies: Array = []
	for body in world.world.bodies:
		bodies.append({"id": body.id, "position": [body.position.x, body.position.y],
			"rotation": body.rotation, "velocity": [body.linear_velocity.x, body.linear_velocity.y],
			"angular_velocity": body.angular_velocity, "mass": body.mass,
			"rects": body.rects.size(), "shapes": body.shapes.size(), "rects_rev": body.rects_rev,
			"static": body.is_static, "frozen": body.frozen, "awake": body.awake,
			"force": [body.control_force.x + body.accum_force.x, body.control_force.y + body.accum_force.y],
			"torque": body.control_torque + body.accum_torque})
	var joints: Array = []
	for joint in world.world.joints:
		joints.append({"kind": joint.kind, "a": joint.body_a.id if joint.body_a != null else -1,
			"b": joint.body_b.id if joint.body_b != null else -1, "active": joint.active,
			"limits": [joint.min_limit, joint.max_limit] if joint.limits_enabled else []})
	low_log.store_line(JSON.stringify({"tick_us": tick, "frame": Engine.get_process_frames(),
		"fps": 1000000.0 / duration_us, "frame_ms": duration_us / 1000.0,
		"game_ms": game_us / 1000.0, "previous_log_ms": previous_cost / 1000.0,
		"physics_profile": physics_profile, "force_profile": force_profile,
		"last_substeps": world.world.last_substeps, "last_native_command_us": world.world._rp_cmd_us,
		"joints": joints, "bodies": bodies,
		"player_id": hand.player_body.id, "hand_id": hand.body.id,
		"grabbed_id": hand.grabbed_body.id if hand.grabbed_body != null else -1,
		"q": hand.rotate_grip, "target": [hand.target_relative.x, hand.target_relative.y],
		"hand_force": [hand.debug_force_vector.x, hand.debug_force_vector.y],
		"hand_power": hand.debug_active_power, "force_debug": forces.enabled}))
	logged_frames += 1
	log_cost_us = Time.get_ticks_usec() - start

func _exit_tree() -> void:
	if low_log != null:
		low_log.close()
#endregion


func _watch_hang(tick: int, duration_us: int) -> bool:
	if duration_us < int(hang_frame_ms * 1000.0):
		hang_count = 0
		return false
	hang_count += 1
	if hang_count < hang_frames:
		return false
	if low_log != null:
		low_log.close()
	var stamp: String = Time.get_datetime_string_from_system().replace(":", "-")
	log_path = "user://hang_%s.jsonl" % stamp
	low_log = FileAccess.open(log_path, FileAccess.WRITE)
	if low_log != null:
		_record_low_frame(tick, duration_us, damage.take_profile(), forces.take_profile())
		low_log.close()
		low_log = null
	push_error("持续卡顿，现场已保存并自动退出：" + ProjectSettings.globalize_path(log_path))
	get_tree().quit(2)
	return true


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("record_low_frames"):
		_toggle_log()

func _process(delta: float) -> void:
	# 用墙钟间隔统计卡顿，不受游戏时间缩放影响；队列游标避免每帧搬移数组。
	var tick: int = Time.get_ticks_usec()
	if previous_tick > 0:
		var duration_us: int = tick - previous_tick
		if low_log != null:
			_record_low_frame(tick, duration_us, damage.take_profile(), forces.take_profile())
		if _watch_hang(tick, duration_us):
			return
		var duration: float = duration_us / 1e6
		frame_times.append(duration)
		history_time += duration
		while first < frame_times.size() - 1 and history_time - frame_times[first] >= low_window:
			history_time -= frame_times[first]
			first += 1
	previous_tick = tick
	elapsed += delta
	if elapsed < 0.5:
		return
	elapsed = 0.0
	frame_times = frame_times.slice(first)
	first = 0
	if not visible:
		return
	var low: String = "--"
	if frame_times.size() >= 100:
		var sorted: PackedFloat64Array = frame_times.duplicate()
		sorted.sort()
		var count: int = maxi(1, ceili(sorted.size() * 0.01))
		var slow_time: float = 0.0
		for i in range(sorted.size() - count, sorted.size()):
			slow_time += sorted[i]
		low = "%.0f" % (count / slow_time) if slow_time > 0.0 else "--"
	label.text = "FPS %d | 1%% low %s | CPU %.1f ms | 子步 %d\n手功率 %.1f / %.1f M | 力 %.2f / %.2f M\n脚功率 %.1f / %.1f M | 力 %.2f M | Q %s" % [
		Engine.get_frames_per_second(), low, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		world.world.last_substeps, hand.debug_active_power / 1e6, hand.max_power / 1e6,
		hand.debug_linear_effort / 1e6, hand.max_force / 1e6,
		feet.debug_active_power / 1e6, feet.max_power / 1e6, feet.debug_force / 1e6,
		"开" if hand.rotate_grip else "关"]
	if low_log != null:
		label.text += "\nF1 录制中 | 已记录 %d 个低帧" % logged_frames
