extends Node2D
## 按当前选色落一整块墨水轮廓；轴心只记进 `gear_centers`，固化时再按中心格找轮体建铰链。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const History := preload("res://actor/canvas/src/canvas_history.gd")
const MIN_RADIUS := 12.0
const DEFAULT_TEETH := 12
var teeth := DEFAULT_TEETH
var dragging := false
var center := Vector2.ZERO
var radius := 0.0
var polygon := PackedVector2Array()
## 落笔用的墨水材质；整个齿轮都是这一种颜色。
var ink_material: int = Palette.GREY.id

static func outline(reach: float, tooth_count := DEFAULT_TEETH) -> PackedVector2Array:
	var points := PackedVector2Array()
	# 宽齿根与平齿顶适合像素碰撞；拖动距离定义齿尖外半径。
	for tooth in tooth_count:
		for entry in [[-0.5, 0.78], [-0.28, 0.78], [-0.18, 1.0], [0.18, 1.0], [0.28, 0.78]]:
			var angle: float = (float(tooth) + entry[0]) * TAU / tooth_count
			points.append(Vector2.from_angle(angle) * reach * entry[1])
	return points

func begin(point: Vector2, tooth_count := DEFAULT_TEETH) -> void:
	if not get_parent().get_parent()._map_editor_mode:
		return
	dragging = true
	ink_material = get_parent().ink_material_id()
	teeth = 8 if tooth_count == 8 else DEFAULT_TEETH
	center = point.floor() + Vector2.ONE * 0.5
	update_preview(point)

func update_preview(point: Vector2) -> void:
	var size: Vector2 = Vector2(get_parent().canvas_size)
	var available := minf(minf(center.x, center.y), minf(size.x - center.x, size.y - center.y))
	radius = minf(center.distance_to(point), maxf(0.0, available - 0.5))
	polygon = outline(radius, teeth)
	position = center
	queue_redraw()

func cancel() -> void:
	dragging = false
	polygon.clear()
	queue_redraw()

func _draw() -> void:
	if not dragging or polygon.is_empty():
		return
	var color: Color = Palette.color_for_material_id(ink_material)
	color.a = 0.65
	draw_colored_polygon(polygon, color)
	var border := polygon.duplicate()
	border.append(polygon[0])
	draw_polyline(border, Color(0.95, 0.72, 0.08), 1.0)
	# 中心只留一个十字准星；预览里也不画黄点，避免和落笔结果不一致。
	draw_line(Vector2(-6, 0), Vector2(6, 0), Color.BLACK)
	draw_line(Vector2(0, -6), Vector2(0, 6), Color.BLACK)

func finish(point: Vector2):
	if not dragging:
		return null
	update_preview(point)
	dragging = false
	queue_redraw()
	var surface = get_parent()
	var canvas = surface.get_parent()
	if not canvas._map_editor_mode or radius < MIN_RADIUS:
		return null
	var cells := _outline_cells()
	if _covers_nail(cells):
		return null
	var state: Dictionary = History.capture(canvas)
	var color: Color = Palette.color_for_material_id(ink_material)
	for at: Vector2i in cells:
		surface._set_pixel_raw(at, color)
	# 齿轮就是一整块普通墨水：中心不再画黄色轴点，轴心只记在 gear_centers 里，
	# 固化时 create_axles 按中心格的实际墨水找轮体。
	if not surface.gear_centers.has(center):
		surface.gear_centers.append(center)
	surface._flush_texture()
	surface._flush_ink()
	History.commit(canvas, state)
	polygon.clear()
	return surface

func _outline_cells() -> Dictionary:
	var surface = get_parent()
	var extent := ceili(radius)
	var origin := Vector2i(center.floor()) - Vector2i(extent, extent)
	var cells: Dictionary = {}
	for j in range(-extent, extent + 1):
		for i in range(-extent, extent + 1):
			if not Geometry2D.is_point_in_polygon(Vector2(i, j), polygon):
				continue
			var at := origin + Vector2i(i + extent, j + extent)
			if surface._inside(Vector2(at)):
				cells[at] = true
	return cells


func _covers_nail(cells: Dictionary) -> bool:
	var surface = get_parent()
	var nail := Palette.nail_material_id()
	for at: Vector2i in cells:
		if surface.material_at(at.x, at.y) == nail:
			return true
	return false
