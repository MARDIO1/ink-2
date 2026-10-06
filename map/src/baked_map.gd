@tool
extends "res://addons/pixel_destruction/nodes/pixel_body_2d.gd"

## Canvas 保存的大地图 PNG；透明处为空，非透明处使用 material_id。
@export_file("*.png") var map_path := "res://map/asset/baked_map.png":
	set(value):
		map_path = value
		_load_map()


func _ready() -> void:
	_load_map()


func _load_map() -> void:
	if not is_node_ready() or not ResourceLoader.exists(map_path):
		return
	var map_texture := load(map_path) as Texture2D
	if map_texture == null:
		return
	source = Source.TEXTURE
	texture = map_texture
	$Preview.texture = map_texture
