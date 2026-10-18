extends RefCounted
## 画布撤销日志：步骤栈、重做栈，以及"一次操作"期间的像素/图层快照。
##
## 只做**记录**，不做还原——`undo_last_edit` / `redo_last_edit` 仍由画布执行，
## 因为它们要协调工具取消、选区取消、图层刷新和场景历史。
##
## 一个 surface 一份。所有方法第一个参数是 surface：它提供像素与各图层。

const InkPalette := preload("res://ink/general/src/ink_palette.gd")
const GearCenters := preload("res://actor/canvas/src/gear_centers.gd")

const MAX_STEPS := 64

## 步骤栈（旧 → 新）；超过上限丢最旧的。
var _steps: Array[Dictionary] = []
## 重做栈：`{"undo": step, "after": <重做前状态>}`。
var _redo: Array[Dictionary] = []
## 正在进行的那一次操作的快照：像素 → 原颜色，外加 gear_centers / draft_bearings / nails / blue。
var _capture: Dictionary = {}
var _capturing := false
var _nail := {}
var _blue := {}
var _gear: Dictionary = {}


## 开始一次操作：记下钉子、轴心与蓝墨的当前状态，供 commit 时比对。
func begin(surface) -> void:
	if not _capturing and surface.blue_layer != null:
		var rule = surface.blue_rule()
		_blue = {"cells": surface.blue_layer.cells.duplicate(),
			"motors": rule.capture(surface) if rule != null else [],
			"ledger": surface.ink_px_of(InkPalette.BLUE.id)}
	_capture = {}
	_nail = surface.nail_layer.snapshot()
	_gear = {"centers": surface.gear_centers.duplicate(true),
		"bearings": surface.draft_bearings.duplicate(true)}
	_capturing = true


## 记一个像素的原始颜色（同一次操作只记第一次）。
func track(surface, pixel: Vector2i) -> void:
	if not _capturing or _capture.has(pixel):
		return
	_capture[pixel] = surface.black_image.get_pixelv(pixel)


## 墨水桶整图替换时直接给一份原图字节，比逐像素字典省得多。
func capture_bucket_before(surface, data: PackedByteArray, material_id: int,
		count: int) -> void:
	if not _capturing:
		return
	_capture = {"bucket_before": data, "bucket_material": material_id, "bucket_count": count}


## 黄墨填充属于独立杆层，沿用杆层步骤以支持撤销、重做和返还墨水。
func capture_rod_bucket_before(surface, cells: PackedInt32Array) -> void:
	if not _capturing:
		return
	var before := {}
	for index: int in cells:
		before[Vector2i(index % surface.canvas_size.x, index / surface.canvas_size.x)] = false
	_capture = {"rod_pixels": before,
		"rod_anchors": surface.rod_layer.anchor_points.duplicate(), "rod_delta": cells.size()}


## 结束一次操作：把有变化的部分合成一个步骤压栈；没有变化就不留步骤。
func commit(surface, rod_step: Dictionary = {}) -> void:
	if not _capturing:
		return
	_capturing = false
	if surface.nail_layer.snapshot() != _nail:
		_capture["nails"] = _nail
	_nail = {}
	if not _gear.is_empty():
		if surface.gear_centers != _gear.centers:
			_capture["gear_centers"] = GearCenters.normalize(_gear.centers)
		if surface.draft_bearings != _gear.bearings:
			_capture["draft_bearings"] = _gear.bearings.duplicate(true)
	_gear = {}
	var rule = surface.blue_rule()
	if not _blue.is_empty() and (surface.blue_layer.cells != _blue.cells \
			or surface.ink_px_of(InkPalette.BLUE.id) != _blue.ledger \
			or (rule != null and rule.draft_data(surface).size() != _blue.motors.size())):
		_capture["blue"] = _blue
	_blue = {}
	if _capture.is_empty() and rod_step.is_empty():
		_capture = {}
		return
	if rod_step.is_empty():
		push(surface, _capture)
	else:
		if not _capture.is_empty():
			rod_step["black_pixels"] = _capture.duplicate()
		push(surface, rod_step)
	_capture = {}


## 压入一步并清空重做栈（新操作会让"未来"作废）。
func push(surface, step: Dictionary) -> void:
	_steps.append(step)
	_redo.clear()
	if _steps.size() > MAX_STEPS:
		_steps.pop_front()
	surface.edit_committed.emit()


## 放弃进行中的那一次操作（工具被取消、指针离开画布等）。
func cancel() -> void:
	_capture = {}
	_nail = {}
	_gear = {}
	_capturing = false


func empty_undo() -> bool:
	return _steps.is_empty()


func empty_redo() -> bool:
	return _redo.is_empty()


func pop_undo() -> Dictionary:
	return _steps.pop_back()


func pop_redo() -> Dictionary:
	return _redo.pop_back()


func push_redo(entry: Dictionary) -> void:
	_redo.append(entry)


## 清空两套栈（关卡重新加载时用）。
func clear() -> void:
	_steps.clear()
	_redo.clear()
	_capture = {}
	_capturing = false
	_nail = {}
	_blue = {}
	_gear = {}


func top() -> Dictionary:
	return _steps.back() if not _steps.is_empty() else {}


func undo_depth() -> int:
	return _steps.size()
