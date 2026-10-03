#画布上层：状态机 + 键盘胶水，把 CanvasSurface 的绘制和 CanvasSolid 的固化串起来
#当前只有 DRAWING 一个状态：按 Space 固化，但仍停留在 DRAWING

#region 依赖
extends Node2D

@onready var surface = $CanvasSurface
@onready var solid = $CanvasSolid
#endregion


#region 状态机
enum State { DRAWING }

var state := State.DRAWING
#endregion


#region 初始化
#门面世界暂时由 main2 的根节点提供
var physics = null

func _ready() -> void:
	physics = get_parent()
#endregion


#region 输入
#只处理固化按键，绘制/擦除输入由 CanvasSurface 自己消费
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			solid.solidify(surface, physics)
#endregion
