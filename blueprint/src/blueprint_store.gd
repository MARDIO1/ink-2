extends RefCounted
## 蓝图的文件读写与命名。**数据格式不在这里**，见 `blueprint/src/blueprint_format.gd`。

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Format := preload("res://blueprint/src/blueprint_format.gd")

const VERSION := Format.VERSION
const MAX_SIDE := Format.MAX_SIDE
const MAX_FILE_BYTES := Format.MAX_FILE_BYTES
const MAX_CELLS := Format.MAX_CELLS

const PROJECT_DIRECTORY := "res://blueprints"
const FALLBACK_DIRECTORY := "user://blueprints"

var directory := PROJECT_DIRECTORY
var used_fallback := false
var error := ""
var _cache := {}

func cache_key(id: String) -> String:
	var path := directory.path_join(id + ".inkbp")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return "%s:%d:%d" % [path, FileAccess.get_modified_time(path), file.get_length()]

func list_all() -> Array:
	var result: Array = []
	var folder := DirAccess.open(directory)
	if folder == null:
		return result
	var present := {}
	for file in folder.get_files():
		if file.ends_with(".inkbp"):
			present[directory.path_join(file)] = true
			var data := read(file.get_basename())
			if not data.is_empty():
				result.append(data)
	for path in _cache.keys():
		if path.get_base_dir() != directory or not present.has(path):
			_cache.erase(path)
	result.sort_custom(func(a, b): return int(a.updated) > int(b.updated))
	return result

func valid_id(id: String) -> bool:
	return not id.is_empty() and id.length() <= 80 and id.is_valid_filename() \
		and not id.contains(".") and not id.contains("/") and not id.contains("\\")

func read(id: String) -> Dictionary:
	error = ""
	if not valid_id(id):
		return {}
	var path := directory.path_join(id + ".inkbp")
	var signature := cache_key(id)
	if _cache.has(path) and _cache[path].signature == signature:
		return _cache[path].data.duplicate(true)
	var file := FileAccess.open(directory.path_join(id + ".inkbp"), FileAccess.READ)
	if file == null or file.get_length() > MAX_FILE_BYTES:
		return {}
	var data = JSON.parse_string(file.get_as_text())
	if data is Dictionary and int(data.get("version", 0)) < VERSION:
		var source_version := int(data.get("version", 0))
		if source_version == 1:
			data = migrate_v1(data)
		if source_version < 3:
			data = migrate_v2(data)
		data = migrate_v3(data)
		if validate(data) and data.id == id:
			save(data, true)
	if not data is Dictionary or not validate(data) or data.id != id:
		error = "蓝图损坏或版本不受支持"
		return {}
	_cache[path] = {"signature": signature, "data": data.duplicate(true)}
	return data

## 确保目标目录存在；项目内目录不可写（导出后 res:// 只读）时回退到用户目录。
func ensure_directory() -> bool:
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory)) == OK:
		return true
	if directory == PROJECT_DIRECTORY:
		directory = FALLBACK_DIRECTORY
		used_fallback = true
		push_warning("蓝图目录 res:// 不可写，已改用 %s" % directory)
		return DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory)) == OK
	return false


func save(data: Dictionary, keep_id := false) -> bool:
	error = ""
	var previous := str(data.get("id", ""))
	# 文件名直接用蓝图名字（重名自动加 _2、_3）。改名时旧文件随后删掉。
	# `keep_id` 只给 v1 迁移用：那种老文件按旧 id 修复格式，不该被顺手改名。
	#
	# ⚠️ `id` 是**记录身份**：`previous` 非空且与新的名字不同，就视为"这条记录改名"，
	#    旧文件会被删除。复用同一个字典保存**另一条**蓝图时，必须先 `data.id = ""`，
	#    否则会意外删掉上一条。
	var stem := previous if keep_id else unique_stem(str(data.get("name", "")), previous)
	if stem.is_empty():
		error = "蓝图名称不能用作文件名"
		return false
	data.id = stem
	data.version = VERSION
	data.updated = int(Time.get_unix_time_from_system())
	if not valid_id(data.id) or not validate(data):
		error = "蓝图数据无效或超出大小限制"
		return false
	var content := JSON.stringify(data)
	if content.to_utf8_buffer().size() > MAX_FILE_BYTES:
		error = "蓝图文件过大"
		return false
	if not ensure_directory():
		error = "无法创建蓝图目录"
		return false
	var absolute := ProjectSettings.globalize_path(directory)
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
	# 改名：新文件已经写好了，再把旧名字的文件删掉。
	if not previous.is_empty() and previous != data.id:
		var stale := absolute.path_join(previous + ".inkbp")
		if FileAccess.file_exists(stale):
			DirAccess.remove_absolute(stale)
		_cache.erase(directory.path_join(previous + ".inkbp"))
	_cache.erase(directory.path_join(data.id + ".inkbp"))
	return true


## 名字直接当文件名：清掉路径分隔符与 Windows 保留字符，再按 id 长度上限截断。
static func file_stem(name: String) -> String:
	var stem := name.strip_edges()
	for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", ".", "\t", "\n"]:
		stem = stem.replace(bad, "_")
	stem = stem.strip_edges().lstrip(".").rstrip(". ")
	if stem.to_upper().begins_with("CON") or stem.to_upper() in ["PRN", "AUX", "NUL"]:
		stem = "_" + stem
	return stem.left(64)


## 同名蓝图不互相覆盖：第二个叫「桥」的落成 `桥_2.inkbp`。
func unique_stem(name: String, previous := "") -> String:
	var base := file_stem(name)
	if base.is_empty():
		return ""
	var candidate := base
	var suffix := 2
	while candidate != previous and FileAccess.file_exists(directory.path_join(candidate + ".inkbp")):
		candidate = "%s_%d" % [base, suffix]
		suffix += 1
	return candidate

func trash(id: String) -> bool:
	if not valid_id(id):
		return false
	var path := ProjectSettings.globalize_path(directory.path_join(id + ".inkbp"))
	# 直接删除文件，蓝图手册里删掉的那张就不会再在目录里留下残骸。
	# 只有删除被拒绝（文件被占用）时才退回改名，避免删不掉又悄悄丢失。
	var removed := DirAccess.remove_absolute(path) == OK
	if not removed:
		removed = DirAccess.rename_absolute(path, path + ".%d.trash" % Time.get_ticks_usec()) == OK
	if removed:
		_cache.erase(directory.path_join(id + ".inkbp"))
	return removed


## 清掉旧版本删除时留下的 `.trash` 残骸；返回清掉的个数。
func purge_trash() -> int:
	var folder := DirAccess.open(directory)
	if folder == null:
		return 0
	var purged := 0
	for file in folder.get_files():
		if file.ends_with(".trash"):
			if DirAccess.remove_absolute(ProjectSettings.globalize_path(directory.path_join(file))) == OK:
				purged += 1
	return purged


## 蓝图对应的存档文件名；手册里直接显示，方便与目录里的文件对上号。
func file_name(id: String) -> String:
	return id + ".inkbp" if valid_id(id) else ""

## 校验逻辑在 blueprint_format.gd；这里保留同名转发，store 内部调用点不用改。
static func number(value) -> bool:
	return Format.number(value)


static func pair(value, limit := 65536.0) -> bool:
	return Format.pair(value, limit)


static func validate(data: Dictionary) -> bool:
	return Format.validate(data)


static func cells_valid(cells, area: int, materials: bool) -> bool:
	return Format.cells_valid(cells, area, materials)


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


## v2 -> v3：中心从裸坐标升级为 {position,radius,material}；
## 轴承记录补齐明确连接（世界 / 蓝图内部支座）与轮体、支座的独立局部点。
static func migrate_v2(source: Dictionary) -> Dictionary:
	var data := source.duplicate(true)
	data.version = VERSION
	data["gear_centers"] = _migrate_centers(data.get("gear_centers", []))
	for body in data.get("bodies", []):
		body["gear_centers"] = _migrate_centers(body.get("gear_centers", []))
	for gear in data.get("gears", []):
		if not gear is Dictionary:
			continue
		gear["wheel_point"] = gear.get("wheel_point", gear.get("point", [0, 0]))
		gear["support_point"] = gear.get("support_point", gear.get("point", [0, 0]))
		gear["world"] = bool(gear.get("world", int(gear.get("support", -1)) < 0))
		gear["legacy"] = bool(gear.get("legacy", true))
		gear["support_material"] = int(gear.get("support_material", 0))
	return data


static func _migrate_centers(raw) -> Array:
	var out: Array = []
	if not raw is Array:
		return out
	for entry in raw:
		if entry is Dictionary:
			var position = entry.get("position")
			if position is Vector2:
				position = [position.x, position.y]
			if position is Array and position.size() == 2:
				out.append({"position": [float(position[0]), float(position[1])],
					"radius": float(entry.get("radius", 48.0)),
					"material": int(entry.get("material", 0)),
					"id": int(entry.get("id", 0))})
		elif entry is Array and entry.size() == 2:
			out.append({"position": [float(entry[0]), float(entry[1])],
				"radius": 48.0, "material": 0, "id": 0})
		elif entry is Vector2:
			out.append({"position": [entry.x, entry.y], "radius": 48.0, "material": 0, "id": 0})
	return out


## v3 -> v4：草稿手动轴承独立保存；旧蓝图没有轴承就保持自由，绝不推导补轴。
static func migrate_v3(source: Dictionary) -> Dictionary:
	var data := source.duplicate(true)
	data.version = VERSION
	data["draft_bearings"] = data.get("draft_bearings", [])
	return data
