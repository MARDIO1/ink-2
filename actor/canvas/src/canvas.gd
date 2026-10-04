#region 依赖
@tool
extends Node2D

@onready var surface = $CanvasSurface
@onready var solid = $CanvasSolid
@onready var world = $".."
#endregion


#region 画布范围
@export var canvas_size := Vector2i(256, 256):
	set(value):
		canvas_size = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
		if is_node_ready():
			surface.canvas_size = canvas_size


func _ready() -> void:
	surface.canvas_size = canvas_size
#endregion


#region 固化输入
func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E:
		solid.solidify(surface, world)
#endregion
