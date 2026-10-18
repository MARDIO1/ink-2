extends Node2D
## 只画齿轮中心提示：小黄色十字。
## 它不写入黄墨图层、不参与碰撞/耗墨/导电；和真实轴承（大号黄色轴承贴图）外观不同。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const GearCenters := preload("res://actor/canvas/src/gear_centers.gd")
const ARM := 3.0
var surface
var entity_body = null
var entity_host: Node2D


func _ready() -> void:
	if entity_body == null:
		surface = get_parent()
	z_index = 9
	z_as_relative = false
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func _process(_delta: float) -> void:
	if entity_body != null:
		global_transform = entity_host.global_transform * Transform2D(entity_body.rotation, entity_body.position)
	queue_redraw()


func _draw() -> void:
	if entity_body != null:
		for record in GearCenters.body_records(entity_body):
			if GearCenters.record_alive(entity_body, record):
				_cross(GearCenters.position_of(record), Color(0.08, 0.07, 0.02, 1.0), 3.0)
				_cross(GearCenters.position_of(record), Palette.YELLOW.color, 1.0)
		return
	if surface == null:
		return
	for record in surface.gear_centers:
		var point := GearCenters.position_of(record)
		if not GearCenters.inside(point, surface.canvas_size):
			continue
		if surface.material_at(int(point.x), int(point.y)) == 0:
			continue
		_cross(point, Color(0.08, 0.07, 0.02, 1.0), 3.0)
		_cross(point, Palette.YELLOW.color, 1.0)


func _cross(point: Vector2, color: Color, width: float) -> void:
	draw_line(point - Vector2(ARM, 0), point + Vector2(ARM, 0), color, width)
	draw_line(point - Vector2(0, ARM), point + Vector2(0, ARM), color, width)
