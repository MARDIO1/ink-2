#把世界里的墨水物品导成一个 .tscn 节点树。
#每个物品一个 InkItem（PixelBody2D）+ 若干 PixelShape2D(source=PAINT)，像素图内嵌在场景里。

#region 依赖
extends RefCounted

const PixelShape2D := preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
const InkItem := preload("res://map/src/ink_item.gd")
const MapRoot := preload("res://map/src/map_root.gd")
## 墨水物品所在的组；CanvasSolid 固化时会加，导出时按它找。
const INK_GROUP := "ink_item"
#endregion


#region 导出
## 把场景树里所有墨水物品打包成地图场景写到 path；返回 {saved, count, path, error}。
static func build(tree: SceneTree, path: String) -> Dictionary:
	var root := MapRoot.new()
	root.name = "Map"
	var count := 0
	for node in tree.get_nodes_in_group(INK_GROUP):
		var body = node.get("body")
		if body == null:
			continue
		_append(root, body)
		count += 1
	if count == 0:
		root.free()
		return {"saved": false, "count": 0, "path": path, "error": ERR_DOES_NOT_EXIST}
	var scene := PackedScene.new()
	var error: Error = scene.pack(root)
	if error == OK:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
		error = ResourceSaver.save(scene, path)
	root.free()
	return {"saved": error == OK, "count": count, "path": path, "error": error}
#endregion


#region 组装
#把一个刚体拆成：InkItem 根 + 每个形状一个 PixelShape2D（材质图按形状包围盒裁切）。
static func _append(root: Node2D, body) -> void:
	var item := InkItem.new()
	item.name = "Ink%d" % root.get_child_count()
	item.position = body.position
	item.rotation = body.rotation
	item.is_static = body.is_static
	item.add_to_group(INK_GROUP, true)   # persistent：读回来还能再导出
	root.add_child(item)
	item.owner = root
	var index := 0
	for shape in body.shapes:
		var rect: Rect2i = shape.local_aabb()
		if rect.size.x <= 0 or rect.size.y <= 0:
			continue
		var shape_node := PixelShape2D.new()
		shape_node.name = "Shape%d" % index
		index += 1
		shape_node.position = Vector2(rect.position)
		shape_node.source = PixelShape2D.Source.PAINT
		shape_node.paint = _material_image(shape, rect)
		item.add_child(shape_node)
		shape_node.owner = root


#把形状的一段像素抽成 R8 材质图，R 通道 = 材质 id。
static func _material_image(shape, rect: Rect2i) -> Image:
	var image := Image.create_empty(rect.size.x, rect.size.y, false, Image.FORMAT_R8)
	for y in range(rect.size.y):
		for x in range(rect.size.x):
			var material: int = shape.get_pixel(rect.position.x + x, rect.position.y + y)
			if material != 0:
				image.set_pixel(x, y, Color8(material, 0, 0, 255))
	return image
#endregion
