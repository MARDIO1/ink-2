extends RefCounted
## 一次蓝图放置会话：幽灵预览、落点、合法性预检、提交。
##
## **不画 UI**：提示条、暂停、工具切换都留在调用方（`blueprint_system.gd`）。
## 提交只经过 `blueprint_place.gd`，所以"检查 → 提交"仍然只有一个入口。

const Codec := preload("res://actor/canvas/blueprint/src/blueprint_codec.gd")
const Place := preload("res://blueprint/src/blueprint_place.gd")
const Ghost := preload("res://actor/canvas/blueprint/blueprint_ghost.tscn")

var canvas
var data: Dictionary = {}
var ghost: Node2D
var offset := Vector2i.ZERO
var amounts: Dictionary = {}
var footprint: Dictionary = {}
var error := ""
var check_elapsed := 1.0


## 建幽灵并挂到画布表面。调用方负责预先校验蓝图数据。
func begin(target, blueprint: Dictionary) -> bool:
	if target == null or not is_instance_valid(target) or blueprint.is_empty():
		return false
	canvas = target
	data = blueprint.duplicate(true)
	amounts = Codec.costs(data)
	footprint = Codec.footprint(data)
	ghost = Ghost.instantiate()
	ghost.texture = ImageTexture.create_from_image(Codec.preview(data))
	ghost.extent = Codec.vec(data.size)
	ghost.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	ghost.z_index = 50
	canvas.surface.add_child(ghost)
	check_elapsed = 1.0
	return true


func is_active() -> bool:
	return is_instance_valid(ghost)


func cancel() -> void:
	if is_instance_valid(ghost):
		ghost.queue_free()
	ghost = null
	data = {}
	amounts = {}
	footprint = {}
	error = ""


## 用**屏幕坐标**更新幽灵位置。合法性按 ~8 Hz 节流；提交时 `place()` 仍会完整复查。
func update(delta: float, screen_point: Vector2) -> void:
	if not is_active():
		return
	var surface = canvas.surface
	var point: Vector2 = surface.get_global_transform_with_canvas().affine_inverse() * screen_point
	offset = Vector2i((point - Codec.vec(data.size) * 0.5).round())
	ghost.position = Vector2(offset)
	check_elapsed += delta
	if check_elapsed >= 0.12:
		error = Place.placement_error(canvas, data, offset, amounts, footprint)
		check_elapsed = 0.0
	ghost.allowed = error.is_empty()
	ghost.queue_redraw()


## 提交这次放置。返回错误字符串，空串表示成功。
func commit() -> String:
	if not is_active():
		return "放置已取消"
	return Place.place(canvas, data, offset)


## 幽灵左上角的屏幕坐标；提示条据此贴边显示。
func ghost_corner_screen() -> Vector2:
	if not is_active():
		return Vector2.ZERO
	return ghost.get_global_transform_with_canvas() * Vector2.ZERO
