#画布表面：负责黑色墨水的像素缓冲、鼠标绘制/擦除与渲染
#1 像素 = 1 世界单位，本版本只做可见像素，不进入物理世界

#region 依赖
@tool
extends Area2D

signal selection_delete_requested(rect: Rect2i)

signal edit_committed

const InkPalette := preload("res://ink/general/src/ink_palette.gd")
#endregion

#region 初始化
## 黑墨瓦片边长。整张画布仍是一张 CPU Image，但上传按瓦片走：4352x1328 的整图
## 重传实测 2.5 ms/次（22 MB），而一笔只碰到一两块 512 瓦片（每块约 0.1 ms）。
const TILE_SIZE := 512
## 瓦片键（画布坐标 / TILE_SIZE）-> {"image": Image, "texture": ImageTexture, "sprite": Sprite2D}。
## 只有真的画到某块时才建 —— 空画布一张贴图都不占，也不上传。
var _tiles := {}
## 尚未上传的像素范围（闭区间；lo > hi 表示没有脏像素）。
var _dirty_lo := Vector2i(1 << 30, 1 << 30)
var _dirty_hi := Vector2i(-(1 << 30), -(1 << 30))
@onready var black_tiles: Node2D = $BlackTiles
@onready var nail_layer: Node2D = $NailLayer
@onready var bounds: CollisionShape2D = $Bounds
@onready var blue_layer: Node2D = $BlueWireLayer
@onready var rod_layer: Node2D = $YellowRodLayer
var _rod_drawing := false
func _ready() -> void:
	black_tiles.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	_resize()
	# 地图编辑快照由 Creative 在首次进入编辑器时按需恢复；游戏启动时不读盘。


# ⚠️ 后台写盘任务必须等回来：它的 Callable 是 static、只带一份 Image 副本，
#    但节点先被释放而任务还在写文件时，退出过程会读到写了一半的快照。
func _exit_tree() -> void:
	if _snapshot_task != -1:
		WorkerThreadPool.wait_for_task_completion(_snapshot_task)
		_snapshot_task = -1
#endregion


#region 外观
## 表面宽高，单位 px；由父 Canvas 的 canvas_size 同步，直接修改父节点即可。
@export var canvas_size := Vector2i(256, 256):
	set(value):
		canvas_size = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
		if is_node_ready():
			_resize()
## 纸底颜色；只影响显示，不属于可固化墨水。
@export var background_color := Color(0.86, 0.85, 0.80, 1.0):
	set(value):
		background_color = value
		queue_redraw()
## 纸张底图；绘制时按原始尺寸循环平铺，画布扩展后会自动补齐。
@export var background_texture: Texture2D:
	set(value):
		background_texture = value
		queue_redraw()
## 画布边框颜色；只影响显示。
@export var border_color := Color(0.12, 0.12, 0.12, 1.0):
	set(value):
		border_color = value
		queue_redraw()
## 画布边框线宽，单位 px。
@export var border_width := 2.0
## 地图编辑自动保存使用的快照路径；由 Creative 按需恢复。
@export_file("*.res", "*.tres") var saved_ink_path := ""

#纸底和边框由表面画，黑色墨水由 BlackTiles 的瓦片盖在上面
func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, Vector2(canvas_size))
	draw_rect(rect, background_color, true)
	if background_texture != null:
		draw_texture_rect(background_texture, rect, true)
	draw_rect(rect, border_color, false, border_width)
#endregion


#region 输入
#原生引擎回调，处理鼠标左键右键
func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseButton:
		# 工具栏是屏幕固定 GUI，但本节点使用全局输入；若不主动拦截，按钮点击会同时
		# 穿透到背后的世界画布。松开事件仍要放行，用来正确结束已开始的笔画/形状。
		if event.pressed and get_viewport().gui_get_hovered_control() != null:
			return
		_on_mouse_button(event as InputEventMouseButton)


#摄像机移动不会产生 MouseMotion，因此按住画笔时每帧按世界坐标补线。
func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_poll_snapshot()
	var blue = blue_rule()
	if blue != null and blue.drawing != null and blue.drawing.source_surface == self:
		blue.extend(self, _mouse_point())
		return
	if blue_layer.drawing:
		blue_layer.extend(_mouse_point().clamp(Vector2.ZERO, Vector2(canvas_size) - Vector2.ONE))
		return
	if _rod_drawing:
		rod_layer.extend(_mouse_point().clamp(Vector2.ZERO, Vector2(canvas_size) - Vector2.ONE))
		return
	var yellow = yellow_rule()
	if yellow != null and yellow.drawing != null and yellow.drawing.source_surface == self:
		yellow.extend(self, _mouse_point())
		return
	if _selecting:
		_update_selection()
	elif _shaping:
		_update_shape()
	elif _painting:
		_continue_stroke()

## 工具：普通手不落笔；画笔/橡皮擦/钉子按笔刷落笔；矩形与圆形画**外框**；
## 直线按拖拽起终点绘制；墨水桶灌满封闭空区。LINE 追加在末尾以保持旧地图工具枚举值兼容。
enum Tool { HAND, BRUSH, ERASER, NAIL, RECT, CIRCLE, BUCKET, SELECT_DELETE, LINE }

var _painting := false #状态机
var _paint_color := Color.TRANSPARENT
var _last_point := Vector2.ZERO
var _undo_steps: Array[Dictionary] = []
var _undo_capture := {}
var _undo_capturing := false
var _blue_undo := {}
const MAX_UNDO_STEPS := 64
## 框选删除只负责交互与预览；真正删除由 Canvas 完成，因为固化实体属于 PixelWorld。
var _selecting := false
var _selection_origin := Vector2.ZERO
@onready var selection_overlay: Node2D = $SelectionOverlay
# 墨水桶一次保留的最大像素数。允许灌到画布边缘，但不能让误点把超大地图
# 整张扫描进内存而卡住编辑器。
const MAX_BUCKET_PIXELS := 250000
## 形状拖拽中：起点、预览期间被改过的像素（原色）、本次新增的墨水量。
var _shaping := false
var _shape_origin := Vector2.ZERO
var _shape_saved := {}
var _shape_delta := 0
## 当前工具；切换时中断正在进行的笔画或形状。
@export var tool: Tool = Tool.HAND:
	set(value):
		if _rod_drawing:
			rod_layer.finish(rod_layer.last_point)
			_rod_drawing = false
		if is_node_ready() and not Engine.is_editor_hint():
			var yellow = yellow_rule()
			if yellow != null and yellow.drawing != null and yellow.drawing.source_surface == self:
				yellow.cancel()
		if _selecting:
			_cancel_selection()
		if _shaping:
			_revert_shape()
			_cancel_undo_step()
		elif _painting:
			_commit_undo_step()
		if is_node_ready():
			_finish_blue_edit()
		tool = value
		_painting = false
		_shaping = false
## 当前选中的墨水（`ink/general/src/ink_palette.gd` 的 INKS 下标）；右侧面板改它。
@export var selected_ink: int = 0:
	set(value):
		if selected_ink != value and is_node_ready():
			if _rod_drawing:
				rod_layer.finish(rod_layer.last_point)
				_rod_drawing = false
			var yellow = yellow_rule()
			if yellow != null and yellow.drawing != null and yellow.drawing.source_surface == self:
				yellow.cancel()
		if is_node_ready() and selected_ink != value:
			_finish_blue_edit()
		selected_ink = value


## 当前墨水的画布颜色。
func ink_color() -> Color:
	return InkPalette.color_at(selected_ink)


## 当前墨水的材质 id。
func ink_material_id() -> int:
	return InkPalette.material_id_of(InkPalette.ink_at(selected_ink))


## 钉子像素颜色。钉子不是墨水，只有这一种。
func nail_color() -> Color:
	return InkPalette.nail_color()


func _is_nail(color: Color) -> bool:
	return color == nail_color()


func _on_mouse_button(button: InputEventMouseButton) -> void:
	var blue = blue_rule()
	if button.button_index == MOUSE_BUTTON_LEFT and blue != null:
		if not button.pressed and blue_layer.drawing:
			blue_layer.finish()
			return
		if not button.pressed and blue.drawing != null and blue.drawing.source_surface == self:
			blue.finish(self, _mouse_point())
			return
		if button.pressed and ink_material_id() == InkPalette.BLUE.id and tool in [Tool.BRUSH, Tool.LINE, Tool.RECT, Tool.CIRCLE, Tool.BUCKET, Tool.NAIL]:
			if _inside(_mouse_point()):
				if tool == Tool.LINE:
					blue.begin(self, _mouse_point())
				elif tool == Tool.BRUSH:
					blue_layer.begin(_mouse_point())
			return
	var yellow = yellow_rule()
	if button.button_index == MOUSE_BUTTON_LEFT and yellow != null:
		if not button.pressed and _rod_drawing:
			rod_layer.finish(_mouse_point().clamp(Vector2.ZERO, Vector2(canvas_size) - Vector2.ONE))
			_rod_drawing = false
			return
		if not button.pressed and yellow.drawing != null and yellow.drawing.source_surface == self:
			yellow.finish(self, _mouse_point())
			return
		if button.pressed and ink_material_id() == InkPalette.YELLOW.id:
			if tool == Tool.ERASER and _inside(_mouse_point()) and rod_layer.erase_anchor(_mouse_point()):
				return
			if tool in [Tool.BRUSH, Tool.ERASER] and _inside(_mouse_point()):
				_rod_drawing = true
				rod_layer.begin(_mouse_point(), tool == Tool.ERASER)
				return
			if tool == Tool.LINE:
				yellow.begin(self, _mouse_point())
				return
			if tool == Tool.CIRCLE:
				if _inside(_mouse_point()):
					rod_layer.place_anchor(_mouse_point())
				return
			if tool in [Tool.RECT, Tool.BUCKET, Tool.NAIL]:
				return
		if not button.pressed and ink_material_id() == InkPalette.YELLOW.id and tool == Tool.CIRCLE:
			return
	if button.button_index == MOUSE_BUTTON_MIDDLE:
		if ink_material_id() == InkPalette.YELLOW.id:
			return
		_painting = false
		if button.pressed:
			_begin_undo_step()
			_place_nail(_mouse_point())
			_commit_undo_step()
		return
	if button.button_index != MOUSE_BUTTON_LEFT:
		return
	if not button.pressed:
		if _selecting:
			_finish_selection()
			return
		if _shaping:
			_end_shape()
			_commit_undo_step()
		elif _painting:
			_commit_undo_step()
		_painting = false
		return
	var point := _mouse_point()
	if not _inside(point):
		return
	if tool == Tool.SELECT_DELETE:
		_selecting = true
		_selection_origin = point
		_update_selection()
		return
	#墨水桶是点击工具：按下即灌满所在空区。
	if tool == Tool.BUCKET:
		_begin_undo_step()
		_bucket_fill(point)
		_commit_undo_step()
		return
	#矩形/圆形/直线是拖拽工具：按下定起点，拖拽出形状，松手定型。
	if tool == Tool.RECT or tool == Tool.CIRCLE or tool == Tool.LINE:
		_begin_undo_step()
		_shaping = true
		_shape_origin = point
		_update_shape()
		return
	var color = _stroke_color()
	if color == null:
		return
	_painting = true
	_begin_undo_step()
	_paint_color = color
	_last_point = point
	_stroke(point, point, color)


## 当前工具左键落笔的颜色；null 表示这个工具不落笔。
func _stroke_color():
	match tool:
		Tool.BRUSH:
			return ink_color()
		Tool.ERASER:
			return Color.TRANSPARENT
		Tool.NAIL:
			return nail_color()
	return null

func blue_rule():
	return get_node_or_null("../../SimulationRuntime/BlueInk")

func _finish_blue_edit() -> void:
	if blue_layer != null and blue_layer.drawing:
		blue_layer.finish()
	var blue = blue_rule()
	if blue != null and blue.drawing != null and blue.drawing.source_surface == self:
		blue.cancel()

func yellow_rule():
	return get_node_or_null("../../SimulationRuntime/YellowInk")


func _continue_stroke() -> void:
	if tool == Tool.HAND:
		_painting = false
		return
	var point := _mouse_point()
	#移出画布时停笔，避免从外侧拖回时突然补一条线
	if not _inside(point):
		_painting = false
		_commit_undo_step()
		return
	_stroke(_last_point, point, _paint_color)
	_last_point = point


##世界坐标转画布本地坐标，之后可直接当像素坐标用
func _mouse_point() -> Vector2:
	return to_local(get_global_mouse_position())

##检测是否在画布内
func _inside(point: Vector2) -> bool:
	return (
		point.x >= 0.0
		and point.y >= 0.0
		and point.x < float(canvas_size.x)
		and point.y < float(canvas_size.y)
	)


func _selection_rect(from: Vector2, to: Vector2) -> Rect2i:
	var first := Vector2i(from.floor()).clamp(Vector2i.ZERO, canvas_size - Vector2i.ONE)
	var last := Vector2i(to.floor()).clamp(Vector2i.ZERO, canvas_size - Vector2i.ONE)
	var position := first.min(last)
	return Rect2i(position, first.max(last) - position + Vector2i.ONE)


func _update_selection() -> void:
	if not _selecting:
		return
	var point := _mouse_point().clamp(Vector2.ZERO, Vector2(canvas_size) - Vector2(0.001, 0.001))
	selection_overlay.set_selection(_selection_rect(_selection_origin, point))


func _finish_selection() -> void:
	if not _selecting:
		return
	var point := _mouse_point().clamp(Vector2.ZERO, Vector2(canvas_size) - Vector2(0.001, 0.001))
	var rect := _selection_rect(_selection_origin, point)
	_cancel_selection()
	selection_delete_requested.emit(rect)


func _cancel_selection() -> void:
	_selecting = false
	if is_instance_valid(selection_overlay):
		selection_overlay.clear_selection()
#endregion


#region 绘制
var black_image: Image
var _preserve_next_resize := false


#region 黑墨瓦片
## 上传脏范围覆盖到的瓦片；没碰到的块一次都不传。
## 契约：改 black_image 之前必须先标脏（_mark_dirty / mark_dirty_rect），
## 否则那部分只活在 CPU 上，画面不动。
func _flush_texture() -> void:
	if _dirty_hi.x < _dirty_lo.x:
		return
	var rect := Rect2i(_dirty_lo, _dirty_hi - _dirty_lo + Vector2i.ONE)
	_dirty_lo = Vector2i(1 << 30, 1 << 30)
	_dirty_hi = Vector2i(-(1 << 30), -(1 << 30))
	_upload_rect(rect)


func _mark_dirty(pixel: Vector2i) -> void:
	_dirty_lo.x = mini(_dirty_lo.x, pixel.x)
	_dirty_lo.y = mini(_dirty_lo.y, pixel.y)
	_dirty_hi.x = maxi(_dirty_hi.x, pixel.x)
	_dirty_hi.y = maxi(_dirty_hi.y, pixel.y)


func mark_dirty_rect(rect: Rect2i) -> void:
	if not rect.has_area():
		return
	_mark_dirty(rect.position)
	_mark_dirty(rect.end - Vector2i.ONE)


## 整张 CPU 图被换掉（读盘、撤销还原、扩展画布）之后重建瓦片：
## 旧瓦片全丢，只按真的有不透明像素的范围重建；空图因此一张贴图都不建。
func rebuild_ink_tiles() -> void:
	_free_tiles()
	var used := black_image.get_used_rect()
	if used.has_area():
		mark_dirty_rect(used)
	_flush_texture()


func _free_tiles() -> void:
	for key in _tiles:
		var sprite: Sprite2D = _tiles[key]["sprite"]
		black_tiles.remove_child(sprite)
		sprite.queue_free()
	_tiles.clear()
	_dirty_lo = Vector2i(1 << 30, 1 << 30)
	_dirty_hi = Vector2i(-(1 << 30), -(1 << 30))


## rect 覆盖到的瓦片键。整图级操作（擦除、重数账本、重建钉子）都从这里出发，
## 空块再交给 _tile_content 判掉 —— 这就是"分治"的粒度。
func _tile_keys(rect: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var last := (canvas_size - Vector2i.ONE) / TILE_SIZE
	var first := (rect.position / TILE_SIZE).max(Vector2i.ZERO)
	var end := ((rect.end - Vector2i.ONE) / TILE_SIZE).min(last)
	for ty in range(first.y, end.y + 1):
		for tx in range(first.x, end.x + 1):
			out.append(Vector2i(tx, ty))
	return out


func _upload_rect(rect: Rect2i) -> void:
	for key in _tile_keys(rect):
		_upload_tile(key, rect)


## 这一块里真的有内容的范围（画布坐标）；整块空返回空矩形。
## 懒算 + 缓存：任何上传都把它置脏，下次问再重算 —— 一次原生 get_used_rect，
## 不用 GDScript 扫。整图操作因此只碰"真的有墨的那一小块"。
func _tile_content(key: Vector2i) -> Rect2i:
	var tile = _tiles.get(key)
	if tile == null:
		return Rect2i()
	if not tile["stale"]:
		return tile["content"]
	var origin := key * TILE_SIZE
	var size := (canvas_size - origin).min(Vector2i(TILE_SIZE, TILE_SIZE))
	var box := Rect2i()
	if size.x > 0 and size.y > 0:
		var content := black_image.get_region(Rect2i(origin, size)).get_used_rect()
		if content.has_area():
			box = Rect2i(origin + content.position, content.size)
	tile["content"] = box
	tile["stale"] = false
	return box


## 画布上所有真的有内容的块范围。整图级重数/重建按它遍历。
func _content_boxes() -> Array[Rect2i]:
	var boxes: Array[Rect2i] = []
	for key in _tile_keys(Rect2i(Vector2i.ZERO, canvas_size)):
		var box := _tile_content(key)
		if box.has_area():
			boxes.append(box)
	return boxes


func _upload_tile(key: Vector2i, rect: Rect2i) -> void:
	var origin := key * TILE_SIZE
	var tile_rect := Rect2i(origin, (canvas_size - origin).min(Vector2i(TILE_SIZE, TILE_SIZE)))
	var hit := rect.intersection(tile_rect)
	if not hit.has_area():
		return
	var tile = _tiles.get(key)
	if tile == null:
		var image := Image.create_empty(tile_rect.size.x, tile_rect.size.y, false, Image.FORMAT_RGBA8)
		image.fill(Color.TRANSPARENT)
		var texture := ImageTexture.create_from_image(image)
		var sprite := Sprite2D.new()
		sprite.centered = false
		sprite.position = Vector2(origin)
		sprite.texture = texture
		black_tiles.add_child(sprite)
		tile = {"image": image, "texture": texture, "sprite": sprite,
			"content": Rect2i(), "stale": true}
		_tiles[key] = tile
	# blit_rect 是原样拷贝（不混合），正好把瓦片对齐到画布坐标。
	var tile_image: Image = tile["image"]
	var tile_texture: ImageTexture = tile["texture"]
	tile_image.blit_rect(black_image, hit, hit.position - origin)
	tile_texture.update(tile_image)
	tile["stale"] = true          # 内容变了：这块的内容框要重算
#endregion


func _resize() -> void:
	# Area 只表达可编辑的画布范围，不参与游戏刚体碰撞。
	bounds.shape.size = Vector2(canvas_size)
	bounds.position = Vector2(canvas_size) * 0.5
	if not _preserve_next_resize:
		_reset()
	if rod_layer != null:
		rod_layer.resize(canvas_size)
	queue_redraw()


## 调整画布时平移并裁切像素与钉子，同时保留墨水账本。
## content_offset 表示旧内容在新画布中的偏移；负值会裁掉对应边缘。
func resize_preserving_content(new_size: Vector2i, content_offset := Vector2i.ZERO) -> bool:
	if new_size.x < 1 or new_size.y < 1:
		return false
	if new_size == canvas_size and content_offset == Vector2i.ZERO:
		return true

	# 先结束未完成的预览，避免扩容后仍引用旧坐标。
	if _shaping:
		_revert_shape()
	_painting = false
	_shaping = false
	var old_blue: PackedVector2Array = blue_layer.cells.duplicate()
	var old_image := black_image
	var old_size := canvas_size
	var old_nails: Array = nail_layer.nails.keys()

	# 属性 setter 仍负责更新碰撞范围，但这一次不能清空像素或退还墨水。
	_preserve_next_resize = true
	canvas_size = new_size
	_preserve_next_resize = false

	blue_layer.mask.clear()
	for point in old_blue:
		var at := Vector2i(point) + content_offset
		if Rect2i(Vector2i.ZERO, new_size).has_point(at):
			blue_layer.mask[at] = true
	blue_layer.refresh()
	blue_layer.build_widths()
	var expanded := Image.create_empty(new_size.x, new_size.y, false, Image.FORMAT_RGBA8)
	expanded.fill(Color.TRANSPARENT)
	expanded.blit_rect(old_image, Rect2i(Vector2i.ZERO, old_size), content_offset)
	black_image = expanded
	rebuild_ink_tiles()
	if rod_layer != null:
		rod_layer.resize(new_size, content_offset)

	nail_layer.clear()
	for nail in old_nails:
		var shifted := Vector2i(nail) + content_offset
		if Rect2i(Vector2i.ZERO, new_size).has_point(shifted):
			nail_layer.add(shifted)
	queue_redraw()
	return true


#重建透明画布，透明像素在纸底下露出来
func _reset() -> void:
	if blue_layer != null:
		blue_layer.clear()
	if rod_layer != null and black_image != null:
		rod_layer.clear()
	_refund_all_ink()                  # 画布被重建：把还挂在画布上的墨水还给瓶子
	black_image = Image.create_empty(canvas_size.x, canvas_size.y, false, Image.FORMAT_RGBA8)
	black_image.fill(Color.TRANSPARENT)
	_free_tiles()
	nail_layer.clear()


#清空画布。
#refund = true：把画布上剩的墨水还回瓶子（"重绘"按钮）。
#refund = false：这些墨水已经随固化变成刚体带走了，不能再还。
func clear(refund := true) -> void:
	if refund and blue_rule() != null:
		blue_rule().clear_drafts(self)
	blue_layer.clear()
	var yellow = yellow_rule()
	if refund and yellow != null:
		yellow.clear_drafts(self)
		rod_layer.clear()
	if refund:
		_refund_all_ink()
	else:
		_flush_ink()                   # 这些墨已经随固化带走了，不能再还
		ink_px_by_material = {}
	black_image.fill(Color.TRANSPARENT)
	_free_tiles()                      # 画布空了：贴图一起丢掉，不用再传一遍空白
	nail_layer.clear()
	queue_redraw()


## 直接写入一个画布像素（"重新回到画布"用）；越界返回 false，批量写入后调 refresh()。
##
## ⚠️ 这里**不碰瓶子**：这些墨水在固化那一刻就已经从瓶里扣过了，再扣一次就是重复记账。
##    但它必须把**画布自己的**账补上 —— 否则这些像素对账本是隐形的，
##    "重绘"就退不回它们（这正是之前的 bug：抓回来的物品，墨水永远回不来）。
func write_pixel(pixel: Vector2i, color: Color) -> bool:
	if pixel.x < 0 or pixel.y < 0 or pixel.x >= canvas_size.x or pixel.y >= canvas_size.y:
		return false
	if InkPalette.material_id_at_color(color) == InkPalette.YELLOW.id:
		var health = _health_node()
		if health != null and not ink_free:
			health.add(InkPalette.YELLOW.id, 1)
		return true
	var before: int = material_at(pixel.x, pixel.y)
	black_image.set_pixelv(pixel, color)
	_mark_dirty(pixel)
	if InkPalette.material_id_at_color(color) == InkPalette.nail_material_id():
		nail_layer.add(pixel)
	else:
		nail_layer.remove(pixel)
	_bump_ink(before, -1, false)
	_bump_ink(InkPalette.material_id_at_color(color), 1, false)
	return true


## 把 CPU 像素缓冲刷到贴图；批量写入后调用一次。
func refresh() -> void:
	_flush_texture()
	_flush_ink()


#两点之间插值补点，避免鼠标移动过快断线
func _stroke(from: Vector2, to: Vector2, color: Color) -> void:
	#画之前先看瓶里还剩多少 px；擦除不设上限，钉子不花墨水。
	var room := 1 << 30
	if color.a > 0.5 and not _is_nail(color):
		room = _ink_room(ink_material_id())
	var delta := 0
	var steps := maxi(1, int(ceil(from.distance_to(to))))
	for i in range(steps + 1):
		delta += _stamp(from.lerp(to, float(i) / float(steps)), color, room - delta)
	_flush_texture()
	blue_layer.flush_display()
	_flush_ink()


## 笔触直径，单位 px；圆形笔刷，绘制和擦除使用同一尺寸。
## 1 = 单像素；偶数直径按半整数半径铺（见 `_stamp`）。
@export var brush_size := 7:
	set(value):
		brush_size = maxi(1, value)
#落一个圆形笔刷；钉子不铺笔刷，只落单像素。
func _stamp(center: Vector2, color: Color, allowance: int) -> int:
	var pixels := {}
	if _is_nail(color):
		pixels[Vector2i(center.floor())] = true
	else:
		_collect_stamp(pixels, center)
	var delta := 0
	for pixel: Vector2i in pixels:
		delta += _write_pixel(pixel, color, allowance - delta)
	return delta


#把笔刷圆盘覆盖到的像素收进 out（只收，不写）。
func _collect_stamp(out: Dictionary, center: Vector2) -> void:
	#直径 1 直接取"点所在的那一格"。
	#⚠️ 不能走下面的距离判定：采样点正好落在**格角**上时（x、y 都是整数），
	#   半径 0.5 够不到任何格心 —— 1px 的线会随机缺格、1px 的圆环会开口，
	#   而开了口的封闭区域会被墨水桶灌满整张画布。
	if brush_size <= 1:
		out[Vector2i(center.floor())] = true
		return
	#⚠️ 半径下限 0.5：直径 1 的笔刷若用半径 0，只有圆心正好压在格心上才落笔，
	#   而鼠标坐标是小数 —— 实测 1px 笔触会"什么都画不出来"。
	var radius := maxf(0.5, (brush_size - 1) * 0.5)
	var r2 := radius * radius
	#⚠️ 边界必须按**真实圆心**推，不能按 roundi(center)：半径是半整数（偶数直径）时
	#   roundi 会把整圈偏一格，实测 3px 笔触只铺出 2x2。
	var x0 := floori(center.x - radius)
	var x1 := ceili(center.x + radius)
	var y0 := floori(center.y - radius)
	var y1 := ceili(center.y + radius)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if x < 0 or y < 0 or x >= canvas_size.x or y >= canvas_size.y:
				continue
			var dx := float(x) + 0.5 - center.x
			var dy := float(y) + 0.5 - center.y
			if dx * dx + dy * dy <= r2:
				out[Vector2i(x, y)] = true


#只改像素 + 同步钉子外观层，不碰任何账本。
func _set_pixel_raw(pixel: Vector2i, color: Color) -> void:
	_track_undo_pixel(pixel)
	if color.a <= 0.5:
		blue_layer.erase(pixel)
		var blue = blue_rule()
		if blue != null:
			blue.erase_draft_anchor(self, pixel)
	var before: int = material_at(pixel.x, pixel.y)
	black_image.set_pixelv(pixel, color)
	_mark_dirty(pixel)
	if _is_nail(color):
		nail_layer.add(pixel)
	else:
		nail_layer.remove(pixel)
	_bump_ink(before, -1)
	_bump_ink(InkPalette.material_id_at_color(color), 1)


#写一个像素并记账，返回**墨水净变化**：+1 新画、-1 擦掉、0 没变或墨水不够。
#allowance 是本笔还剩多少 px 可画（擦除传大数）。
func _write_pixel(pixel: Vector2i, color: Color, allowance: int) -> int:
	if pixel.x < 0 or pixel.y < 0 or pixel.x >= canvas_size.x or pixel.y >= canvas_size.y:
		return 0
	var blue_here: bool = blue_layer.mask.has(pixel)
	if color.a > 0.5 and blue_here and color != InkPalette.BLACK.color:
		return 0
	var current := black_image.get_pixelv(pixel)
	#和现状逐位相同就什么都不做：不写、不记账、也不进撤销。
	#蓝线单独存储，因此擦除透明底上的蓝线仍必须继续。
	if current == color and not (color.a <= 0.5 and blue_here):
		return 0
	var had: bool = current.a > 0.5
	var want: bool = color.a > 0.5
	if want and not had and allowance <= 0:
		return 0
	_set_pixel_raw(pixel, color)
	if want and not had:
		return 1
	if had and not want:
		return -1
	return 0


## 在画布上放一枚钉子：写一个材质 4 的像素，外观由 NailLayer 画。
func _place_nail(point: Vector2) -> void:
	if not _inside(point):
		return
	#钉子不是墨水，不花瓶子里的墨。
	var delta := _write_pixel(Vector2i(point.floor()), nail_color(), 1 << 30)
	if delta == 0:
		return
	_flush_texture()
	_flush_ink()


#该像素是否为黑色墨水，供固化时采样
func is_solid(x: int, y: int) -> bool:
	return black_image.get_pixel(x, y).a > 0.5


## 透明=空；其余按色表认（认不出来返回 0）。
func material_at(x: int, y: int) -> int:
	return InkPalette.material_id_at_color(black_image.get_pixel(x, y))
#endregion


#region 矩形 / 圆形 / 直线
#拖拽预览：每动一次先把上一帧改过的像素还原，再按新位置重画一圈。
#松手才记账，所以拖拽过程不会反复扣墨水。
func _update_shape() -> void:
	_revert_shape()
	var to: Vector2 = _mouse_point().clamp(Vector2.ZERO, Vector2(canvas_size))
	var pixels := _shape_pixels(_shape_origin, to)
	var color := ink_color()
	var room := _ink_room(ink_material_id())
	var delta := 0
	for pixel: Vector2i in pixels:
		var prior := black_image.get_pixelv(pixel)
		if prior == color:
			continue                      # 已经是这个颜色：不用记也不用重画
		var had: bool = prior.a > 0.5
		if not had and delta >= room:
			continue                      # 墨水不够：剩下的格子不落笔
		_shape_saved[pixel] = prior
		_set_pixel_raw(pixel, color)
		if not had:
			delta += 1
	_shape_delta = delta
	_flush_texture()
	_flush_ink()


#把上一帧的预览还原成原样并清空记录。
func _revert_shape() -> void:
	if _shape_saved.is_empty():
		return
	for pixel: Vector2i in _shape_saved:
		var prior: Color = _shape_saved[pixel]
		_set_pixel_raw(pixel, prior)
	_shape_saved.clear()
	_shape_delta = 0
	_flush_texture()


#松手定型：像素已经落在画布上了，这里只把这一笔的账记到瓶子上。
func _end_shape() -> void:
	_shaping = false
	_update_shape()
	_shape_saved.clear()
	_flush_ink()
	_shape_delta = 0


#形状外框 = 拿笔刷沿边界扫一圈，所以线宽就是笔刷直径。
func _shape_pixels(from: Vector2, to: Vector2) -> Dictionary:
	var out := {}
	match tool:
		Tool.CIRCLE:
			#圆心 = 按下点，半径 = 拖出的距离；永远是正圆。
			_brush_circle(out, from, from.distance_to(to))
		Tool.LINE:
			#起点到终点的连续线段，粗细与当前笔刷一致。
			_brush_line(out, from, to)
		_:
			# 矩形不能复用圆形笔刷沿边盖章：圆盘相交后的最外层会周期性凹凸，
			# 粗边框固化后就会变成明显锯齿。这里直接生成整数像素包围盒和等宽方角边框。
			_brush_rect(out, from, to)
	return out


## 生成轴对齐、方角、外沿完全平整的矩形边框。
## 拖拽的两个点定义外包围盒；最大边按半开坐标换算，确保鼠标落在画布最右/下边时不越界。
func _brush_rect(out: Dictionary, from: Vector2, to: Vector2) -> void:
	var left := clampi(floori(minf(from.x, to.x)), 0, canvas_size.x - 1)
	var top := clampi(floori(minf(from.y, to.y)), 0, canvas_size.y - 1)
	var right := clampi(ceili(maxf(from.x, to.x)) - 1, 0, canvas_size.x - 1)
	var bottom := clampi(ceili(maxf(from.y, to.y)) - 1, 0, canvas_size.y - 1)
	# 单击或零宽/零高拖拽仍至少落一个像素。
	right = maxi(right, left)
	bottom = maxi(bottom, top)
	var thickness := maxi(1, brush_size)
	for y in range(top, bottom + 1):
		for x in range(left, right + 1):
			if x - left < thickness or right - x < thickness \
			or y - top < thickness or bottom - y < thickness:
				out[Vector2i(x, y)] = true


#沿线段撒笔刷脚印；步长 ≤ 笔刷半径，保证圈与圈之间不留缝。
func _brush_line(out: Dictionary, from: Vector2, to: Vector2) -> void:
	var steps := maxi(1, int(ceil(from.distance_to(to) / _brush_step())))
	for i in range(steps + 1):
		_collect_stamp(out, from.lerp(to, float(i) / float(steps)))


func _brush_circle(out: Dictionary, center: Vector2, radius: float) -> void:
	if radius < 0.5:
		_collect_stamp(out, center)
		return
	var steps := maxi(8, int(ceil(TAU * radius / _brush_step())))
	for i in steps:
		_collect_stamp(out, center + Vector2.from_angle(TAU * float(i) / float(steps)) * radius)


func _brush_step() -> float:
	return maxf(1.0, brush_size * 0.5)
#endregion


#region 墨水桶
#把点所在的**连通空区**一次灌满。
#
#⚠️ 用 4 邻接，不是 8 邻接：数字拓扑里"8 连通的边界"正好困住"4 连通的填充"。
#   圆形的 1px 外框是斜着走的（8 连通），4 邻接的填充才不会从斜缝里漏出去。
#
#⚠️ 整块区域要么全灌、要么不动：瓶里不够就什么都不画（半灌的封闭区看着像坏了）。
#   所以先数够不够，再落笔；数的时候一旦超就提前退出。
#
#⚠️ 必须**封口**：一旦漫到画布边缘就说明这片区域是敞开的（点在了开阔处），
#   直接放弃。否则创造模式免墨水、没有余额上限，一下就把整张图灌满 ——
#   2048x1024 = 200 万格，既没用又会卡死。
#   顺带这也是最快的退出路径：栈是后进先出，DFS 会顺着一个方向一路走到边，
#   几步就撞线，不用扫完整张图。
#
#⚠️ 入栈和标记必须**内联**：`PackedByteArray` / `PackedInt32Array` 在 GDScript 里是
#   **值拷贝**，塞进 helper 里改，改的是副本 —— 会变成永远推同一个像素的死循环。
func _bucket_fill(point: Vector2) -> bool:
	var w := canvas_size.x
	var h := canvas_size.y
	var start := Vector2i(point.floor())
	if not _inside(start):
		return false
	var data := black_image.get_data()
	var seen := PackedByteArray()
	seen.resize(w * h)
	var stack := PackedInt32Array()
	var targets := PackedInt32Array()
	var room := mini(_ink_room(ink_material_id()), MAX_BUCKET_PIXELS)

	var first := start.y * w + start.x
	if data[first * 4 + 3] > 127:
		return false                  # 点在实心像素上：什么都不做
	seen[first] = 1
	stack.append(first)
	while not stack.is_empty():
		var top := stack.size() - 1
		var idx := stack[top]
		stack.resize(top)
		targets.append(idx)
		var x := idx % w
		var y := idx / w
		if targets.size() > room:
			if room == MAX_BUCKET_PIXELS:
				print("墨水桶：区域过大（上限 %d px），请先用边框分隔" % MAX_BUCKET_PIXELS)
			else:
				print("墨水不足：这一片灌不下（瓶里 %d px）" % room)
			return false
		if x > 0 and seen[idx - 1] == 0 and data[(idx - 1) * 4 + 3] <= 127:
			seen[idx - 1] = 1
			stack.append(idx - 1)
		if x + 1 < w and seen[idx + 1] == 0 and data[(idx + 1) * 4 + 3] <= 127:
			seen[idx + 1] = 1
			stack.append(idx + 1)
		if y > 0 and seen[idx - w] == 0 and data[(idx - w) * 4 + 3] <= 127:
			seen[idx - w] = 1
			stack.append(idx - w)
		if y + 1 < h and seen[idx + w] == 0 and data[(idx + w) * 4 + 3] <= 127:
			seen[idx + w] = 1
			stack.append(idx + w)

	var pixel := PackedByteArray([
		int(ink_color().r * 255.0), int(ink_color().g * 255.0),
		int(ink_color().b * 255.0), 255])
	for idx: int in targets:
		var target := Vector2i(idx % w, idx / w)
		_track_undo_pixel(target)
		_mark_dirty(target)
		var at := idx * 4
		data[at] = pixel[0]
		data[at + 1] = pixel[1]
		data[at + 2] = pixel[2]
		data[at + 3] = pixel[3]
	black_image.set_data(canvas_size.x, canvas_size.y, false, Image.FORMAT_RGBA8, data)
	_flush_texture()
	_bump_ink(ink_material_id(), targets.size())
	_flush_ink()
	return true
#endregion


#region 撤销
## 删除框内当前画布像素。调用方可先把固化实体的框内像素采样回来，
## 两部分会作为同一个撤销步骤被 Ctrl+Z 恢复。
func erase_rect(rect: Rect2i) -> bool:
	var clipped := rect.intersection(Rect2i(Vector2i.ZERO, canvas_size))
	if not clipped.has_area():
		return false
	#分治：按瓦片走。整块空的直接跳过（一个字节都不扫），有内容的块也只扫自己的
	#内容框 —— 全选整张地图时，代价只和"真有墨的地方"成正比，跟画布多大无关。
	_flush_texture()                  # 先落地未上传的写入，瓦片集合才是完整的
	var changed := false
	for key in _tile_keys(clipped):
		var box := _tile_content(key).intersection(clipped)
		if box.has_area():
			changed = _erase_box(box) or changed
	# 蓝线不在 black_image 的瓦片内容框里；单独处理剩余的纯蓝像素。
	for pixel: Vector2i in blue_layer.mask.keys():
		if clipped.has_point(pixel):
			_set_pixel_raw(pixel, Color.TRANSPARENT)
			changed = true
	if changed:
		_flush_texture()
		blue_layer.refresh()
		_flush_ink()
	return changed


## 把一个矩形里的有墨格子擦成透明。先按原始字节挑出有墨的格子再擦：
## 框里绝大多数格子是空的，逐格 get_pixelv 白付一次引擎调用（600x400 实测 18.9 ms）。
func _erase_box(box: Rect2i) -> bool:
	var width := canvas_size.x
	var data := black_image.get_data()
	var targets := PackedInt32Array()
	for y in range(box.position.y, box.end.y):
		var row := y * width
		for x in range(box.position.x, box.end.x):
			if data[(row + x) * 4 + 3] > 127:
				targets.append(row + x)
	if targets.is_empty():
		return false
	data = PackedByteArray()          # 放开引用，下面的写入才不触发整图写时复制
	for index in targets:
		_set_pixel_raw(Vector2i(index % width, index / width), Color.TRANSPARENT)
	return true


func _begin_undo_step() -> void:
	if not _undo_capturing and blue_layer != null:
		_blue_undo = {"cells": blue_layer.cells.duplicate(), "motors": blue_rule().capture(self) if blue_rule() != null else [], "ledger": ink_px_of(InkPalette.BLUE.id)}
	_undo_capture = {}
	_undo_capturing = true


func _track_undo_pixel(pixel: Vector2i) -> void:
	if not _undo_capturing or _undo_capture.has(pixel):
		return
	_undo_capture[pixel] = black_image.get_pixelv(pixel)


func _commit_undo_step() -> void:
	if not _undo_capturing:
		return
	_undo_capturing = false
	if not _blue_undo.is_empty() and (blue_layer.cells != _blue_undo.cells or ink_px_of(InkPalette.BLUE.id) != _blue_undo.ledger or (blue_rule() != null and blue_rule().draft_data(self).size() != _blue_undo.motors.size())):
		_undo_capture["blue"] = _blue_undo
	_blue_undo = {}
	if _undo_capture.is_empty():
		_undo_capture = {}
		return
	push_undo_step(_undo_capture)
	_undo_capture = {}


func push_undo_step(step: Dictionary) -> void:
	_undo_steps.append(step)
	if _undo_steps.size() > MAX_UNDO_STEPS:
		_undo_steps.pop_front()
	edit_committed.emit()


func _cancel_undo_step() -> void:
	_undo_capture = {}
	_undo_capturing = false


## 撤销最近一次完整的画笔、橡皮、形状、墨水桶或钉子操作。
func undo_last_edit() -> bool:
	if _undo_steps.is_empty():
		return false
	if _shaping:
		_revert_shape()
	_shaping = false
	_painting = false
	_cancel_undo_step()
	var step: Dictionary = _undo_steps.pop_back()
	if step.has("rod_pixels"):
		rod_layer.undo(step)
		return true
	if step.has("transaction"):
		get_parent().History.restore(get_parent(), step.transaction)
		return true
	if step.has("yellow"):
		var yellow = yellow_rule()
		if yellow != null:
			var stroke = step.yellow
			if (not is_instance_valid(stroke) or not yellow.strokes.has(stroke)) and step.has("yellow_id"):
				for candidate in yellow.strokes:
					if candidate.get_meta(&"canvas_undo_identity", -1) == step.yellow_id:
						stroke = candidate
						break
			yellow.undo(stroke, self)
		return true
	var blue_saved: Dictionary = step.get("blue", {})
	step.erase("blue")
	for pixel: Vector2i in step:
		_set_pixel_raw(pixel, step[pixel])
	if not blue_saved.is_empty():
		blue_layer.cells = blue_saved.cells
		blue_layer.rebuild()
		if blue_rule() != null:
			blue_rule().restore(self, blue_saved.motors)
		_bump_ink(InkPalette.BLUE.id, int(blue_saved.ledger) - ink_px_of(InkPalette.BLUE.id))
	_flush_texture()
	_flush_ink()
	return true
#endregion


#region 墨水账
## 瓶中墨水的真源（玩家身上的 InkHealth）；接不到就当成无限墨水。
@export var health_path := NodePath("../../Player/InkHealth")

var _health = null
## 画布上各墨水的实心像素数：材质 id -> 数量。**这是画布自己的账**，和瓶子无关：
## 画布上写着多少墨，"重绘"就还多少。钉子不算墨水，不进这本账。
var ink_px_by_material := {}
## 本笔还没记到瓶子上的净变化：材质 id -> ±像素数。一笔只和瓶子对一次账。
var _pending_ink := {}
## 免墨水模式（创造模式）：整张画布不和瓶子对账 —— 画、擦、重绘都不动墨水。
## ⚠️ 关掉时画布上的墨算"免费"，所以进入时要把已经欠的账先结清（见 setter）。
@export var ink_free := false:
	set(value):
		if value == ink_free:
			return
		if value:
			_refund_all_ink()           # 先把画布上的墨还给瓶子，之后画布上的墨算免费
		ink_free = value


## 某墨水在画布上有多少像素。
func ink_px_of(material_id: int) -> int:
	return ink_px_by_material.get(material_id, 0)


#本笔还能新增多少像素（按当前墨水的余量）。
func _ink_room(material_id: int) -> int:
	var health = _health_node()
	if health == null:
		return 1 << 30
	return (1 << 30) if ink_free else maxi(0, int(health.ink_of(material_id)))


#惰性解析墨水源：Player 可能比画布晚就绪。
func _health_node():
	if _health == null:
		_health = get_node_or_null(health_path)
	return _health


#画布自己的账：某墨水的像素数变化。钉子不是墨水，不进账。
#charge = false 只改画布自己的账、不记到瓶子上（"重新回到画布"那条路）。
func _bump_ink(material_id: int, delta: int, charge := true) -> void:
	if delta == 0 or ink_free:
		return
	if not InkPalette.is_ink(material_id):
		return
	ink_px_by_material[material_id] = ink_px_of(material_id) + delta
	if not charge:
		return
	_pending_ink[material_id] = _pending_ink.get(material_id, 0) + delta


#把本笔的净变化记到瓶子上；一次笔画只发一次信号。
func _flush_ink() -> void:
	var pending := _pending_ink
	_pending_ink = {}
	if ink_free or pending.is_empty():
		return
	var health = _health_node()
	if health == null:
		return
	for material_id in pending:
		var delta: int = pending[material_id]
		if delta > 0:
			health.reduce(material_id, float(delta))
		elif delta < 0:
			health.add(material_id, float(-delta))


#把画布上现有各墨水的库存全部还给瓶子（重建画布 / 重绘 / 进创造模式前）。
func _refund_all_ink() -> void:
	_flush_ink()
	var book := ink_px_by_material
	ink_px_by_material = {}
	if ink_free:
		return
	var health = _health_node()
	if health == null:
		return
	for material_id in book:
		var count: int = book[material_id]
		if count > 0:
			health.add(material_id, float(count))
#endregion


#region 画布复现文件
## 自动保存的 .edit.snapshot 是整张画布的 PNG（PNG 没有增量接口，只能整图编码）。
## 4352x1328 实测编码 120~160 ms —— 放主线程就是每笔卡十帧，所以拷一份整图
## 交给 WorkerThreadPool，主线程只付一次内存拷贝（约 3 ms）。
var _snapshot_task := -1
var _snapshot_path := ""
var _snapshot_again := false


## 请后台把当前画布写进快照；上一个任务没写完时，新请求合并成一次补写。
func request_snapshot(path: String) -> void:
	if black_image == null:
		return
	_snapshot_path = path
	_snapshot_again = true
	_start_snapshot()


func _start_snapshot() -> void:
	if _snapshot_task != -1 or not _snapshot_again:
		return
	_snapshot_again = false
	var copy := Image.new()
	copy.copy_from(black_image)
	_snapshot_task = WorkerThreadPool.add_task(
		_write_snapshot.bind(copy, _snapshot_path), false, "canvas snapshot")


func _poll_snapshot() -> void:
	if _snapshot_task == -1 or not WorkerThreadPool.is_task_completed(_snapshot_task):
		return
	WorkerThreadPool.wait_for_task_completion(_snapshot_task)
	_snapshot_task = -1
	_start_snapshot()


## 线程里跑的写盘：只碰自己那份 Image 和字符串，所以可以是 static。
static func _write_snapshot(image: Image, path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	var temporary := absolute + ".tmp"
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		push_error("Canvas snapshot open failed: %s (%d)" % [path, FileAccess.get_open_error()])
		return
	file.store_buffer(image.save_png_to_buffer())
	file.flush()
	file.close()
	if FileAccess.file_exists(path) and DirAccess.remove_absolute(absolute) != OK:
		DirAccess.remove_absolute(temporary)
		return
	DirAccess.rename_absolute(temporary, absolute)


## 保存 CPU 像素缓冲，包含颜色、透明度和尺寸；不读取 GPU，不触发固化。
func save_ink(path: String) -> Error:
	var error: Error
	if path.get_extension().to_lower() == "snapshot":
		error = _save_snapshot(path)
	elif path.get_extension().to_lower() == "png":
		error = black_image.save_png(ProjectSettings.globalize_path(path))
	else:
		error = ResourceSaver.save(black_image, path)
	if error == OK:
		print("CANVAS saved: ", ProjectSettings.globalize_path(path))
	else:
		push_error("Canvas save failed: %s (%d)" % [path, error])
	return error


## 编辑快照使用 PNG 压缩数据，但故意不用 .png 扩展名。Godot 编辑器会持续监视并
## 导入 res:// 下的 PNG，自动保存恰好撞上导入线程时 Windows 会返回 ERR_FILE_CANT_WRITE。
## 未注册的 .snapshot 不进入导入流水线，并通过同目录临时文件避免中途写坏快照。
func _save_snapshot(path: String) -> Error:
	var absolute := ProjectSettings.globalize_path(path)
	var temporary := absolute + ".tmp"
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer("INK2".to_ascii_buffer())
	var rule = yellow_rule()
	file.store_var({"black": black_image.save_png_to_buffer(), "rod": rod_layer.pixels.save_png_to_buffer(), "anchors": rod_layer.anchor_points,
		"springs": rule.draft_data(self) if rule != null else [], "blue": blue_layer.cells,
		"motors": blue_rule().draft_data(self) if blue_rule() != null else []})
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
func save_png(path: String) -> Error:
	var error: Error = black_image.save_png(ProjectSettings.globalize_path(path))
	if error == OK:
		print("MAP saved: ", ProjectSettings.globalize_path(path))
	else:
		push_error("Map save failed: %s (%d)" % [path, error])
	return error


func load_ink(path: String) -> Error:
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
	_painting = false
	get_parent().canvas_size = image.get_size()
	black_image = image
	black_image.convert(Image.FORMAT_RGBA8)
	rebuild_ink_tiles()
	_rebuild_loaded_metadata()
	if not rod_data.is_empty():
		var rods := Image.new()
		rods.load_png_from_buffer(rod_data.rod)
		rod_layer.pixels = rods
		rod_layer.anchor_points = rod_data.anchors
		rod_layer.refresh()
		var health = _health_node()
		if not ink_free and health != null:
			health.reduce(InkPalette.YELLOW.id, rod_layer.make_shape().pixel_count())
		var rule = yellow_rule()
		if rule != null:
			rule.restore_drafts(self, rod_data.get("springs", []), not ink_free)
		blue_layer.cells = rod_data.get("blue", PackedVector2Array())
		blue_layer.rebuild()
		_bump_ink(InkPalette.BLUE.id, blue_layer.cells.size())
		if blue_rule() != null:
			blue_rule().restore_draft_data(self, rod_data.get("motors", []))
		_flush_ink()
	print("CANVAS loaded: ", ProjectSettings.globalize_path(path))
	return OK


## 读盘后重建钉子和墨水账：按块分治，只扫各块的内容框（空块一个字节都不扫）。
func _rebuild_loaded_metadata() -> void:
	nail_layer.clear()
	ink_px_by_material = {}
	_pending_ink = {}
	var nail_id := InkPalette.nail_material_id()
	var width := canvas_size.x
	var data := black_image.get_data()
	for box in _content_boxes():
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
					nail_layer.add(Vector2i(x, y))
				elif InkPalette.is_ink(material_id):
					ink_px_by_material[material_id] = ink_px_of(material_id) + 1


#按像素重新数一遍画布自己的账 —— 读盘、以及怀疑账本漂了的时候用。
#⚠️ 只走一次性路径。按块分治：代价 = 各块内容框之和，不是整张画布。
func recount_ink_px() -> void:
	ink_px_by_material = {}
	_pending_ink = {}
	_flush_texture()                  # 先落地未上传的写入，块集合才是完整的
	var width := canvas_size.x
	var data := black_image.get_data()
	for box in _content_boxes():
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
					ink_px_by_material[material_id] = ink_px_of(material_id) + 1


#按像素颜色重建钉子外观层；只在读盘时走一次。同样只扫各块的内容框。
func _rebuild_nails() -> void:
	nail_layer.clear()
	var nail_id := InkPalette.nail_material_id()
	var width := canvas_size.x
	var data := black_image.get_data()
	for box in _content_boxes():
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
					nail_layer.add(Vector2i(x, y))
#endregion
