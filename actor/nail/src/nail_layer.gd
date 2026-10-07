#钉子外观层：编辑时把画布上的每个钉子像素画成一枚钉子贴图，画在墨水之上。
#钉子数据只此一份；CanvasSurface 落笔/擦除/清空时调用 add/remove/clear。

#region 依赖
@tool
extends Node2D

const NAIL_TEXTURE := preload("res://actor/nail/asset/nail.png")
## 贴图里充当固定点的像素中心；7x13 的 (3, 6)。
const ANCHOR_CENTER := Vector2(3.5, 6.5)
#endregion


#region 数据
## 钉子像素 -> true。
var nails := {}


func add(pixel: Vector2i) -> void:
	nails[pixel] = true
	queue_redraw()


func remove(pixel: Vector2i) -> void:
	if nails.erase(pixel):
		queue_redraw()


func clear() -> void:
	if nails.is_empty():
		return
	nails.clear()
	queue_redraw()
#endregion


#region 绘制
func _draw() -> void:
	for pixel: Vector2i in nails:
		#贴图的固定点对准该画布像素的中心，钉子就长在它钉的那个像素上。
		draw_texture(NAIL_TEXTURE, Vector2(pixel) + Vector2(0.5, 0.5) - ANCHOR_CENTER)
#endregion
