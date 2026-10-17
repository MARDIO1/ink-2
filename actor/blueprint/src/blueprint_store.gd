extends RefCounted
const Palette := preload("res://ink/general/src/ink_palette.gd")
## 蓝图仅包含 JSON 数据；不加载场景、脚本或带对象的 Variant。
const VERSION := 2
const MAX_SIDE := 1024
const MAX_FILE_BYTES := 24 * 1024 * 1024
const MAX_CELLS := 600000
var directory := "user://blueprints"
var error := ""

func list_all() -> Array:
	var result: Array = []
	var folder := DirAccess.open(directory)
	if folder == null:
		return result
	for file in folder.get_files():
		if file.ends_with(".inkbp"):
			var data := read(file.get_basename())
			if not data.is_empty():
				result.append(data)
	result.sort_custom(func(a, b): return int(a.updated) > int(b.updated))
	return result

func valid_id(id: String) -> bool:
	return not id.is_empty() and id.length() <= 80 and id.is_valid_filename() \
		and not id.contains(".") and not id.contains("/") and not id.contains("\\")

func read(id: String) -> Dictionary:
	error = ""
	if not valid_id(id):
		return {}
	var file := FileAccess.open(directory.path_join(id + ".inkbp"), FileAccess.READ)
	if file == null or file.get_length() > MAX_FILE_BYTES:
		return {}
	var data = JSON.parse_string(file.get_as_text())
	if data is Dictionary and data.get("version", 0) == 1:
		data = migrate_v1(data)
		if validate(data) and data.id == id:
			save(data)
	if not data is Dictionary or not validate(data) or data.id != id:
		error = "蓝图损坏或版本不受支持"
		return {}
	return data

func save(data: Dictionary) -> bool:
	error = ""
	if data.get("id", "").is_empty():
		data.id = "%d_%d" % [Time.get_unix_time_from_system() * 1000, randi()]
	data.version = VERSION
	data.updated = int(Time.get_unix_time_from_system())
	if not valid_id(data.id) or not validate(data):
		error = "蓝图数据无效或超出大小限制"
		return false
	var content := JSON.stringify(data)
	if content.to_utf8_buffer().size() > MAX_FILE_BYTES:
		error = "蓝图文件过大"
		return false
	var absolute := ProjectSettings.globalize_path(directory)
	if DirAccess.make_dir_recursive_absolute(absolute) != OK:
		error = "无法创建蓝图目录"
		return false
	var target := absolute.path_join(data.id + ".inkbp")
	var file := FileAccess.open(target + ".tmp", FileAccess.WRITE)
	if file == null:
		error = "无法写入蓝图"
		return false
	file.store_string(content)
	file.flush()
	var written := file.get_error()
	file.close()
	if written != OK:
		error = "蓝图写入失败，原文件未修改"
		return false
	# Windows 不允许 rename 覆盖；先将旧文件移到可恢复的备份。
	var had_old := FileAccess.file_exists(target)
	if had_old and DirAccess.rename_absolute(target, target + ".bak") != OK:
		error = "蓝图正被占用，原文件未修改"
		return false
	if DirAccess.rename_absolute(target + ".tmp", target) != OK:
		if had_old:
			DirAccess.rename_absolute(target + ".bak", target)
		error = "无法提交蓝图，已保留原文件"
		return false
	if had_old:
		DirAccess.remove_absolute(target + ".bak")
	return true

func trash(id: String) -> bool:
	if not valid_id(id):
		return false
	var path := ProjectSettings.globalize_path(directory.path_join(id + ".inkbp"))
	return DirAccess.rename_absolute(path, path + ".%d.trash" % Time.get_ticks_usec()) == OK

static func number(value) -> bool:
	return (value is float or value is int) and is_finite(float(value))

static func pair(value, limit := 65536.0) -> bool:
	return value is Array and value.size() == 2 and number(value[0]) and number(value[1]) \
		and absf(value[0]) <= limit and absf(value[1]) <= limit

static func validate(data: Dictionary) -> bool:
	for key in ["version", "id", "name", "description", "tags", "updated", "favorite", "editor_only", "size",
		"pixels", "fixed_nails", "background_nails", "rods", "blue", "anchors", "springs", "motors", "bodies", "gears"]:
		if not data.has(key):
			return false
	if data.get("version") != VERSION or not data.get("id", "") is String \
		or not data.get("name", "") is String or data.get("name", "").strip_edges().is_empty() \
		or data.name.length() > 64 or not data.get("description", "") is String \
		or data.get("description", "").length() > 2000 or not number(data.get("updated", 0)):
		return false
	if not pair(data.get("size"), MAX_SIDE):
		return false
	var width := int(data.size[0])
	var height := int(data.size[1])
	if width < 1 or height < 1 or width != data.size[0] or height != data.size[1]:
		return false
	if not data.get("tags", []) is Array or data.get("tags", []).size() > 8:
		return false
	for tag in data.get("tags", []):
		if not tag is String or tag.length() > 24:
			return false
	if not data.get("favorite", false) is bool or not data.get("editor_only", false) is bool:
		return false
	var total := 0
	for key in ["pixels", "rods", "blue"]:
		if not data.get(key) is Array or not cells_valid(data[key], width * height, key == "pixels"):
			return false
		total += data[key].size()
	for key in ["fixed_nails", "background_nails"]:
		if not cells_valid(data.get(key), width * height, false):
			return false
		total += data[key].size() * 10
	if not cells_valid(data.get("infinite_nails", []), width * height, false):
		return false
	for key in ["anchors", "springs", "motors", "bodies", "gears"]:
		if not data.get(key) is Array or data[key].size() > 128:
			return false
	for point in data.anchors:
		if not pair(point, MAX_SIDE):
			return false
	var body_cells: Array = []
	for body in data.bodies:
		if not body is Dictionary or not cells_valid(body.get("pixels"), width * height, true) \
			or not cells_valid(body.get("fixed_nails", []), width * height, false) \
			or not cells_valid(body.get("background_nails", []), width * height, false) \
			or not cells_valid(body.get("infinite_nails", []), width * height, false) \
			or body.pixels.is_empty() or not body.has("static") or not body.static is bool:
			return false
		total += body.pixels.size()
		var mapped := {}
		for entry in body.pixels:
			mapped[int(entry[0])] = int(entry[1])
		body_cells.append(mapped)
	for gear in data.gears:
		if not gear is Dictionary or not pair(gear.get("point"), MAX_SIDE) \
			or not number(gear.get("wheel")) or not number(gear.get("support")) \
			or not number(gear.get("teeth")) or (gear.teeth != 8 and gear.teeth != 12) \
			or not number(gear.get("material")) or not Palette.is_ink(int(gear.material)):
			return false
		if int(gear.wheel) != gear.wheel or int(gear.support) != gear.support or gear.wheel < 0 or gear.wheel >= data.bodies.size() or gear.support < -1 or gear.support >= data.bodies.size():
			return false
		var point := Vector2(gear.point[0], gear.point[1])
		if not Rect2(Vector2.ZERO, Vector2(width, height)).has_point(point) or gear.wheel == gear.support:
			return false
		var at := floori(point.y) * width + floori(point.x)
		if body_cells[int(gear.wheel)].get(at, 0) != gear.material:
			return false
		if gear.support >= 0 and not body_cells[int(gear.support)].has(at):
			return false
	for spring in data.springs:
		if not spring is Dictionary or not spring.get("path") is Array or spring.path.size() != 2:
			return false
		for point in spring.path:
			if not pair(point, MAX_SIDE):
				return false
		if not number(spring.get("width")) or spring.width < 1 or spring.width > 65 \
			or not number(spring.get("dash")) or spring.dash < 1 or spring.dash > 128 \
			or not number(spring.get("gap")) or spring.gap < 1 or spring.gap > 128 or not spring.get("dashed", true) is bool:
			return false
		var span := Vector2(spring.path[0][0], spring.path[0][1]).distance_to(Vector2(spring.path[1][0], spring.path[1][1]))
		if span * (spring.width + 2) > 200000:
			return false
		total += ceili(span * (spring.width + 2))
		if not spring.get("worn", []) is Array or spring.get("worn", []).size() > MAX_CELLS:
			return false
		total += spring.get("worn", []).size()
		for point in spring.get("worn", []):
			if not pair(point):
				return false
	for motor in data.motors:
		if not motor is Dictionary or not pair(motor.get("point"), MAX_SIDE) or not pair(motor.get("tip"), MAX_SIDE) \
			or not number(motor.get("angle")) or absf(motor.angle) > TAU * 100 \
			or not number(motor.get("width")) or motor.width < 1 or motor.width > 65 \
			or not number(motor.get("area")) or motor.area < 1 or motor.area > MAX_CELLS:
			return false
		if Vector2(motor.tip[0], motor.tip[1]).length() * motor.width + motor.width * motor.width > MAX_CELLS:
			return false
		total += int(motor.area)
	return total > 0 and total <= MAX_CELLS and (data.gears.is_empty() or data.get("editor_only", false))


static func migrate_v1(source: Dictionary) -> Dictionary:
	var data := source.duplicate(true)
	data.version = VERSION
	data["fixed_nails"] = []
	data["background_nails"] = []
	for entry in data.get("pixels", []):
		if int(entry[1]) == Palette.nail_material_id():
			data.fixed_nails.append(int(entry[0]))
			entry[1] = Palette.GREY.id
	for body in data.get("bodies", []):
		body["fixed_nails"] = []
		body["background_nails"] = []
		for entry in body.get("pixels", []):
			if int(entry[1]) == Palette.nail_material_id():
				body.fixed_nails.append(int(entry[0]))
				entry[1] = Palette.GREY.id
	return data

static func cells_valid(cells, area: int, materials: bool) -> bool:
	if not cells is Array or cells.size() > MAX_CELLS:
		return false
	var seen := {}
	for entry in cells:
		var index = entry[0] if materials and entry is Array and entry.size() == 2 else entry
		if not number(index) or int(index) != index or index < 0 or index >= area or seen.has(int(index)):
			return false
		if materials and (not entry is Array or entry.size() != 2 or not number(entry[1]) \
			or int(entry[1]) != entry[1] or (not Palette.is_ink(int(entry[1])) and entry[1] != Palette.nail_material_id())):
			return false
		seen[int(index)] = true
	return true
