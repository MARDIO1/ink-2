extends RefCounted
## 画布快照的后台写盘：整图 PNG 编码放 WorkerThreadPool，主线程只拷一份内存。
##
## 4352x1328 实测编码 120~160 ms —— 放主线程就是每笔卡十帧。
## 这里只管"拷图 → 排队 → 轮询完成"，画布内容仍由 canvas_surface 提供。

## 任务句柄；-1 表示当前没有在写。
var _task := -1
var _path := ""
var _again := false


## 请后台把当前画布写进快照；上一个任务没写完时，新请求合并成一次补写。
func request(surface, path: String) -> void:
	if surface.black_image == null:
		return
	_path = path
	_again = true
	_start(surface)


func _start(surface) -> void:
	if _task != -1 or not _again:
		return
	_again = false
	var copy := Image.new()
	copy.copy_from(surface.black_image)
	_task = WorkerThreadPool.add_task(
		_write.bind(copy, _path, metadata(surface)), false, "canvas snapshot")


## 主线程每帧调用；写完后如果期间又来过请求，就再补写一次。
func poll(surface) -> void:
	if _task == -1 or not WorkerThreadPool.is_task_completed(_task):
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	_start(surface)


## 退出场景时把还在写的任务等完，避免线程碰已释放的图像。
func cancel_wait() -> void:
	if _task == -1:
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1


func busy() -> bool:
	return _task != -1


## 主线程只捕获副本；PNG 编码交由后台任务完成。
static func metadata(surface) -> Dictionary:
	var rule = surface.yellow_rule()
	return {"rod": surface.rod_layer.pixels.duplicate(),
		"anchors": surface.rod_layer.anchor_points.duplicate(),
		"gear_centers": surface.gear_centers.duplicate(true),
		"draft_bearings": surface.draft_bearings.duplicate(true),
		"rails": surface.rod_layer.rails.duplicate(true),
		"slider_pins": surface.rod_layer.slider_pins.duplicate(true),
		"springs": rule.draft_data(surface).duplicate(true) if rule != null else [],
		"blue": surface.blue_layer.cells.duplicate(),
		"motors": surface.blue_rule().draft_data(surface).duplicate(true) if surface.blue_rule() != null else []}


## 线程只操作捕获的图像/元数据副本；后台快照也保留轴心与机关信息。
## `INK2` 头 + `store_var` 的元数据，最后整体改名，避免中途写坏旧快照。
static func _write(image: Image, path: String, meta: Dictionary) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	var temporary := absolute + ".tmp"
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		push_error("Canvas snapshot open failed: %s (%d)" % [path, FileAccess.get_open_error()])
		return
	meta["black"] = image.save_png_to_buffer()
	meta["rod"] = meta.rod.save_png_to_buffer()
	file.store_buffer("INK2".to_ascii_buffer())
	file.store_var(meta)
	file.flush()
	file.close()
	if FileAccess.file_exists(path) and DirAccess.remove_absolute(absolute) != OK:
		DirAccess.remove_absolute(temporary)
		return
	DirAccess.rename_absolute(temporary, absolute)
