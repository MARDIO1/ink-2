extends Sprite2D
## 生成稿的同一纸条外框，内部血量由着色器实时绘制。
const SOURCE := "res://actor/monster/health_bar_concept.png"
const BAR_SHADER := preload("res://actor/monster/health_bar.gdshader")
static var _atlas: AtlasTexture
var _material: ShaderMaterial

func _ready() -> void:
	if _atlas == null:
		var source := load(SOURCE) as Texture2D
		_atlas = AtlasTexture.new()
		_atlas.atlas = source
		_atlas.region = Rect2(120, 260, 1930, 210)
	texture = _atlas
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_material = ShaderMaterial.new()
	_material.shader = BAR_SHADER
	material = _material
	z_index = 4095
	z_as_relative = false

func update_health(current: float, maximum: float, width: float) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("health_ratio", clampf(current / maxf(maximum, 1.0), 0.0, 1.0))
	global_rotation = 0.0
	global_scale = Vector2(width / 1930.0, 10.0 / 210.0)
	visible = current > 0.0
