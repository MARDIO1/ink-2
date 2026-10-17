#钉子外观（固化后）：贴在某个刚体的某个像素上，每帧跟着它走；那个像素没了就自毁。
#只负责画，不参与物理；固化时由 CanvasSolid 为每个钉子像素生成一枚。

#region 依赖
@tool
extends Sprite2D

const BACKGROUND_TEXTURE := preload("res://actor/nail/asset/nail.png")
const FIXED_TEXTURE := preload("res://actor/nail/asset/fixed_nail.png")
const INFINITE_TEXTURE := preload("res://actor/nail/asset/infinite_nail.png")
const NAIL_TEXTURE := FIXED_TEXTURE
## 固定/背景钉子为 11×11，无限钉子为 16×16；固定点都位于纹理中心。
const ANCHOR_CENTER := Vector2(5.5, 5.5)
const VISUAL_SCALE := 1.0
enum Kind { FIXED, BACKGROUND, INFINITE }
const FIXED_TAG := "static_anchor_points"
const BACKGROUND_TAG := "background_anchor_points"
## 无限钉子也保存实际锚点坐标；body 级不可破坏/无限燃料标记在 ink_traits.gd。
const INFINITE_TAG := "infinite_nail_points"

## 所有运行时钉子外观都进入这个组，地图编辑器只切显示，不改物理锚点。
const VISUAL_GROUP := &"nail_visual"
## 地图编辑器可单独切换钉子预览；正常游玩中所有钉子都可见。
static var visuals_visible := true
static var map_editor_active := false
## 钉子对应的材料 id；真源在 ink/general/src/ink_palette.gd。
#endregion


#region 状态
var body = null
var pixel := Vector2i.ZERO
var kind: Kind = Kind.FIXED
var hide_outside_map_editor := false
#endregion


#region 挂载
static func texture_for(target_kind: Kind) -> Texture2D:
	if target_kind == Kind.BACKGROUND:
		return BACKGROUND_TEXTURE
	if target_kind == Kind.INFINITE:
		return INFINITE_TEXTURE
	return FIXED_TEXTURE


static func anchor_center_for(target_kind: Kind) -> Vector2:
	return Vector2(texture_for(target_kind).get_size()) * 0.5


static func tag_for(target_kind: Kind) -> String:
	if target_kind == Kind.BACKGROUND:
		return BACKGROUND_TAG
	if target_kind == Kind.INFINITE:
		return INFINITE_TAG
	return FIXED_TAG


static func visual_rect(pixel: Vector2i, target_kind: Kind = Kind.FIXED) -> Rect2:
	return Rect2(Vector2(pixel) + Vector2(0.5, 0.5) - anchor_center_for(target_kind) * VISUAL_SCALE,
		Vector2(texture_for(target_kind).get_size()) * VISUAL_SCALE)


func _enter_tree() -> void:
	add_to_group(VISUAL_GROUP)
	refresh_visibility()


## 绑定到一个刚体上的某个钉子像素；调用前先 add_child。
func setup(target_body, target_pixel: Vector2i, editor_placed := false,
		target_kind: Kind = Kind.FIXED) -> void:
	body = target_body
	pixel = target_pixel
	kind = target_kind
	hide_outside_map_editor = editor_placed
	texture = texture_for(kind)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	centered = false
	offset = -anchor_center_for(kind)        # 固定点落在节点原点
	scale = Vector2.ONE * VISUAL_SCALE
	process_physics_priority = 20  # 和 pbody_visual 一样，等世界走完再读位置
	refresh_visibility()
	_follow()


## 游戏中始终显示钉子（包括地图编辑器放置的钉子）；
## 只有处于地图编辑模式时，才服从“显示钉子”开关。
func refresh_visibility() -> void:
	visible = visuals_visible if map_editor_active else true
#endregion


#region 跟踪
func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not _anchor_alive():
		if not _try_rebind():
			queue_free()
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
	return body.tags.get(tag_for(kind), {}).has(pixel)


func _try_rebind() -> bool:
	var host = get_parent()
	var physics = host.get("world") if host != null else null
	if physics == null:
		return false
	var tag := tag_for(kind)
	var best = null
	var best_distance := INF
	for candidate in physics.bodies:
		if candidate == null or not candidate.tags.get(tag, {}).has(pixel):
			continue
		var distance: float = candidate.to_world(Vector2(pixel) + Vector2.ONE * 0.5).distance_squared_to(global_position)
		if distance < best_distance:
			best = candidate
			best_distance = distance
	if best == null or best_distance > 4.0:
		return false
	body = best
	return true
#endregion
