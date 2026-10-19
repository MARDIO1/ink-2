extends RefCounted
## 导出版内容路径：地图和蓝图库可以放在 exe 旁边，其他依赖仍从 PCK 读取。
##
## 编辑器里继续使用 res://，这样地图编辑器和资源自动重载保持原有行为；
## 导出版里只把 map/blueprints 的逻辑路径解析到可写内容目录。

static func is_external() -> bool:
	return not OS.has_feature("editor") or OS.get_cmdline_user_args().has("--external-content")


static func base_dir() -> String:
	if is_external():
		return OS.get_executable_path().get_base_dir()
	return ProjectSettings.globalize_path("res://")


## 只在导出版把存在的 res:// 文件优先解析为 exe 旁边的真实文件。
static func resolve(path: String) -> String:
	if not is_external() or not path.begins_with("res://"):
		return path
	var external := base_dir().path_join(path.trim_prefix("res://"))
	return external if FileAccess.file_exists(external) else path


static func resource_exists(path: String, type_hint := "") -> bool:
	var resolved := resolve(path)
	if resolved != path and FileAccess.file_exists(resolved):
		return true
	if type_hint.is_empty():
		return FileAccess.file_exists(resolved) or ResourceLoader.exists(resolved)
	return ResourceLoader.exists(resolved, type_hint)


static func external_map_dir() -> String:
	return base_dir().path_join("map") if is_external() else ""


static func writable_map_dir() -> String:
	if is_external():
		return external_map_dir().path_join("asset/imported")
	return "res://map/asset/imported"


## 把扫描得到的 exe 旁绝对路径还原成选关/传送门共用的 res:// 逻辑路径。
static func to_res_path(path: String) -> String:
	if not is_external() or path.begins_with("res://"):
		return path
	var base := base_dir().replace("\\", "/").trim_suffix("/")
	var normalized := path.replace("\\", "/")
	if normalized.begins_with(base + "/"):
		return "res://" + normalized.substr(base.length() + 1)
	return path
