#钉子外观层：编辑时把画布上的每个钉子像素画成一枚钉子贴图，画在墨水之上。
#钉子数据只此一份；CanvasSurface 落笔/擦除/清空时调用 add/remove/clear。

#region 依赖
@tool
extends Node2D

const Nail := preload("res://actor/nail/src/nail.gd")
const NAIL_TEXTURE := Nail.NAIL_TEXTURE
const BACKGROUND_TEXTURE := Nail.BACKGROUND_TEXTURE
const INFINITE_TEXTURE := Nail.INFINITE_TEXTURE
const ANCHOR_CENTER := Nail.ANCHOR_CENTER
#endregion


#region 数据
## 钉子像素 -> true。
var nails := {}
var background_nails := {}
var infinite_nails := {}


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func add(pixel: Vector2i, kind: Nail.Kind = Nail.Kind.FIXED) -> bool:
	if nails.has(pixel) or background_nails.has(pixel) or infinite_nails.has(pixel):
		return false
	if kind == Nail.Kind.BACKGROUND:
		background_nails[pixel] = true
	elif kind == Nail.Kind.INFINITE:
		infinite_nails[pixel] = true
	else:
		nails[pixel] = true
	queue_redraw()
	return true


func remove(pixel: Vector2i) -> int:
	var kind := -1
	if nails.erase(pixel):
		kind = Nail.Kind.FIXED
	elif background_nails.erase(pixel):
		kind = Nail.Kind.BACKGROUND
	elif infinite_nails.erase(pixel):
		kind = Nail.Kind.INFINITE
	if kind >= 0:
		queue_redraw()
	return kind


func kind_at(pixel: Vector2i) -> int:
	if nails.has(pixel):
		return Nail.Kind.FIXED
	if background_nails.has(pixel):
		return Nail.Kind.BACKGROUND
	if infinite_nails.has(pixel):
		return Nail.Kind.INFINITE
	return -1


func snapshot() -> Dictionary:
	return {"fixed": nails.duplicate(), "background": background_nails.duplicate(),
		"infinite": infinite_nails.duplicate()}


func restore(state: Dictionary) -> void:
	nails = state.get("fixed", {}).duplicate()
	background_nails = state.get("background", {}).duplicate()
	infinite_nails = state.get("infinite", {}).duplicate()
	queue_redraw()


func clear() -> void:
	if nails.is_empty() and background_nails.is_empty() and infinite_nails.is_empty():
		return
	nails.clear()
	background_nails.clear()
	infinite_nails.clear()
	queue_redraw()
#endregion


#region 绘制
func _draw() -> void:
	for pixel: Vector2i in nails:
		#贴图的固定点对准该画布像素的中心，钉子就长在它钉的那个像素上。
		draw_texture_rect(NAIL_TEXTURE, Nail.visual_rect(pixel), false)
	for pixel: Vector2i in background_nails:
		draw_texture_rect(BACKGROUND_TEXTURE,
			Nail.visual_rect(pixel, Nail.Kind.BACKGROUND), false)
	for pixel: Vector2i in infinite_nails:
		draw_texture_rect(INFINITE_TEXTURE,
			Nail.visual_rect(pixel, Nail.Kind.INFINITE), false)
#endregion
