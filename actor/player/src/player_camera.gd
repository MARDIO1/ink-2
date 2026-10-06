#region 依赖
extends Camera2D

## 跟随目标节点；相机读取其 PBody 质心
@export var player_path := NodePath("../Player")

var player_body = null
#endregion


#region 初始化
func _ready() -> void:
	# PixelWorld 在优先级 10 推进；相机随后读取最终物理位置供本帧渲染。
	process_physics_priority = 20
	position = Vector2(-116.0, 212.0)
#endregion


#region 物理跟随
func _physics_process(_delta: float) -> void:
	if player_body == null:
		var player_node := get_node_or_null(player_path)
		if player_node != null:
			player_body = player_node.get("body")
	if player_body != null:
		global_position = player_body.com_world()
#endregion
