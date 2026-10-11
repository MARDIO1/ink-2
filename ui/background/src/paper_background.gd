extends CanvasLayer
## 无限纸背景：在屏幕最底层铺一张横格纸，纸纹随玩家相机在世界里无限平铺，
## 并按屏幕方向做左亮右暗渐变。挂在 root.tscn 的 Level 旁，关卡切换不释放。
##
## 坐标换算在 paper_background.gdshader 里完成；本脚本只负责每帧把
## 当前活动相机的世界坐标和视口尺寸喂给 shader 材质。

@onready var _rect: ColorRect = $ColorRect
var _mat: ShaderMaterial


func _ready() -> void:
	_mat = _rect.material as ShaderMaterial


func _process(_delta: float) -> void:
	if _mat == null:
		return
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		return
	_mat.set_shader_parameter("world_camera_pos", cam.global_position)
	_mat.set_shader_parameter("viewport_size", get_viewport().get_visible_rect().size)
