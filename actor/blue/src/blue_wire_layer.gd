@tool
extends Node2D
## 草稿与实体共用导电覆盖层。物性仍属于唯一 PBody；覆盖黑色不增加质量。
const Palette := preload("res://ink/src/ink_palette.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const DIRS: Array[Vector2i] = [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]

#region 数据与显示
@export var cells: PackedVector2Array = []
@export var active := false
@export var carrier_material: int = 1
var mask: Dictionary = {}
var widths: Dictionary = {}
var boundary: Array[Vector2i] = []
var boundary_mask: Dictionary = {}
var chunks: Dictionary = {}
var body = null
var source_surface = null
var last_point := Vector2.ZERO
var drawing := false
var _image: Image
var _texture: ImageTexture
var _origin := Vector2i.ZERO
var _revision: Array = []

func local_bounds() -> Rect2:
	return Rect2(Vector2(_origin), Vector2(_image.get_size())) if not mask.is_empty() and _image != null else Rect2()

func _ready() -> void:
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
	cells = PackedVector2Array(mask.keys())
	if cells.is_empty():
		_texture = null
		queue_redraw()
		return
	var lo: Vector2i = mask.keys()[0]
	var hi := lo
	for at: Vector2i in mask:
		lo = lo.min(at)
		hi = hi.max(at)
	_origin = lo
	_image = Image.create_empty(hi.x - lo.x + 1, hi.y - lo.y + 1, false, Image.FORMAT_RGBA8)
	for at: Vector2i in mask:
		_image.set_pixelv(at - lo, Palette.BLUE.color)
	_texture = ImageTexture.create_from_image(_image)
	queue_redraw()

func _draw() -> void:
	if _texture != null:
		draw_texture(_texture, Vector2(_origin))

func sync_pose() -> void:
	if active and body != null:
		position = body.position
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
		source_surface._bump_ink(Palette.BLUE.id, 1)
		room -= 1
	source_surface._flush_ink()
	last_point = point
	refresh()

func finish() -> void:
	drawing = false
	build_widths()
	source_surface._commit_undo_step()

func erase(at: Vector2i, refund := true) -> void:
	if mask.erase(at) and refund:
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
