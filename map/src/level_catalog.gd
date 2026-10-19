extends RefCounted
## 关卡目录的**纯查询**：正式页顺序、扫描 `res://map`、判断"这是不是一关"。
##
## 不实例化地图、不写盘、不建按钮。选关界面只负责显示，Portal 只问"下一关是谁"。
## 行为与迁移前完全一致；路线与去重规则见 `doc/architecture_split_rules_2026-10-18.md` §5。

const LEVEL_DIR := "res://map"
const PLAYER_NODE := "Player"
## 空白模板自己不是关卡，不进程列表。
const BLANK_TEMPLATE := "res://map/asset/blank_level.tscn"
## Peak 独立入口：不参与纸页传送路线。
const PEAK := "res://map/asset/imported/peak.tscn"
## 正式页：按阅读顺序。
const LEVEL_PATHS: Array[String] = [
	"res://map/asset/imported/扉页.tscn",
	"res://map/asset/imported/第一页.tscn",
	"res://map/asset/imported/第三页.tscn",
	"res://map/asset/imported/peak.tscn",
]


## 返回正式地图；开发测试夹具不进入玩家目录。
## 顺序固定为：正式页（扉页/第一页/第三页/Peak，按阅读顺序） → 自建关卡（按路径）。
## Peak 只是"不参与翻页路线"，在列表里仍紧随三页之后，排在自建关卡之前。
static func find_levels() -> PackedStringArray:
	var found := PackedStringArray()
	for path in LEVEL_PATHS:
		if found.has(path):
			continue
		if ResourceLoader.exists(path, "PackedScene") and is_level(path):
			found.append(path)
	for path in scan_map_levels():
		if found.has(path):
			continue
		found.append(path)
	return found


## 递归扫 res://map，收所有带 Player 的 .tscn；空白模板自己不算关卡。
static func scan_map_levels() -> PackedStringArray:
	var result := PackedStringArray()
	var pending: Array[String] = [LEVEL_DIR]
	while not pending.is_empty():
		var directory: String = pending.pop_back()
		var dir := DirAccess.open(directory)
		if dir == null:
			continue
		for name in dir.get_directories():
			pending.append(directory.path_join(name))
		for name in dir.get_files():
			# 导出包里只有编译场景（`x.tscn.remap`）；归一成 `x.tscn` 再统一验证，
			# 避免源码场景与导出场景被当成两张不同的关卡。
			var normalized := name.trim_suffix(".remap")
			if not normalized.ends_with(".tscn"):
				continue
			var path := directory.path_join(normalized)
			if result.has(path):
				continue
			if path == BLANK_TEMPLATE or not is_level(path):
				continue
			result.append(path)
	result.sort()
	return result


## 路线固定为 扉页 → 第一页 → 第三页；第三页与 Peak 都没有自动下一关。
static func next_level(current: String) -> String:
	var index := LEVEL_PATHS.find(current)
	if index < 0 or index >= 2:
		return ""
	var destination := LEVEL_PATHS[index + 1]
	if destination == PEAK:
		return ""
	return destination if ResourceLoader.exists(destination, "PackedScene") else ""


## 真关卡的判据：场景里有一个叫 `Player` 的节点。只看结构，不实例化、不进游戏。
static func is_level(path: String) -> bool:
	# 不先问 `ResourceLoader.exists`：它为了判断类型会去加载，场景有解析错误时会返回 false，
	# 于是"这关存不存在"就变成了"这关能不能加载"。这里只看文件里的节点名。
	# 关卡列表只需要判断节点名。逐行读取并在找到 Player 后立即停止，避免为了显示
	# 菜单就把每个大型地图完整解析进 ResourceLoader 缓存。
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		# PCK 内不保留源 .tscn：读取编译场景的结构，不实例化关卡。
		var packed = ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		if packed != null:
			var state := packed.get_state()
			for index in state.get_node_count():
				if String(state.get_node_name(index)) == PLAYER_NODE:
					return true
		return false
	var found := false
	while not file.eof_reached():
		var line := file.get_line()
		if line.begins_with("[node ") and line.contains("name=\"" + PLAYER_NODE + "\""):
			found = true
			break
	file.close()
	return found
