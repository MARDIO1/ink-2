#region 依赖
extends Camera2D

## 跟随目标节点；相机读取其 PBody 质心
@export var player_path := NodePath("../Player")
const PixelScale := preload("res://addons/pixel_destruction/core/pixel_scale.gd")
## 游玩时靠近画布轻微放大；不改变画布尺寸或编辑器视图。
@export_range(1.0, 1.5, 0.01) var canvas_zoom_multiplier := 1.15
@export var canvas_zoom_response := 6.0
var _canvas_zoom_weight := 0.0

var player_body = null
#endregion


#region 初始化
func _ready() -> void:
	# PixelWorld 在优先级 10 推进；相机随后读取最终物理位置供本帧渲染。
	process_physics_priority = 20
#endregion


#region 物理跟随
func _physics_process(_delta: float) -> void:
	if player_body == null:
		var player_node := get_node_or_null(player_path)
		if player_node != null:
			player_body = player_node.get("body")
	if player_body != null:
		global_position = player_body.com_world()
	_update_canvas_zoom(_delta)


func _update_canvas_zoom(delta: float) -> void:
	var creative := get_parent().get_node_or_null("Creative")
	var editing: bool = creative != null and creative.get("active") == true
	var near := false
	if not editing:
		for canvas in get_tree().get_nodes_in_group(&"canvas_workbench"):
			if canvas.get_parent() == get_parent() and canvas.is_player_near_workbench():
				near = true
				break
	_canvas_zoom_weight = lerpf(_canvas_zoom_weight, 1.0 if near else 0.0,
		1.0 - exp(-maxf(canvas_zoom_response, 0.0) * maxf(delta, 0.0)))
	if editing:
		_canvas_zoom_weight = 0.0
	var base_zoom := PixelScale.get_scale() * PixelScale.render_scale(self)
	zoom = Vector2.ONE * base_zoom * lerpf(1.0, canvas_zoom_multiplier, _canvas_zoom_weight)
#endregion
