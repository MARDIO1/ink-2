extends CanvasLayer
## 调试值来自执行器；不把重力、摩擦等外力计入主动功率。
@onready var hand = $"../Player/Arm/Hand/HandControl"
@onready var feet = $"../Player/PlayerInput"
@onready var world = $".."
@onready var label: Label = $Stats
var elapsed: float = 0.0

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed < 0.1:
		return
	elapsed = 0.0
	label.text = "FPS %d | CPU %.1f ms | 子步 %d\n手功率 %.1f / %.1f M | 力 %.2f / %.2f M\n脚功率 %.1f / %.1f M | 力 %.2f M" % [
		Engine.get_frames_per_second(), Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		world.world.last_substeps, hand.debug_active_power / 1e6, hand.max_power / 1e6,
		hand.debug_linear_effort / 1e6, hand.max_force / 1e6,
		feet.debug_active_power / 1e6, feet.max_power / 1e6, feet.debug_force / 1e6]
