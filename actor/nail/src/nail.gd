#钉子外观（固化后）：贴在某个刚体的某个像素上，每帧跟着它走；那个像素没了就自毁。
#只负责画，不参与物理；固化时由 CanvasSolid 为每个钉子像素生成一枚。

#region 依赖
@tool
extends Sprite2D

const NAIL_TEXTURE := preload("res://actor/nail/asset/nail.png")
## 新钉子贴图为 32x32，固定点对齐图片中心。
const ANCHOR_CENTER := Vector2(16.0, 16.0)
## 所有运行时钉子外观都进入这个组，地图编辑器只切显示，不改物理锚点。
const VISUAL_GROUP := &"nail_visual"
## 地图编辑器可单独预览预置钉子；切回游玩后只隐藏这类钉子的外观。
static var visuals_visible := true
static var map_editor_active := false
## 钉子对应的材料 id；真源在 Ink/src/ink_palette.gd。
const InkPalette := preload("res://Ink/src/ink_palette.gd")
#endregion


#region 状态
var body = null
var pixel := Vector2i.ZERO
var hide_outside_map_editor := false
#endregion


#region 挂载
func _enter_tree() -> void:
	add_to_group(VISUAL_GROUP)
	refresh_visibility()


## 绑定到一个刚体上的某个钉子像素；调用前先 add_child。
func setup(target_body, target_pixel: Vector2i, editor_placed := false) -> void:
	body = target_body
	pixel = target_pixel
	hide_outside_map_editor = editor_placed
	texture = NAIL_TEXTURE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	centered = false
	offset = -ANCHOR_CENTER        # 固定点落在节点原点
	process_physics_priority = 20  # 和 pbody_visual 一样，等世界走完再读位置
	refresh_visibility()
	_follow()


## 预置钉子只在地图编辑模式显示；普通游玩钉子始终保留外观。
func refresh_visibility() -> void:
	visible = not hide_outside_map_editor or (map_editor_active and visuals_visible)
#endregion


#region 跟踪
func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not _anchor_alive():
		queue_free()               # 钉子像素被破坏/移走：外观跟着消失
		return
	_follow()


#把节点挪到钉子像素的世界位置，并跟着刚体转。
func _follow() -> void:
	if not is_inside_tree() or body == null:
		return
	global_position = body.to_world(Vector2(pixel) + Vector2(0.5, 0.5))
	global_rotation = body.rotation


#钉子像素还在这个刚体上吗。
func _anchor_alive() -> bool:
	if body == null:
		return false
	for shape in body.shapes:
		if shape.get_pixel(pixel.x, pixel.y) == InkPalette.nail_material_id():
			return true
	return false
#endregion
