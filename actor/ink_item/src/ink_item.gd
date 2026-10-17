#地图里的墨水物品：就是引擎的 PixelBody2D，从 .tscn 加载出来就是一个静态/动态刚体。
#唯一的额外工作——像素里已经有钉子，但锚点标签和可见外观看不出来，烘焙时按自己的像素补一遍。

#region 依赖
@tool
extends "res://addons/pixel_destruction/nodes/pixel_body_2d.gd"

const InkPalette := preload("res://ink/general/src/ink_palette.gd")
const ANCHOR_TAG := "static_anchor_points"
const BACKGROUND_TAG := "background_anchor_points"
const BACKGROUND_LAYER_TAG := "background_original_layer"
const BACKGROUND_MASK_TAG := "background_original_mask"
const BACKGROUND_IMMUNE_TAG := "background_original_no_impact_damage"
const BACKGROUND_WHITE_TAG := "background_original_white_ink"
const BACKGROUND_SWEEP_TAG := "background_original_white_sweep"
const Nail := preload("res://actor/nail/src/nail.gd")
#endregion

## 关卡文件里的墨水实体默认属于地图编辑器预置内容，其钉子仅供编辑时查看。
## 游玩过程中由 CanvasSolid 新建的实体会显式将此值设为 false。
@export var hide_nails_in_play := true
@export var fixed_nails := PackedVector2Array()
@export var background_nails := PackedVector2Array()
@export_flags_2d_physics var background_collision_layer := 1
@export_flags_2d_physics var background_collision_mask := 0xFFFFFFFF
## 强制白墨使用高速扫掠；关闭时仍会自动识别画布生成的圆环。
@export var violent_white := false


#region 装载
## 白墨沿用刚体运动和渲染；普通白墨接触后关闭碰撞，圆形扫掠从生成起无碰撞。
func bake():
	_migrate_legacy_nails()
	if not fixed_nails.is_empty():
		is_static = true
	var result = super.bake()
	var white := false
	var other := false
	var shapes: Array = collect_shapes()
	for shape in shapes:
		for chunk in shape.chunks.values():
			for material in chunk.mat:
				white = white or material == InkPalette.WHITE.id
				other = other or (material != 0 and material != InkPalette.WHITE.id)
	if white and not other:
		result.tags["keep_disconnected"] = true
		result.tags["linear_damping"] = 0.0
		result.tags["angular_damping"] = 0.0
		# 白墨先以真实刚体落地；首次接触后由 WhiteInk 关闭碰撞并附着。
		result.collision_layer = 1
		result.collision_mask = 0xFFFFFFFF
		result.angular_velocity = 0.0
		# 固定白墨只是地图画面，不应变成会扫掠擦除整张地图的幽灵刚体。
		# 只有可运动白墨才参与白墨消除规则。
		if not is_static:
			result.tags["white_ink"] = true
			result.tags["no_impact_damage"] = true
			result.is_static = false
			if violent_white or _looks_like_white_circle(shapes):
				result.tags["white_sweep"] = true
				result.collision_layer = 0
				result.collision_mask = 0
	apply_nails(result, false)
	return result


func _migrate_legacy_nails() -> void:
	for shape in collect_shapes():
		var rect: Rect2i = shape.local_aabb()
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				if shape.get_pixel(x, y) != InkPalette.nail_material_id():
					continue
				var point := Vector2i(x, y)
				shape.set_pixel(x, y, InkPalette.GREY.id)
				if not fixed_nails.has(point):
					fixed_nails.append(point)


func apply_nails(target_body, spawn_visuals := true) -> void:
	if target_body == null:
		return
	var fixed := {}
	for point in fixed_nails:
		fixed[Vector2i(point)] = true
	var background := {}
	for point in background_nails:
		background[Vector2i(point)] = true
	if fixed.is_empty():
		target_body.tags.erase(ANCHOR_TAG)
	else:
		target_body.tags[ANCHOR_TAG] = fixed
		target_body.is_static = true
	if background.is_empty():
		target_body.tags.erase(BACKGROUND_TAG)
	else:
		if not target_body.tags.has(BACKGROUND_IMMUNE_TAG):
			target_body.tags[BACKGROUND_IMMUNE_TAG] = target_body.tags.has("no_impact_damage")
			target_body.tags[BACKGROUND_WHITE_TAG] = target_body.tags.has("white_ink")
			target_body.tags[BACKGROUND_SWEEP_TAG] = target_body.tags.has("white_sweep")
		target_body.tags[BACKGROUND_TAG] = background
		target_body.tags[BACKGROUND_LAYER_TAG] = background_collision_layer
		target_body.tags[BACKGROUND_MASK_TAG] = background_collision_mask
		target_body.tags["no_impact_damage"] = true
		target_body.tags.erase("white_ink")
		target_body.tags.erase("white_sweep")
		target_body.collision_layer = 0
		target_body.collision_mask = 0
	if not spawn_visuals or Engine.is_editor_hint() or not is_inside_tree():
		return
	var host := get_parent()
	if host == null:
		return
	_spawn_visuals(host, target_body, fixed, Nail.Kind.FIXED)
	_spawn_visuals(host, target_body, background, Nail.Kind.BACKGROUND)


func _spawn_visuals(host: Node, target_body, points: Dictionary, kind: Nail.Kind) -> void:
	for point: Vector2i in points:
		var exists := false
		for child in host.get_children():
			if child is Nail and child.body == target_body and child.pixel == point and child.kind == kind:
				exists = true
				break
		if exists:
			continue
		var nail := Nail.new()
		host.add_child(nail)
		nail.setup(target_body, point, hide_nails_in_play, kind)


## 圆形工具生成的是空心圆环：近似等宽高、中心和四角为空、四个轴端都有墨水。
static func _looks_like_white_circle(shapes: Array) -> bool:
	if shapes.size() != 1:
		return false
	var shape = shapes[0]
	var rect: Rect2i = shape.local_aabb()
	if mini(rect.size.x, rect.size.y) < 8:
		return false
	var ratio := float(rect.size.x) / float(rect.size.y)
	if ratio < 0.75 or ratio > 1.25:
		return false
	var center := rect.position + rect.size / 2
	if shape.get_pixel(center.x, center.y) != 0:
		return false
	for corner in [rect.position, Vector2i(rect.end.x - 1, rect.position.y),
		Vector2i(rect.position.x, rect.end.y - 1), rect.end - Vector2i.ONE]:
		if shape.get_pixel(corner.x, corner.y) != 0:
			return false
	for point in [Vector2i(center.x, rect.position.y), Vector2i(center.x, rect.end.y - 1),
		Vector2i(rect.position.x, center.y), Vector2i(rect.end.x - 1, center.y)]:
		if not _has_pixel_near(shape, point):
			return false
	return true


static func _has_pixel_near(shape, point: Vector2i) -> bool:
	for y in range(point.y - 2, point.y + 3):
		for x in range(point.x - 2, point.x + 3):
			if shape.get_pixel(x, y) != 0:
				return true
	return false

#⚠️ 不能挂在 _bake_lazily 上：PixelWorld.rebuild() 走的是 bake_node() → bake()，
#   不经过"按需烘焙"那个钩子。所以延迟一帧，等世界把刚体和形状都装好再补锚点。
func _ready() -> void:
	_restore_nails.call_deferred()


#把材质 4 的像素认成锚点：打标签给破坏管线，并补上可见的钉子外观。
func _restore_nails() -> void:
	if not is_inside_tree():
		return
	var body = self.body          # 读 body 会幂等触发烘焙
	if body == null:
		return
	apply_nails(body, true)
#endregion
