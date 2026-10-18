extends Node2D
## 齿轮中心提示：视觉上的透明十字孔。
##
## 它只在渲染层用画布背景色/背景纹理盖出十字，看起来像穿透的孔；
## **不修改** black_image、rod_layer.pixels、gear_centers 或任何物理数据，
## 因此齿轮碰撞、中心吸附、轴承、蓝图、存档都不受影响。
const GearCenters := preload("res://actor/canvas/src/gear_centers.gd")
const Axle := preload("res://ink/yellow/src/axle.gd")
const ARM := 3
var surface
var entity_body = null
var entity_host: Node2D
var _background_texture: Texture2D
var _background_image: Image


func _ready() -> void:
	if entity_body == null:
		surface = get_parent()
	z_index = 9
	z_as_relative = false
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func _process(_delta: float) -> void:
	if entity_body != null:
		global_transform = entity_host.global_transform * Transform2D(entity_body.rotation, entity_body.position)
	modulate = Color.WHITE
	queue_redraw()


func _surface():
	if surface != null:
		return surface
	if entity_host == null:
		return null
	var canvas = entity_host.get_node_or_null("MapCanvas")
	if canvas != null:
		return canvas.surface
	return entity_host.find_child("CanvasSurface", true, false)


func _draw() -> void:
	var target = _surface()
	if target == null:
		return
	if entity_body != null:
		for record in GearCenters.body_records(entity_body):
			if not GearCenters.record_alive(entity_body, record):
				continue
			# 已经装了真实轴承时，中心显示轴承本体，不能再盖一个纸色十字。
			if _has_entity_bearing(GearCenters.position_of(record)):
				continue
			_draw_hole(target, GearCenters.position_of(record), true)
		return
	for record in target.gear_centers:
		if _has_draft_bearing(target, GearCenters.position_of(record)):
			continue
		_draw_hole(target, GearCenters.position_of(record), false)


func _has_draft_bearing(target, point: Vector2) -> bool:
	for record in target.draft_bearings:
		if Vector2(record.get("position", Vector2.ZERO)).distance_squared_to(point) <= 0.25:
			return true
	return false


func _has_entity_bearing(local_point: Vector2) -> bool:
	if entity_host == null:
		return false
	for child in entity_host.get_children():
		if not child is Axle or child.is_queued_for_deletion() or child.yellow_anchor.is_empty():
			continue
		if child.yellow_anchor.body != entity_body:
			continue
		var anchor_local: Vector2 = child.yellow_anchor.get("local", Vector2.INF)
		if anchor_local.distance_squared_to(local_point) <= 0.25:
			return true
	return false


## local_point：实体为刚体局部坐标，草稿为画布局部坐标。
func _draw_hole(target, local_point: Vector2, body_space: bool) -> void:
	for cell: Vector2i in _cross_cells(Vector2i(local_point.floor())):
		var canvas_point := Vector2(cell)
		if body_space:
			canvas_point = target.to_local(global_transform * (Vector2(cell) + Vector2.ONE * 0.5))
		if not GearCenters.inside(canvas_point, target.canvas_size):
			continue
		var color := _paper_color(target, Vector2i(canvas_point.floor()))
		draw_rect(Rect2(Vector2(cell), Vector2.ONE), color, true)


func _cross_cells(center: Vector2i) -> Array:
	var cells: Array = []
	for offset in range(-ARM, ARM + 1):
		cells.append(center + Vector2i(offset, 0))
		if offset != 0:
			cells.append(center + Vector2i(0, offset))
	return cells


func _paper_color(target, cell: Vector2i) -> Color:
	if target.background_texture != null:
		if _background_texture != target.background_texture:
			_background_texture = target.background_texture
			_background_image = target.background_texture.get_image()
		var image := _background_image
		if image != null and not image.is_empty():
			var width := image.get_width()
			var height := image.get_height()
			var x := ((cell.x % width) + width) % width
			var y := ((cell.y % height) + height) % height
			return target.background_color.blend(image.get_pixel(x, y))
	return target.background_color
