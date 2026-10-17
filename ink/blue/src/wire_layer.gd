@tool
extends Node2D
## 草稿与实体共用导电覆盖层。物性仍属于唯一 PBody；覆盖黑色不增加质量。
## 此节点管理导线像素、显示和载体跟随；能源接触由 energy_flow.gd 管理。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const DIRS: Array[Vector2i] = [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]

#region 数据与显示
var _cells := PackedVector2Array()
var _cells_dirty := false
@export var cells: PackedVector2Array:
	get:
		# 运行时局部烧断不复制整条长线；真正保存/回收/碎裂时才同步序列化数组。
		if _cells_dirty:
			_cells = PackedVector2Array(mask.keys())
			_cells_dirty = false
		return _cells
	set(value):
		_cells = value
		_cells_dirty = false
@export var active := false
@export var carrier_material: int = 1
## 只调显示，不影响能源量/传播。Inspector 可按每条导线覆盖。
@export_range(0.0, 8.0, 0.1) var highlight_brightness := 2.5
@export_range(1.0, 6.0, 0.5) var highlight_core_width := 2.0
var mask: Dictionary = {}
var widths: Dictionary = {}
var boundary: Array[Vector2i] = []
var boundary_mask: Dictionary = {}
var chunks: Dictionary = {}
var body = null
var source_surface = null
var last_point := Vector2.ZERO
var drawing := false
var line_drawing := false
var line_origin := Vector2.ZERO
var line_cursor := Vector2.ZERO
const TILE_SIZE := 64
var _images: Dictionary = {}
var _textures: Dictionary = {}
var _dirty_tiles: Dictionary = {}
var _bounds := Rect2()
var _revision: Array = []
var energy_lines := PackedVector2Array()
var energy_colors := PackedColorArray()
var _energy_display: Node2D
var tail_lines := PackedVector2Array()
var version := 0
var layout_version := 0 # 只有整批替换才使电机接触范围缓存失效；烧断只删像素。

func local_bounds() -> Rect2:
	return _bounds if not mask.is_empty() else Rect2()

func pixels_in_rect(rect: Rect2, boundary_only := false) -> Array:
	var region := rect.intersection(local_bounds())
	if not region.has_area():
		return []
	var lookup: Dictionary = boundary_mask if boundary_only else mask
	var lo := Vector2i(region.position.floor())
	var hi := Vector2i(region.end.ceil())
	var result: Array = []
	if (hi.x - lo.x + 1) * (hi.y - lo.y + 1) < lookup.size():
		for y in range(lo.y, hi.y + 1):
			for x in range(lo.x, hi.x + 1):
				var at := Vector2i(x, y)
				if lookup.has(at):
					result.append(at)
	else:
		for at: Vector2i in lookup:
			if region.has_point(Vector2(at) + Vector2.ONE * 0.5):
				result.append(at)
	return result

func _ready() -> void:
	# 每条导线只多一个批量高光层；高光移动不重建全部静态贴图绘制命令。
	_energy_display = Node2D.new()
	_energy_display.name = "EnergyHighlight"
	add_child(_energy_display)
	_energy_display.draw.connect(_draw_energy)
	z_index = 7
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rebuild()
	if active:
		call_deferred("restore")
	else:
		source_surface = get_parent()

func rebuild() -> void:
	mask.clear()
	for point in cells:
		mask[Vector2i(point)] = true
	refresh()
	build_widths()

func refresh() -> void:
	# 整批数据替换后重建显示；连续落笔只刷脏块，避免长斜线生成巨大透明贴图。
	cells = PackedVector2Array(mask.keys())
	_images.clear()
	_textures.clear()
	_dirty_tiles.clear()
	_bounds = Rect2()
	for at: Vector2i in mask:
		_set_display_pixel(at, Palette.BLUE.color)
	flush_display(false)
	queue_redraw()
	version += 1
	layout_version += 1

func show_energy_points(heads: PackedVector2Array, tails: PackedVector2Array, energies: PackedFloat32Array, reference: float) -> void:
	energy_lines.resize(heads.size() * 2)
	energy_colors.resize(heads.size())
	for i in heads.size():
		energy_lines[i * 2] = heads[i] + Vector2(0, 0.5)
		energy_lines[i * 2 + 1] = heads[i] + Vector2(1, 0.5)
		var color := Color(0.9, 1.0, 1.0, clampf(sqrt(maxf(0.0, energies[i]) / reference) * highlight_brightness, 0.3, 1.0))
		energy_colors[i] = color
	tail_lines.resize(tails.size() * 2)
	for i in tails.size():
		tail_lines[i * 2] = tails[i] + Vector2(0, 0.5)
		tail_lines[i * 2 + 1] = tails[i] + Vector2(1, 0.5)
	_energy_display.queue_redraw()

func _set_display_pixel(at: Vector2i, color: Color) -> void:
	var key := Vector2i(floori(float(at.x) / TILE_SIZE), floori(float(at.y) / TILE_SIZE))
	var image: Image = _images.get(key)
	if image == null:
		if color.a == 0.0:
			return
		image = Image.create_empty(TILE_SIZE, TILE_SIZE, false, Image.FORMAT_RGBA8)
		_images[key] = image
	image.set_pixelv(at - key * TILE_SIZE, color)
	_dirty_tiles[key] = true
	if color.a > 0.0:
		var pixel_rect := Rect2(Vector2(at), Vector2.ONE)
		_bounds = _bounds.merge(pixel_rect) if _bounds.has_area() else pixel_rect

func flush_display(sync_cells := true) -> void:
	# cells 是保存/撤销数据；落笔已逐像素追加时无需再复制整条导线。
	if _dirty_tiles.is_empty():
		return
	if sync_cells:
		cells = PackedVector2Array(mask.keys())
	for key: Vector2i in _dirty_tiles:
		var image: Image = _images[key]
		if image.is_invisible():
			_images.erase(key)
			_textures.erase(key)
		elif _textures.has(key):
			_textures[key].update(image)
		else:
			_textures[key] = ImageTexture.create_from_image(image)
	_dirty_tiles.clear()
	queue_redraw()

func _draw() -> void:
	for key: Vector2i in _textures:
		draw_texture(_textures[key], Vector2(key * TILE_SIZE))
	if line_drawing and source_surface != null:
		draw_line(line_origin, line_cursor, Palette.BLUE.color,
			float(source_surface.brush_size), false)

func _draw_energy() -> void:
	# 批量线段模拟光晕，避免每个能源格建立粒子节点或单独光源。
	if not tail_lines.is_empty():
		_energy_display.draw_multiline(tail_lines, Color(0.3, 0.7, 1.0, minf(0.65, 0.25 * highlight_brightness)), 3.0)
	if not energy_lines.is_empty():
		# 一层明亮光晕加亮芯，避免叠加两遍半透明外晕。
		_energy_display.draw_multiline(energy_lines, Color(0.25, 0.7, 1.0, minf(0.85, 0.3 * highlight_brightness)), 5.0)
		_energy_display.draw_multiline_colors(energy_lines, energy_colors, highlight_core_width)

func sync_pose() -> void:
	if active and body != null:
		if position != body.position:
			position = body.position
		if rotation != body.rotation:
			rotation = body.rotation

func _process(_delta: float) -> void:
	sync_pose()

func restore() -> void:
	if body != null:
		return
	var physics = get_parent().get("world")
	if physics == null or cells.is_empty():
		return
	var point: Vector2 = to_global(cells[0] + Vector2.ONE * 0.5)
	for candidate in physics.bodies:
		var local := Vector2i(candidate.to_local(point).floor())
		if material_at(candidate, local) == carrier_material:
			body = candidate
			sync_pose()
			return
	queue_free()

## 蚀除可以不分裂刚体；形状版本变化时才剔除失去载体的导电像素。
func prune(physics) -> bool:
	if body == null or not physics.bodies.has(body):
		queue_free()
		return true
	var revision: Array = []
	for shape in body.shapes:
		revision.append(shape.get_instance_id())
		revision.append(shape.revision)
	if revision == _revision:
		return false
	_revision = revision
	var changed := false
	for at: Vector2i in mask.keys():
		if material_at(body, at) == 0:
			mask.erase(at)
			changed = true
	if changed:
		refresh()
		build_widths()
		if mask.is_empty():
			queue_free()
	return changed

static func material_at(target, at: Vector2i) -> int:
	for shape in target.shapes:
		var material: int = shape.get_pixel(at.x, at.y)
		if material != 0:
			return material
	return 0

## 横纵连续跨度的较小值近似截面；每段只扫描一次，避免细线与长线二次复杂度。
func build_widths() -> void:
	widths.clear()
	boundary.clear()
	boundary_mask.clear()
	chunks.clear()
	for at: Vector2i in mask:
		var key: int = Shape.make_key(at.x >> 3, at.y >> 3)
		chunks[key] = int(chunks.get(key, 0)) | (1 << ((at.y & 7) * 8 + (at.x & 7)))
		if not mask.has(at + Vector2i.LEFT):
			var end := at
			while mask.has(end):
				end.x += 1
			for x in range(at.x, end.x):
				widths[Vector2i(x, at.y)] = float(end.x - at.x)
	for at: Vector2i in mask:
		if not mask.has(at + Vector2i.UP):
			var end := at
			while mask.has(end):
				end.y += 1
			for y in range(at.y, end.y):
				var p := Vector2i(at.x, y)
				widths[p] = minf(widths[p], end.y - at.y)
		for direction in DIRS:
			if not mask.has(at + direction):
				boundary.append(at)
				boundary_mask[at] = true
				break

func intact_on(target) -> bool:
	for key: int in chunks:
		var occupied := 0
		for shape in target.shapes:
			var chunk = shape.chunks.get(key)
			if chunk != null:
				occupied |= chunk.occ
		if occupied & int(chunks[key]) != int(chunks[key]):
			return false
	return true

func remember_revision() -> void:
	_revision.clear()
	for shape in body.shapes:
		_revision.append(shape.get_instance_id())
		_revision.append(shape.revision)
#endregion

#region 草稿编辑
func begin(point: Vector2) -> void:
	source_surface._begin_undo_step()
	drawing = true
	last_point = point
	extend(point)

func extend(point: Vector2) -> void:
	var pixels := {}
	source_surface._brush_line(pixels, last_point, point)
	var room: int = source_surface._ink_room(Palette.BLUE.id)
	for at: Vector2i in pixels:
		if mask.has(at) or room <= 0:
			continue
		var material: int = source_surface.material_at(at.x, at.y)
		if material != 0 and material != Palette.BLACK.id:
			continue
		mask[at] = true
		_cells.append(Vector2(at))
		_set_display_pixel(at, Palette.BLUE.color)
		source_surface._bump_ink(Palette.BLUE.id, 1)
		room -= 1
	source_surface._flush_ink()
	last_point = point
	flush_display(false)

func finish() -> void:
	drawing = false
	cells = PackedVector2Array(mask.keys())
	build_widths()
	source_surface._commit_undo_step()

## 蓝色直线工具：交互和栅格口径与黄色直导轨一致，宽度取当前 px 笔刷。
func begin_line(point: Vector2) -> void:
	source_surface._begin_undo_step()
	line_drawing = true
	line_origin = point.floor() + Vector2.ONE * 0.5
	line_cursor = line_origin
	queue_redraw()

func extend_line(point: Vector2) -> void:
	if not line_drawing:
		return
	line_cursor = point.clamp(Vector2.ZERO, Vector2(source_surface.canvas_size) - Vector2.ONE)
	queue_redraw()

func finish_line(point: Vector2) -> bool:
	if not line_drawing:
		return false
	extend_line(point)
	line_drawing = false
	var changed := _paint_line(line_origin, line_cursor, source_surface.brush_size)
	if changed > 0:
		cells = PackedVector2Array(mask.keys())
		build_widths()
		flush_display(false)
	source_surface._commit_undo_step()
	queue_redraw()
	return changed > 0

func cancel_line() -> void:
	if not line_drawing:
		return
	line_drawing = false
	source_surface._commit_undo_step()
	queue_redraw()

func _paint_line(a: Vector2, b: Vector2, width: int) -> int:
	var vector := b - a
	var length := vector.length()
	if length < 0.001:
		return 0
	var direction := vector / length
	var normal := direction.orthogonal()
	var half := maxf(0.5, width * 0.5)
	var low := Vector2i((a.min(b) - Vector2.ONE * half).floor()).max(Vector2i.ZERO)
	var high := Vector2i((a.max(b) + Vector2.ONE * half).ceil()).min(
		source_surface.canvas_size - Vector2i.ONE)
	var room: int = source_surface._ink_room(Palette.BLUE.id)
	var changed := 0
	for y in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			var cell := Vector2i(x, y)
			var relative := Vector2(cell) + Vector2.ONE * 0.5 - a
			var along := relative.dot(direction)
			if along < 0.0 or along > length or absf(relative.dot(normal)) > half:
				continue
			if mask.has(cell) or room <= 0:
				continue
			var material: int = source_surface.material_at(cell.x, cell.y)
			if material != 0 and material != Palette.BLACK.id:
				continue
			mask[cell] = true
			_cells.append(Vector2(cell))
			_set_display_pixel(cell, Palette.BLUE.color)
			source_surface._bump_ink(Palette.BLUE.id, 1)
			room -= 1
			changed += 1
	source_surface._flush_ink()
	return changed

func erase(at: Vector2i, refund := true) -> void:
	if mask.erase(at):
		_cells_dirty = true
		_set_display_pixel(at, Color.TRANSPARENT)
		if refund:
			source_surface._bump_ink(Palette.BLUE.id, -1)

func clear() -> void:
	mask.clear()
	refresh()
	build_widths()

func make_shape():
	var shape = Shape.new()
	for at: Vector2i in mask:
		shape.set_pixel(at.x, at.y, Palette.BLUE.id)
	return shape
#endregion
