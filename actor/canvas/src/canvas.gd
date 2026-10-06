#region 依赖
@tool
extends Node2D

@onready var surface = $CanvasSurface
@onready var solid = $CanvasSolid
@onready var world = $".."
#endregion


#region 画布范围
## 画布宽高，单位 px；同时决定编辑器可见范围和墨水贴图分辨率。
@export var canvas_size := Vector2i(256, 256):
	set(value):
		canvas_size = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
		if is_node_ready():
			surface.canvas_size = canvas_size


func _ready() -> void:
	surface.canvas_size = canvas_size
#endregion


#region 固化输入
## 开发复现文件留在 test，保存内容仍是未固化墨水。
@export var capture_path: String = "res://test/canvas_capture.tres"

func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E:
		solid.solidify(surface, world)
	elif event.is_action_pressed("canvas_save"):
		surface.save_ink(capture_path)
	elif event.is_action_pressed("canvas_load"):
		surface.load_ink(capture_path)
#endregion
