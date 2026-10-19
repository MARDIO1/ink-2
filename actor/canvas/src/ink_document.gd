extends RefCounted
## 草稿文档的读写：内嵌文档（Dictionary）、`.snapshot` 文件、PNG 与 Image 资源。
##
## 每个函数第一个参数是画布表面——它提供像素缓冲与各层；本模块不持有状态。
## 只搬运字节与元数据，不固化、不推进物理、不动撤销栈。

const InkSnapshot := preload("res://actor/canvas/src/ink_snapshot.gd")
const GearCenters := preload("res://actor/canvas/src/gear_centers.gd")
const Nail := preload("res://actor/nail/src/nail.gd")
const InkPalette := preload("res://ink/general/src/ink_palette.gd")
const NAIL_COST := 10


## 内嵌文档使用无损 PNG，包含空草稿（避免旧快照重新覆盖已清空的画布）。
static func capture(surface) -> Dictionary:
	var data := InkSnapshot.metadata(surface)
	data["version"] = 1
	data["black"] = surface.black_image.save_png_to_buffer()
	data["rod"] = surface.rod_layer.pixels.save_png_to_buffer()
	data["fixed_nails"] = surface.nail_layer.nails.keys()
	data["background_nails"] = surface.nail_layer.background_nails.keys()
	data["infinite_nails"] = surface.nail_layer.infinite_nails.keys()
	return data


static func restore(surface, data: Dictionary) -> Error:
	var image := Image.new()
	var error := image.load_png_from_buffer(data.get("black", PackedByteArray()))
	if error != OK:
		return error
	return restore_pixels(surface, image, data)


## 保存 CPU 像素缓冲，包含颜色、透明度和尺寸；不读取 GPU，不触发固化。
static func save(surface, path: String) -> Error:
	var error: Error
	if path.get_extension().to_lower() == "snapshot":
		error = _save_snapshot(surface, path)
	elif path.get_extension().to_lower() == "png":
		error = surface.black_image.save_png(ProjectSettings.globalize_path(path))
	else:
		error = ResourceSaver.save(surface.black_image, path)
	if error == OK:
		print("CANVAS saved: ", ProjectSettings.globalize_path(path))
	else:
		push_error("Canvas save failed: %s (%d)" % [path, error])
	return error


## 编辑快照使用 PNG 压缩数据，但故意不用 .png 扩展名。Godot 编辑器会持续监视并
## 导入 res:// 下的 PNG，自动保存恰好撞上导入线程时 Windows 会返回 ERR_FILE_CANT_WRITE。
## 未注册的 .snapshot 不进入导入流水线，并通过同目录临时文件避免中途写坏快照。
static func _save_snapshot(surface, path: String) -> Error:
	var absolute := ProjectSettings.globalize_path(path)
	var temporary := absolute + ".tmp"
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer("INK2".to_ascii_buffer())
	var rule = surface.yellow_rule()
	file.store_var({"black": surface.black_image.save_png_to_buffer(), "rod": surface.rod_layer.pixels.save_png_to_buffer(), "anchors": surface.rod_layer.anchor_points,
		"gear_centers": surface.gear_centers.duplicate(true), "draft_bearings": surface.draft_bearings.duplicate(true),
		"rails": surface.rod_layer.rails, "slider_pins": surface.rod_layer.slider_pins,
		"fixed_nails": surface.nail_layer.nails.keys(), "background_nails": surface.nail_layer.background_nails.keys(),
		"infinite_nails": surface.nail_layer.infinite_nails.keys(),
		"springs": rule.draft_data(surface) if rule != null else [], "blue": surface.blue_layer.cells,
		"motors": surface.blue_rule().draft_data(surface) if surface.blue_rule() != null else []})
	file.flush()
	file.close()
	if FileAccess.file_exists(path):
		var remove_error := DirAccess.remove_absolute(absolute)
		if remove_error != OK:
			DirAccess.remove_absolute(temporary)
			return remove_error
	var rename_error := DirAccess.rename_absolute(temporary, absolute)
	if rename_error != OK:
		DirAccess.remove_absolute(temporary)
	return rename_error


## 保存整张透明 PNG：黑=空、颜色=材质 id。
static func save_png(surface, path: String) -> Error:
	var error: Error = surface.black_image.save_png(ProjectSettings.globalize_path(path))
	if error == OK:
		print("MAP saved: ", ProjectSettings.globalize_path(path))
	else:
		push_error("Map save failed: %s (%d)" % [path, error])
	return error


static func load(surface, path: String) -> Error:
	if not FileAccess.file_exists(path):
		push_error("Canvas file missing: " + path)
		return ERR_FILE_NOT_FOUND
	var image: Image
	var rod_data: Dictionary = {}
	if path.get_extension().to_lower() == "snapshot":
		image = Image.new()
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.slice(0, 4).get_string_from_ascii() == "INK2":
			var snapshot := FileAccess.open(path, FileAccess.READ)
			snapshot.get_buffer(4)
			rod_data = snapshot.get_var()
			bytes = rod_data.black
		var load_error := image.load_png_from_buffer(bytes)
		if load_error != OK:
			push_error("Canvas snapshot decode failed: %s (%d)" % [path, load_error])
			return load_error
	elif path.get_extension().to_lower() == "png":
		image = Image.load_from_file(ProjectSettings.globalize_path(path))
	else:
		image = ResourceLoader.load(path, "Image", ResourceLoader.CACHE_MODE_IGNORE) as Image
	if image == null or image.is_empty():
		push_error("Canvas file is not an Image: " + path)
		return ERR_INVALID_DATA
	return restore_pixels(surface, image, rod_data)


## 无坐标转换地恢复文档草稿；已固化实体由场景独立保存。
static func restore_pixels(surface, image: Image, rod_data: Dictionary) -> Error:
	surface._painting = false
	surface.get_parent().canvas_size = image.get_size()
	surface.black_image = image
	surface.black_image.convert(Image.FORMAT_RGBA8)
	if not surface.defer_load_metadata:
		surface.rebuild_ink_tiles()
		rebuild_metadata(surface)
	surface.gear_centers = GearCenters.normalize(rod_data.get("gear_centers", []))
	var pending = rod_data.get("draft_bearings", [])
	surface.draft_bearings = pending.duplicate(true) if pending is Array else []
	if not rod_data.is_empty():
		var rods := Image.new()
		rods.load_png_from_buffer(rod_data.rod)
		surface.rod_layer.pixels = rods
		surface.rod_layer.anchor_points = rod_data.anchors
		surface.rod_layer.rails = rod_data.get("rails", []).duplicate(true)
		surface.rod_layer.slider_pins = rod_data.get("slider_pins", []).duplicate(true)
		surface.rod_layer.refresh()
		if rod_data.has("fixed_nails") or rod_data.has("background_nails") or rod_data.has("infinite_nails"):
			surface.nail_layer.clear()
			for point in rod_data.get("fixed_nails", []):
				surface.nail_layer.add(Vector2i(point), Nail.Kind.FIXED)
			for point in rod_data.get("background_nails", []):
				surface.nail_layer.add(Vector2i(point), Nail.Kind.BACKGROUND)
			for point in rod_data.get("infinite_nails", []):
				surface.nail_layer.add(Vector2i(point), Nail.Kind.INFINITE)
			surface._bump_ink(InkPalette.GREY.id, surface.nail_layer.nails.size() * NAIL_COST, false)
			surface._bump_ink(InkPalette.WHITE.id, surface.nail_layer.background_nails.size() * NAIL_COST, false)
		var health = surface._health_node()
		if not surface.ink_free and health != null:
			health.reduce(InkPalette.YELLOW.id, surface.rod_layer.make_shape().pixel_count())
		var rule = surface.yellow_rule()
		if rule != null:
			rule.restore_drafts(surface, rod_data.get("springs", []), not surface.ink_free)
		surface.blue_layer.cells = rod_data.get("blue", PackedVector2Array())
		surface.blue_layer.rebuild()
		surface._bump_ink(InkPalette.BLUE.id, surface.blue_layer.cells.size())
		if surface.blue_rule() != null:
			surface.blue_rule().restore_draft_data(surface, rod_data.get("motors", []))
		surface._flush_ink()
	return OK


## 读盘后重建钉子和墨水账：按块分治，只扫各块的内容框（空块一个字节都不扫）。
static func rebuild_metadata(surface) -> void:
	surface.nail_layer.clear()
	surface.ink_px_by_material = {}
	surface._pending_ink = {}
	var nail_id := InkPalette.nail_material_id()
	var width: int = surface.canvas_size.x
	var data: PackedByteArray = surface.black_image.get_data()
	for box in surface._content_boxes():
		for y in range(box.position.y, box.end.y):
			var row := y * width
			for x in range(box.position.x, box.end.x):
				var at := (row + x) * 4
				if data[at + 3] <= 127:
					continue
				var material_id := InkPalette.material_id_at_color(Color8(
					data[at], data[at + 1], data[at + 2], data[at + 3]
				))
				if material_id == nail_id:
					var point := Vector2i(x, y)
					surface.black_image.set_pixelv(point, InkPalette.GREY.color)
					surface.nail_layer.add(point, Nail.Kind.FIXED)
					surface.ink_px_by_material[InkPalette.GREY.id] = surface.ink_px_of(InkPalette.GREY.id) + 1
				elif InkPalette.is_ink(material_id):
					surface.ink_px_by_material[material_id] = surface.ink_px_of(material_id) + 1
	surface.ink_px_by_material[InkPalette.GREY.id] = surface.ink_px_of(InkPalette.GREY.id) + surface.nail_layer.nails.size() * NAIL_COST
	surface.ink_px_by_material[InkPalette.WHITE.id] = surface.ink_px_of(InkPalette.WHITE.id) + surface.nail_layer.background_nails.size() * NAIL_COST
	surface.rebuild_ink_tiles()


#按像素重新数一遍画布自己的账 —— 读盘、以及怀疑账本漂了的时候用。
#⚠️ 只走一次性路径。按块分治：代价 = 各块内容框之和，不是整张画布。
static func recount(surface) -> void:
	surface.ink_px_by_material = {}
	surface._pending_ink = {}
	surface._flush_texture()                  # 先落地未上传的写入，块集合才是完整的
	var width: int = surface.canvas_size.x
	var data: PackedByteArray = surface.black_image.get_data()
	for box in surface._content_boxes():
		for y in range(box.position.y, box.end.y):
			var row := y * width
			for x in range(box.position.x, box.end.x):
				var at := (row + x) * 4
				if data[at + 3] <= 127:
					continue
				var material_id := InkPalette.material_id_at_color(Color8(
					data[at], data[at + 1], data[at + 2], data[at + 3]
				))
				if InkPalette.is_ink(material_id):
					surface.ink_px_by_material[material_id] = surface.ink_px_of(material_id) + 1
	surface.ink_px_by_material[InkPalette.GREY.id] = surface.ink_px_of(InkPalette.GREY.id) + surface.nail_layer.nails.size() * NAIL_COST
	surface.ink_px_by_material[InkPalette.WHITE.id] = surface.ink_px_of(InkPalette.WHITE.id) + surface.nail_layer.background_nails.size() * NAIL_COST
