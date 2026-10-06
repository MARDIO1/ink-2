@tool
extends Node2D
# 钉子：大贴图，只有中心点（根节点原点）对应的那一个像素起固定作用。
# 编辑器里直接拖入场景摆放（@tool 让贴图可见）。
# 运行时：把中心点所在的已有动态刚体钉成静态；中心像素一旦被破坏/移走，
# 整钉消失并解除固定。完全自包含，不改动画布与固化流程。
# 贴图由代码生成（金属头+尖针），不依赖外部图片导入。

const TAG := "nailed_by"  # 在被钉刚体 tags 里记录钉它的钉子数组，供解除时辨认。

var _nailed = null  # 当前被本钉子钉成静态的刚体（PBody）；原本静态的刚体不在此列。


func _ready() -> void:
	_build_sprite()
	if Engine.is_editor_hint():
		return
	# 首帧等世界就绪后再判定，避免开场时刚体尚未烘焙。
	call_deferred("_settle")


func _settle() -> void:
	# 中心没有实体：钉子不生效（编辑器里仍保留贴图方便摆放，运行时删除）。
	if _body_at_center() == null:
		queue_free()
		return
	_update_nail()


# 每帧跟踪中心点：中心像素转移到碎片上时改钉碎片；消失时解除并自毁。
func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_update_nail()


func _update_nail() -> void:
	var body = _body_at_center()
	# 目标是动态刚体才需要钉；静态刚体（地形）本来就固定，无需操作。
	var dynamic = body if body != null and not body.is_static else null
	if dynamic == _nailed:
		if body == null:
			queue_free()  # 中心像素被破坏/移走：整钉消失。
		return
	_release()
	_nailed = dynamic
	if _nailed != null:
		_nailed.make_static()
		var nails: Array = _nailed.tags.get(TAG, [])
		if not nails.has(self):
			nails.append(self)
		_nailed.tags[TAG] = nails


# 解除本钉子造成的固定；同一刚体被多枚钉子钉住时，全部解除后才恢复动态。
func _release() -> void:
	if _nailed == null or not is_instance_valid(_nailed):
		_nailed = null
		return
	var nails: Array = _nailed.tags.get(TAG, [])
	nails.erase(self)
	if nails.is_empty():
		_nailed.tags.erase(TAG)
		_nailed.make_dynamic()
	else:
		_nailed.tags[TAG] = nails
	_nailed = null


func _exit_tree() -> void:
	_release()


func _body_at_center():
	var world = _world()
	if world == null:
		return null
	for body in world.bodies:
		var local: Vector2 = body.to_local(global_position)
		var cell := Vector2i(local.floor())
		for shape in body.shapes:
			if shape.get_pixel(cell.x, cell.y) != 0:
				return body
	return null


func _world():
	var node := get_parent()
	while node != null:
		if node.get("bodies") != null and node.has_method("add_body_node"):
			return node
		node = node.get_parent()
	return null


# 生成钉子贴图：圆头在上、尖针朝下，图像中心（SIZE/2 取整处）即固定点，
# Sprite2D.offset 把它对齐到根节点原点。
const SIZE := Vector2i(7, 13)

func _build_sprite() -> void:
	var image := Image.create_empty(SIZE.x, SIZE.y, false, Image.FORMAT_RGBA8)
	for y in range(SIZE.y):
		for x in range(SIZE.x):
			image.set_pixel(x, y, _pixel_at(Vector2(x, y)))
	var sprite := Sprite2D.new()
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.texture = ImageTexture.create_from_image(image)
	# 固定点取图像中心像素 (SIZE/2 向下取整) = (3, 6)，让针尖落在根原点。
	sprite.offset = -Vector2(SIZE / 2)
	sprite.name = "Sprite2D"
	add_child(sprite)


const _HEAD := Vector2(3.0, 3.0)
const _HEAD_R := 3.0
const _DARK := Color(0.18, 0.18, 0.20)
const _METAL := Color(0.45, 0.47, 0.52)
const _LIGHT := Color(0.75, 0.78, 0.82)
const _TIP := Color(0.10, 0.10, 0.12)

func _pixel_at(p: Vector2) -> Color:
	var to_head: Vector2 = p - _HEAD
	if to_head.length() <= _HEAD_R:
		var light: float = clampf((-to_head.x - to_head.y) / (_HEAD_R * 2.0) + 0.5, 0.0, 1.0)
		return _DARK.lerp(_LIGHT, light)
	var tip_y := float(SIZE.y - 1) / 2.0
	if p.y > _HEAD.y:
		var t: float = (p.y - _HEAD.y) / (tip_y - _HEAD.y)
		var half_width: float = maxf(0.45, lerpf(1.6, 0.4, t))
		var d: float = absf(p.x - _HEAD.x)
		if d <= half_width:
			var light: float = clampf(0.55 - d / (half_width * 2.0), 0.0, 1.0)
			return _DARK.lerp(_METAL, light).lerp(_TIP, t * t)
	return Color.TRANSPARENT
