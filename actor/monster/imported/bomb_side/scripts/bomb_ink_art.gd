@tool
extends Sprite2D
## 持握时的红墨轮廓预览；投出后以同一轮廓固化进 PixelWorld。
const Palette := preload("res://ink/general/src/ink_palette.gd")
static var _textures: Dictionary = {}


func _ready() -> void:
	if texture == null:
		return
	var key := str(texture.get_instance_id()) + str(Palette.RED.color)
	if not _textures.has(key):
		var image := texture.get_image()
		image.convert(Image.FORMAT_RGBA8)
		var data := image.get_data()
		var color := Palette.RED.color
		for index in range(0, data.size(), 4):
			var solid := data[index + 3] > 127
			data[index] = roundi(color.r * 255.0) if solid else 0
			data[index + 1] = roundi(color.g * 255.0) if solid else 0
			data[index + 2] = roundi(color.b * 255.0) if solid else 0
			data[index + 3] = 255 if solid else 0
		_textures[key] = ImageTexture.create_from_image(Image.create_from_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, data))
	texture = _textures[key]
	set_meta(&"ink_material_id", Palette.RED.id)
