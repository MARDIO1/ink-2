extends Control
## 黑墨保留在瓶身；灰、红、黄、白、蓝墨使用纯色色段，连续堆叠在横条右侧。
## 顺序跟随 `InkPalette.INKS`（去掉黑墨），改色表不需要同步这里。

const InkPalette := preload("res://ink/general/src/ink_palette.gd")
const MATERIALS := [InkPalette.GREY, InkPalette.RED, InkPalette.YELLOW, InkPalette.WHITE, InkPalette.BLUE]
const EMPTY_COLOR := Color(0.76, 0.75, 0.70, 0.62)

var ratios := PackedFloat32Array([1.0, 1.0, 1.0, 1.0, 1.0])
var remaining := PackedInt32Array([20000, 20000, 20000, 20000, 20000])


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func set_health(health: Node) -> void:
	for index in MATERIALS.size():
		var material_id: int = MATERIALS[index].id
		if health == null:
			ratios[index] = 1.0
			remaining[index] = 20000
		else:
			ratios[index] = clampf(health.ratio_of(material_id), 0.0, 1.0)
			remaining[index] = maxi(0, roundi(health.ink_of(material_id)))
	queue_redraw()


## 每种墨水的满量仍占总宽的等分之一；从左往右连续堆叠，缺墨留下的空位集中在右端 ——
## 这样彩色段始终贴着画框左内沿，墨水变少时不会整体被推向右边。
func segment_rects() -> Array[Rect2]:
	var result: Array[Rect2] = []
	var width: float = size.x / float(MATERIALS.size())
	var x := 0.0
	for ratio in ratios:
		var amount_width: float = width * ratio
		result.append(Rect2(Vector2(x, 0.0), Vector2(amount_width, size.y)))
		x += amount_width
	return result


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	draw_rect(Rect2(Vector2.ZERO, size), EMPTY_COLOR)
	var segments := segment_rects()
	for index in MATERIALS.size():
		if not segments[index].has_area():
			continue
		draw_rect(segments[index], MATERIALS[index].color)
