extends RefCounted
## 与节点树和 UI 无关的编辑时间线；失败操作不丢栈，重放期间不接受新记录。
signal changed
signal recorded(edit: Dictionary)
var undo_stack: Array[Dictionary] = []
var redo_stack: Array[Dictionary] = []
var limit := 128
var replaying := false
var capture: Callable
var undo_command: Callable
var redo_command: Callable
var dispose: Callable

func record(edit: Dictionary) -> void:
	if replaying:
		return
	for item in redo_stack:
		dispose.call(item.edit)
	redo_stack.clear()
	undo_stack.append(edit)
	if undo_stack.size() > limit:
		dispose.call(undo_stack.pop_front())
	recorded.emit(edit)
	changed.emit()

func undo() -> bool:
	if replaying or undo_stack.is_empty():
		return false
	replaying = true
	var edit: Dictionary = undo_stack.pop_back()
	var data: Dictionary = capture.call(edit)
	var ok: bool = undo_command.call(edit)
	if ok:
		redo_stack.append({"edit": edit, "data": data})
	else:
		undo_stack.append(edit)
	replaying = false
	if ok:
		changed.emit()
	return ok

func redo() -> bool:
	if replaying or redo_stack.is_empty():
		return false
	replaying = true
	var item: Dictionary = redo_stack.pop_back()
	var ok: bool = redo_command.call(item.edit, item.data)
	if ok:
		undo_stack.append(item.edit)
	else:
		redo_stack.append(item)
	replaying = false
	if ok:
		changed.emit()
	return ok

func rebind(old_target, restored: Node) -> void:
	for entry in undo_stack:
		if entry.has("target") and entry.target == old_target:
			entry.target = restored
	for item in redo_stack:
		if item.edit.has("target") and item.edit.target == old_target:
			item.edit.target = restored

func clear() -> void:
	for edit in undo_stack:
		dispose.call(edit)
	for item in redo_stack:
		dispose.call(item.edit)
	undo_stack.clear()
	redo_stack.clear()
