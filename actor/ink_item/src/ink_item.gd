#地图里的墨水物品：就是引擎的 PixelBody2D，从 .tscn 加载出来就是一个静态/动态刚体。
#唯一的额外工作——像素里已经有钉子，但锚点标签和可见外观看不出来，烘焙时按自己的像素补一遍。

#region 依赖
@tool
extends "res://addons/pixel_destruction/nodes/pixel_body_2d.gd"

const InkPalette := preload("res://Ink/src/ink_palette.gd")
const ANCHOR_TAG := "static_anchor_points"
const Nail := preload("res://actor/nail/src/nail.gd")
#endregion

## 关卡文件里的墨水实体默认属于地图编辑器预置内容，其钉子仅供编辑时查看。
## 游玩过程中由 CanvasSolid 新建的实体会显式将此值设为 false。
@export var hide_nails_in_play := true


#region 装载
#⚠️ 不能挂在 _bake_lazily 上：PixelWorld.rebuild() 走的是 bake_node() → bake()，
#   不经过"按需烘焙"那个钩子。所以延迟一帧，等世界把刚体和形状都装好再补锚点。
func _ready() -> void:
	_restore_nails.call_deferred()


#把材质 4 的像素认成锚点：打标签给破坏管线，并补上可见的钉子外观。
func _restore_nails() -> void:
	if not is_inside_tree():
		return
	var body = self.body          # 读 body 会幂等触发烘焙
	if body == null or not body.is_static:
		return
	var points: Dictionary = {}
	for shape in body.shapes:
		var rect: Rect2i = shape.local_aabb()
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				if shape.get_pixel(x, y) == InkPalette.nail_material_id():
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
		nail.setup(body, point, hide_nails_in_play)
#endregion
