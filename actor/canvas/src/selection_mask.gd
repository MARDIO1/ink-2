extends RefCounted

## 空字典表示沿用矩形范围；圆形只保存边界，避免大选区逐像素建表。
static func contains(mask: Dictionary, point: Vector2i) -> bool:
	if mask.is_empty():
		return true
	var rect: Rect2i = mask.get("circle_rect", Rect2i())
	if not rect.has_point(point):
		return false
	var center := Vector2(rect.position) + Vector2(rect.size) * 0.5
	var radius := float(rect.size.x) * 0.5
	return (Vector2(point) + Vector2.ONE * 0.5).distance_squared_to(center) <= radius * radius
