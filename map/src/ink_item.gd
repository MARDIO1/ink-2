#地图里的墨水物品：就是引擎的 PixelBody2D，从 .tscn 加载出来就是一个静态/动态刚体。
#唯一的额外工作——像素里已经有钉子，但锚点标签和可见外观看不出来，烘焙时按自己的像素补一遍。

#region 依赖
@tool
extends "res://addons/pixel_destruction/nodes/pixel_body_2d.gd"

const NAIL_MATERIAL_ID := 4
const ANCHOR_TAG := "static_anchor_points"
const Nail := preload("res://actor/nail/src/nail.gd")
#endregion


#region 烘焙
func _bake_lazily():
	var body = super._bake_lazily()
	if body != null and body.is_static:
		_restore_nails(body)
	return body


#把材质 4 的像素认成锚点：打标签给破坏管线，并补上可见的钉子外观。
func _restore_nails(body) -> void:
	var points: Dictionary = {}
	for shape in body.shapes:
		var rect: Rect2i = shape.local_aabb()
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				if shape.get_pixel(x, y) == NAIL_MATERIAL_ID:
					points[Vector2i(x, y)] = true
	if points.is_empty():
		return
	body.tags[ANCHOR_TAG] = points
	#编辑器里只打标签，不生成运行时的钉子外观（否则会写进场景）。
	if Engine.is_editor_hint():
		return
	var host := get_parent()
	if host == null:
		return
	for point: Vector2i in points:
		var nail := Nail.new()
		host.add_child(nail)
		nail.setup(body, point)
#endregion
