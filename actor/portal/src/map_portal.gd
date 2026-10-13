@tool
extends Node2D
## 仅观察自定义 PixelWorld 玩家碰撞壳，不使用 Godot Area2D 的另一套物理世界。

const GROUP := &"map_portal"
const LevelList := preload("res://ui/level_select/src/level_select.gd")
const TEXTURE_PATH := "res://actor/portal/asset/torn_paper_portal.png"
const OVERLAP_SECONDS := 2.0
const SPIRAL_SHADER := preload("res://actor/portal/asset/portal_spiral.gdshader")
static var _center_mask: Texture2D

@export_file("*.tscn") var target_map := ""
@export var portal_size := Vector2(150.0, 150.0)
## 每秒旋转弧度；暂停菜单打开时动画也暂停。
@export var spiral_rotation_speed := 0.7
var _spiral: Sprite2D
var _spiral_material: ShaderMaterial
var _spiral_phase := 0.0
var overlap_time := 0.0
var _fired := false
var _pending := false
var _status := ""
var _texture: Texture2D
var _editor_label := ""
var _label_refresh_elapsed := 0.5


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	# 世界显示层最上方：瓶身 > 瓶内墨水 > 手掌 > 虚线手臂 > 传送门。
	# 仅调整 CanvasItem 排序，保持 PixelWorld 的碰撞与触发逻辑。
	z_index = 4092
	z_as_relative = false
	process_physics_priority = 100
	_texture = load(TEXTURE_PATH) as Texture2D
	if _center_mask == null and _texture != null:
		_center_mask = _make_center_mask(_texture.get_image())
	_setup_spiral()
	queue_redraw()
	set_physics_process(not Engine.is_editor_hint())


func _setup_spiral() -> void:
	if _center_mask == null:
		return
	_spiral = Sprite2D.new()
	_spiral.name = "SpiralCenter"
	_spiral.texture = _center_mask
	_spiral.show_behind_parent = true
	_spiral_material = ShaderMaterial.new()
	_spiral_material.shader = SPIRAL_SHADER
	_spiral.material = _spiral_material
	add_child(_spiral)
	_spiral.scale = portal_size / Vector2(_center_mask.get_size())


## 从透明中心四向扩散，只覆盖被裂纹围住的洞口，不覆盖外围背景。
static func _make_center_mask(source: Image) -> Texture2D:
	var size := source.get_size()
	var mask := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	mask.fill(Color.TRANSPARENT)
	var visited := PackedByteArray()
	visited.resize(size.x * size.y)
	var pending: Array[Vector2i] = [size / 2]
	var index := 0
	while index < pending.size():
		var point := pending[index]
		index += 1
		if point.x < 0 or point.y < 0 or point.x >= size.x or point.y >= size.y:
			continue
		var offset := point.y * size.x + point.x
		if visited[offset] != 0:
			continue
		visited[offset] = 1
		if source.get_pixelv(point).a > 0.1:
			continue
		mask.set_pixelv(point, Color.WHITE)
		for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			pending.append(point + direction)
	return ImageTexture.create_from_image(mask)


func _level() -> Node:
	return get_parent()


func editor_destination_text() -> String:
	var destination := resolve_destination()
	if destination.is_empty():
		return "通往：未设置或目标不可用"
	return "通往：" + destination.get_file().get_basename()


func _process(delta: float) -> void:
	if is_instance_valid(_spiral):
		_spiral_phase = fposmod(_spiral_phase + delta * spiral_rotation_speed, TAU)
		_spiral_material.set_shader_parameter("phase", _spiral_phase)
		_spiral.scale = portal_size / Vector2(_center_mask.get_size())
	var editing := Engine.is_editor_hint() or _editor_active()
	if not editing:
		if not _editor_label.is_empty():
			_editor_label = ""
			queue_redraw()
		return
	_label_refresh_elapsed += delta
	if _label_refresh_elapsed < 0.5:
		return
	_label_refresh_elapsed = 0.0
	var next_label := editor_destination_text()
	if next_label != _editor_label:
		_editor_label = next_label
		queue_redraw()


func _editor_active() -> bool:
	var creative := _level().get_node_or_null("Creative") if _level() != null else null
	return creative != null and bool(creative.get("active"))


func contains_world_point(point: Vector2) -> bool:
	var radius := portal_size * 0.29
	return (to_local(point) / radius).length_squared() <= 1.0


func overlaps_player(player: Node) -> bool:
	var body = player.get("body") if player != null else null
	var level := _level() as Node2D
	if body == null or level == null:
		return false
	# 只检测破洞中央，不把向外延伸的细裂纹算作入口。
	var bounds: Rect2 = body.aabb
	var local_bounds := Rect2(to_local(level.to_global(bounds.position)), Vector2.ZERO)
	for corner in [bounds.end, bounds.position + Vector2(bounds.size.x, 0), bounds.position + Vector2(0, bounds.size.y)]:
		local_bounds = local_bounds.expand(to_local(level.to_global(corner)))
	var closest := Vector2(clampf(0.0, local_bounds.position.x, local_bounds.end.x),
		clampf(0.0, local_bounds.position.y, local_bounds.end.y))
	return (closest / (portal_size * 0.29)).length_squared() <= 1.0


## 连续重合；离开/编辑时清零。一次进入至多发起一次切关请求。
func advance_overlap(delta: float, inside: bool, editing: bool) -> bool:
	if editing or not inside:
		var redraw_needed := overlap_time > 0.0 or _fired or not _status.is_empty()
		overlap_time = 0.0
		_fired = false
		_status = ""
		if redraw_needed:
			queue_redraw()
		return false
	if _pending or _fired:
		return false
	overlap_time = minf(OVERLAP_SECONDS, overlap_time + maxf(delta, 0.0))
	queue_redraw()
	if overlap_time + 0.000001 < OVERLAP_SECONDS:
		return false
	_fired = true
	return true


func _physics_process(delta: float) -> void:
	var player := _level().get_node_or_null("Player") if _level() != null else null
	if advance_overlap(delta, overlaps_player(player), _editor_active()):
		_activate()


func resolve_destination() -> String:
	if not target_map.is_empty():
		return target_map if target_map.ends_with(".tscn") and ResourceLoader.exists(target_map, "PackedScene") and LevelList._has_player(target_map) else ""
	var current := _level().scene_file_path if _level() != null else ""
	var creative := _level().get_node_or_null("Creative") if _level() != null else null
	if creative != null and not str(creative.get("map_path")).is_empty():
		current = str(creative.get("map_path"))
	var levels := LevelList.find_levels()
	var index := levels.find(current)
	return levels[index + 1] if index >= 0 and index + 1 < levels.size() else ""


func _activate() -> void:
	var destination := resolve_destination()
	if destination.is_empty():
		_status = "请在编辑器设置目标地图"
		queue_redraw()
		return
	_pending = true
	_status = "正在进入…"
	queue_redraw()
	var router := get_tree().get_first_node_in_group(&"level_router")
	var succeeded := false
	if router != null:
		succeeded = await router.request_level_change(destination)
	else:
		# F6 直接运行单关时也能使用传送门。
		var error := ResourceLoader.load_threaded_request(destination, "PackedScene", false)
		if error == OK:
			while ResourceLoader.load_threaded_get_status(destination) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				await get_tree().process_frame
			if ResourceLoader.load_threaded_get_status(destination) == ResourceLoader.THREAD_LOAD_LOADED:
				var scene := ResourceLoader.load_threaded_get(destination) as PackedScene
				succeeded = get_tree().change_scene_to_packed(scene) == OK
	if not is_inside_tree():
		return
	_pending = false
	if not succeeded:
		_status = "地图加载失败，离开后可重试"
		queue_redraw()


func _draw() -> void:
	if not _editor_label.is_empty():
		var font := ThemeDB.fallback_font
		var width := maxf(portal_size.x, font.get_string_size(_editor_label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 16).x + 12.0)
		var label_position := Vector2(-width * 0.5, -portal_size.y * 0.5 - 14.0)
		draw_rect(Rect2(label_position - Vector2(0, 18), Vector2(width, 24)), Color(0.96, 0.95, 0.87, 0.85))
		draw_string(font, label_position, _editor_label, HORIZONTAL_ALIGNMENT_CENTER, width, 16, Color.BLACK)
	if _texture != null:
		draw_texture_rect(_texture, Rect2(-portal_size * 0.5, portal_size), false)
	if Engine.is_editor_hint() or _editor_active():
		draw_arc(Vector2.ZERO, minf(portal_size.x, portal_size.y) * 0.29, 0, TAU, 48, Color(0.3, 0.5, 0.8, 0.65), 2.0)
	elif overlap_time > 0.0:
		draw_arc(Vector2.ZERO, minf(portal_size.x, portal_size.y) * 0.31, -PI * 0.5,
			-PI * 0.5 + TAU * overlap_time / OVERLAP_SECONDS, 48, Color(0.95, 0.72, 0.1), 4.0)
	if not _status.is_empty():
		draw_string(ThemeDB.fallback_font, Vector2(-portal_size.x * 0.5, portal_size.y * 0.5 + 24), _status, HORIZONTAL_ALIGNMENT_CENTER, portal_size.x, 18, Color.BLACK)
