extends Node2D
## 编辑器齿轮预览与独立像素部件；不把齿轮焊进背后的画布支座。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const InkItem := preload("res://actor/ink_item/src/ink_item.gd")
const ShapeNode := preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
const Bearing := preload("res://actor/canvas/src/gear_bearing.gd")
const History := preload("res://actor/canvas/src/canvas_history.gd")
const MIN_RADIUS := 12.0
const DEFAULT_TEETH := 12
var teeth := DEFAULT_TEETH
var dragging := false
var center := Vector2.ZERO
var radius := 0.0
var polygon := PackedVector2Array()
## 落笔时记录选色，预览、像素实体和轴承始终使用同一种材质。
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
	draw_circle(Vector2.ZERO, 4.0, Color(0.95, 0.72, 0.08), false, 1.0)
	draw_line(Vector2(-6, 0), Vector2(6, 0), Color.BLACK)
	draw_line(Vector2(0, -6), Vector2(0, 6), Color.BLACK)

## 已经存在的齿轮轮体既不能当支座，也不能和新齿轮共用像素：
## 共用像素的两个刚体会互相插入，各自又钉在固定芯点上，求解器只能硬顶到谁也转不动。
static func gear_wheels(host) -> Dictionary:
	var result: Dictionary = {}
	for child in host.get_children():
		if child.get_script() != Bearing:
			continue
		if child.is_queued_for_deletion() or child.yellow_anchor.is_empty():
			continue
		result[child.yellow_anchor.body] = true
	return result


func finish(point: Vector2):
	if not dragging:
		return null
	update_preview(point)
	dragging = false
	queue_redraw()
	var canvas = get_parent().get_parent()
	if not canvas._map_editor_mode or radius < MIN_RADIUS:
		return null
	var gear_polygon := polygon.duplicate()
	var host = canvas.world
	var axle: Vector2 = host.to_local(get_parent().to_global(center))
	var wheels := gear_wheels(host)
	if _overlaps_wheels(wheels, axle):
		return null
	# 钉子像素是轴点，被齿轮轮廓盖掉等于悄悄删掉玩家的锚。
	var cells := _outline_cells()
	if _covers_nail(cells):
		return null
	var extent := ceili(radius)
	var state: Dictionary = History.capture(canvas, true)
	# 只有已经存在的实体才算支座。放置齿轮不再顺带固化草稿：那样会把整张画布提交，
	# 而且固出来的支座没有钉子，是动态刚体，齿轮跟着它一起掉。
	var support: Dictionary = Bearing.find_support(host.world, axle, null, wheels)
	var support_mat: int = support.get("material", 0)
	var image := Image.create_empty(extent * 2 + 1, extent * 2 + 1, false, Image.FORMAT_R8)
	for y in image.get_height():
		for x in image.get_width():
			if Geometry2D.is_point_in_polygon(Vector2(x - extent, y - extent), gear_polygon):
				image.set_pixel(x, y, Color8(ink_material, 0, 0, 255))
	var node := InkItem.new()
	node.name = "Gear%d" % host.get_child_count()
	node.position = axle - Vector2.ONE * 0.5
	node.add_to_group("ink_item", true)
	var shape := ShapeNode.new()
	shape.source = ShapeNode.Source.PAINT
	shape.paint = image
	shape.position = Vector2(-extent, -extent)
	node.add_child(shape)
	host.add_child(node)
	node.owner = host
	shape.owner = host
	var body = host.add_body_node(node)
	var anchor_local: Vector2 = body.to_local(axle)
	var bearing := Bearing.new()
	bearing.teeth = teeth
	bearing.gear_material = ink_material
	bearing.support_material = support_mat
	bearing.fixed_to_world = support.is_empty()
	bearing.yellow_position = axle
	bearing.black_position = axle
	bearing.yellow_anchor = {"body": body, "cell": Vector2i(anchor_local.floor()), "local": anchor_local}
	bearing.black_anchor = support
	host.add_child(bearing)
	bearing.owner = host
	bearing.wheel_path = bearing.get_path_to(node)
	bearing.connect_joint()
	bearing._process(0.0)
	# 轮体是独立刚体，本来不在画布上；蓝墨工具只认画布像素，所以把轮廓同步写一份上去。
	# 不记账（齿轮不花瓶子里的墨），撤销由这次 History 快照覆盖。
	# 轮廓里原本空白的格子要记下来：固化时跳过它们，否则会多出一块和齿轮完全重合的刚体。
	var surface = get_parent()
	var empty_cells: Dictionary = {}
	for at: Vector2i in cells:
		if surface.material_at(at.x, at.y) == 0:
			empty_cells[at] = true
	for at: Vector2i in cells:
		surface.black_image.set_pixelv(at, Palette.color_for_material_id(ink_material))
		surface._mark_dirty(at)
	surface._flush_texture()
	surface.add_gear_skip_cells(empty_cells)
	History.commit(canvas, state)
	return bearing


## 齿轮轮廓对应的画布像素；与 Image 栅格用同一套判定，保证刚体和画布轮廓一致。
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


## 新齿轮的像素落在已有齿轮轮体上时拒绝落笔；齿只能啮合，不能重叠。
func _overlaps_wheels(wheels: Dictionary, axle: Vector2) -> bool:
	if wheels.is_empty():
		return false
	var extent := ceili(radius)
	var origin := axle - Vector2.ONE * 0.5
	var world_rect := Rect2(origin, Vector2.ONE * float(extent * 2 + 1))
	for body in wheels:
		if not body.aabb.intersects(world_rect):
			continue
		for j in range(-extent, extent + 1):
			for i in range(-extent, extent + 1):
				if not Geometry2D.is_point_in_polygon(Vector2(i, j), polygon):
					continue
				var cell := Vector2i(body.to_local(origin + Vector2(i, j)).floor())
				for body_shape in body.shapes:
					if body_shape.get_pixel(cell.x, cell.y) != 0:
						return true
	return false
