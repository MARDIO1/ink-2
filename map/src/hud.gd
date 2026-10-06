extends CanvasLayer
## 调试值来自执行器；不把重力、摩擦等外力计入主动功率。
@onready var hand = $"../Player/Arm/Hand/HandControl"
@onready var feet = $"../Player/PlayerInput"
@onready var world = $".."
@onready var label: Label = $Stats
@onready var forces = $ForceDebug
## 1% low 帧率的滚动采样窗口，单位秒；增大后统计更平稳、响应更慢。
@export var low_window: float = 10.0
var elapsed: float = 0.5
var frame_times: PackedFloat64Array = PackedFloat64Array()
var first: int = 0
var history_time: float = 0.0
var previous_tick: int = 0


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug"):
		visible = not visible
		forces.enabled = visible
		forces.queue_redraw()

func _process(delta: float) -> void:
	# 用墙钟间隔统计卡顿，不受游戏时间缩放影响；队列游标避免每帧搬移数组。
	var tick: int = Time.get_ticks_usec()
	if previous_tick > 0:
		var duration: float = (tick - previous_tick) / 1e6
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
