extends RefCounted
## 地图图片的**文档操作**：恢复（撤销删除用）、枚举、拾取、选中显示。
##
## 导入窗口与 GIF 解码仍在各自的编辑器路径；这里只处理场景里的图片节点。

const ImportedImageScript := preload("res://map/src/map_imported_image.gd")


## 仅供撤销旧地图图片删除使用；不再提供导入或新放置入口。
## 图片纹理加载失败时返回 null（节点已回收），调用方据此判定失败。
static func restore(container, world_position: Vector2, source_data: PackedByteArray,
		source_format: String, filename: String, image_scale: Vector2) -> Sprite2D:
	if container == null or source_data.is_empty():
		return null
	var image := ImportedImageScript.new() as Sprite2D
	image.name = "ImportedImage"
	image.source_data = source_data
	image.source_format = source_format
	image.original_filename = filename
	container.add_child(image, true)
	if image.texture == null:
		container.remove_child(image)
		image.queue_free()
		return null
	image.global_position = world_position
	image.scale = image_scale
	return image


static func images_in(container) -> Array:
	return container.get_children() if container != null else []


## 从后往前找：后放的在上层；先判缩放手柄再判本体。
static func find_at(container, world_position: Vector2, radius: float) -> Sprite2D:
	var images := images_in(container)
	for index in range(images.size() - 1, -1, -1):
		var image = images[index]
		if image is Sprite2D and (image.resize_handle_hit(world_position)
			or image.contains_world_point(world_position, radius)):
			return image
	return null


## 选中态是图片自己的显示属性；传 null 清空。
static func set_selection(container, target) -> void:
	for image in images_in(container):
		image.editor_selected = image == target
