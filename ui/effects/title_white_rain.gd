@tool
extends Sprite2D
## 扉页白墨仅作视觉贴图；原始 Red8 画稿被着色器当作遮罩读取。

@export var paint: Image


func _ready() -> void:
	centered = false
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if paint != null and not paint.is_empty():
		texture = ImageTexture.create_from_image(paint)
	var shader_material := ShaderMaterial.new()
	shader_material.shader = preload("res://ui/effects/title_white_rain.gdshader")
	material = shader_material
