extends RefCounted
## 用户新建地图的**写盘**：复制空白模板、换资源身份、挑一个没占用的文件名。
##
## 只有用户按下"新建地图"才会被调用；浏览目录永远不写文件。
## 行为与迁移前一致（编号 新地图1..999，跳过已存在的文件）。

const BLANK_TEMPLATE := "res://map/asset/blank_level.tscn"
const NEW_MAP_DIR := "res://map/asset/imported"


## 复制空白模板成一张新关卡，返回新路径；失败返回空串。
static func create_blank_map() -> String:
	var source := FileAccess.get_file_as_string(BLANK_TEMPLATE)
	if source.is_empty():
		push_error("关卡选择：读不到空白地图模板 %s" % BLANK_TEMPLATE)
		return ""
	# 复制出来的场景必须换一个资源身份，否则两张场景共用一个 uid。
	source = strip_scene_uid(source)
	if not DirAccess.dir_exists_absolute(NEW_MAP_DIR):
		var err := DirAccess.make_dir_recursive_absolute(NEW_MAP_DIR)
		if err != OK:
			push_error("关卡选择：建不了目录 %s（%d）" % [NEW_MAP_DIR, err])
			return ""
	for index in range(1, 1000):
		var path := "%s/新地图%d.tscn" % [NEW_MAP_DIR, index]
		if FileAccess.file_exists(path):
			continue
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			push_error("关卡选择：写不了 %s（%d）" % [path, FileAccess.get_open_error()])
			return ""
		file.store_string(source)
		file.close()
		return path
	push_error("关卡选择：新地图编号用完了")
	return ""


## 去掉 `[gd_scene ... uid="..."]` 头里的 uid，让复制品拿到新身份。
static func strip_scene_uid(source: String) -> String:
	var newline := source.find("\n")
	if newline < 0:
		return source
	var header := source.substr(0, newline)
	if not header.begins_with("[gd_scene"):
		return source
	var start := header.find(" uid=\"")
	if start < 0:
		return source
	var end := header.find("\"", start + 6)
	if end < 0:
		return source
	return header.substr(0, start) + header.substr(end + 1) + source.substr(newline)
