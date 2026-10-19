@tool
extends Node2D
## 仅观察自定义 PixelWorld 玩家碰撞壳，不使用 Godot Area2D 的另一套物理世界。

const GROUP := &"map_portal"
const LevelList := preload("res://ui/level_select/src/level_select.gd")
const ContentPaths := preload("res://map/src/content_paths.gd")
const TEXTURE_PATH := "res://actor/portal/asset/torn_paper_portal.png"
const OVERLAP_SECONDS := 2.0
const COMPLETION_PULSE_SECONDS := 0.45
const PROGRESS_INK := Color.BLACK
const PROGRESS_PAPER := Color.WHITE
const SPIRAL_SHADER := preload("res://actor/portal/asset/portal_spiral.gdshader")
static var _center_mask: Texture2D
static var _center_mask_source: Texture2D

@export_file("*.tscn") var target_map := ""
@export var portal_size := Vector2(150.0, 150.0):
	set(value):
		portal_size = value
		_sync_visual_size()
		queue_redraw()
## 每秒旋转弧度；暂停菜单打开时动画也暂停。
@export var spiral_rotation_speed := 0.7
var _spiral: Sprite2D
var _paper_frame: Sprite2D
var _spiral_material: ShaderMaterial
var _spiral_phase := 0.0
var overlap_time := 0.0
var _fired := false
var _pending := false
var _status := ""
var _texture: Texture2D
var _editor_label := ""
var _label_refresh_elapsed := 0.5
var _charge_clock := 0.0
var _completion_elapsed := -1.0


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	# 世界显示层最上方：瓶身 > 瓶内墨水 > 手掌 > 虚线手臂 > 传送门。
	# 仅调整 CanvasItem 排序，保持 PixelWorld 的碰撞与触发逻辑。
	z_index = 4092
	z_as_relative = false
	process_physics_priority = 100
	_paper_frame = get_node_or_null("PaperFrame") as Sprite2D
	_texture = _paper_frame.texture if _paper_frame != null and _paper_frame.texture != null else load(TEXTURE_PATH) as Texture2D
	if _texture != null and (_center_mask == null or _center_mask_source != _texture):
		_center_mask = _make_center_mask(_texture.get_image())
		_center_mask_source = _texture
	_setup_spiral()
	_sync_visual_size()
	queue_redraw()
	set_physics_process(not Engine.is_editor_hint())


func _setup_spiral() -> void:
	if _center_mask == null:
		return
	_spiral = get_node_or_null("SpiralCenter") as Sprite2D
	if _spiral == null:
		# 兼容旧地图中只有 map_portal.gd 的节点，不要求重写地图或快照。
		_spiral = Sprite2D.new()
		_spiral.name = "SpiralCenter"
		add_child(_spiral)
	_spiral.texture = _center_mask
	_spiral.show_behind_parent = true
	# 材质保持实例独立，旋转一个门不能影响其他门的动画。
	_spiral_material = _spiral.material.duplicate() as ShaderMaterial if _spiral.material is ShaderMaterial else ShaderMaterial.new()
	if _spiral_material.shader == null:
		_spiral_material.shader = SPIRAL_SHADER
	_spiral.material = _spiral_material


func _sync_visual_size() -> void:
	if is_instance_valid(_spiral) and _spiral.texture != null:
		_spiral.scale = portal_size / Vector2(_spiral.texture.get_size())
	if is_instance_valid(_paper_frame) and _paper_frame.texture != null:
		_paper_frame.scale = portal_size / Vector2(_paper_frame.texture.get_size())


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
	var editing := Engine.is_editor_hint() or _editor_active()
	var charge := 0.0 if editing else _charge_progress()
	if is_instance_valid(_spiral):
		_spiral_phase = fposmod(_spiral_phase + delta * spiral_rotation_speed * (1.0 + charge * 2.5), TAU)
		_spiral_material.set_shader_parameter("phase", _spiral_phase)
		_spiral_material.set_shader_parameter("charge", charge)
	if charge > 0.0:
		_charge_clock += maxf(delta, 0.0)
		if _completion_elapsed >= 0.0:
			_completion_elapsed += maxf(delta, 0.0)
			if _completion_elapsed >= COMPLETION_PULSE_SECONDS:
				_completion_elapsed = -1.0
		queue_redraw()
	else:
		_charge_clock = 0.0
		_completion_elapsed = -1.0
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
	return creative != null and creative.get("active") == true


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
		_charge_clock = 0.0
		_completion_elapsed = -1.0
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
	_completion_elapsed = 0.0
	return true


func _charge_progress() -> float:
	# 目标缺失或加载失败时停止蓄力反馈，保留错误提示，不表现成持续传送。
	if _fired and not _pending and not _status.is_empty():
		return 0.0
	return clampf(overlap_time / OVERLAP_SECONDS, 0.0, 1.0)


## 黑白双色描边在黑墨、白纸背景上都可辨认；不改变门、玩家或触发范围。
func _draw_charge(progress: float) -> void:
	var radius := minf(portal_size.x, portal_size.y) * 0.39
	var start := -PI * 0.5
	var finish := start + TAU * progress
	# 先给整圈一条轻轨道，再以白底黑芯画出准确的两秒进度。
	draw_arc(Vector2.ZERO, radius, 0, TAU, 80, Color(0, 0, 0, 0.45), 3.0, true)
	draw_arc(Vector2.ZERO, radius, 0, TAU, 80, Color(1, 1, 1, 0.65), 1.0, true)
	draw_arc(Vector2.ZERO, radius, start, finish, 80, PROGRESS_PAPER, 10.0, true)
	draw_arc(Vector2.ZERO, radius, start, finish, 80, PROGRESS_INK, 5.0, true)
	var tip := Vector2.from_angle(finish) * radius
	draw_circle(tip, 6.0, PROGRESS_PAPER)
	draw_circle(tip, 3.0, PROGRESS_INK)
	# 外圈轻微呼吸、分段刻度和向心墨点让站在门内的反馈更清楚，不闪屏或震屏。
	var breath := 0.5 + sin(_charge_clock * TAU * 1.25) * 0.5
	var halo_radius := radius + 8.0 + breath * 3.0
	draw_arc(Vector2.ZERO, halo_radius, 0, TAU, 80, Color(1, 1, 1, 0.35 + breath * 0.35), 3.0, true)
	draw_arc(Vector2.ZERO, halo_radius, 0, TAU, 80, Color(0, 0, 0, 0.35), 1.0, true)
	for index in 12:
		var direction := Vector2.from_angle(start + TAU * index / 12.0)
		var filled := progress * 12.0 >= index + 1
		var end := radius + (9.0 if filled else 6.0)
		draw_line(direction * (radius + 3.0), direction * end, PROGRESS_PAPER, 4.0, true)
		draw_line(direction * (radius + 3.0), direction * end, PROGRESS_INK, 2.0, true)
	for index in 8:
		var travel := fposmod(_charge_clock * (0.7 + progress * 0.35) + index / 8.0, 1.0)
		var angle := TAU * index / 8.0 + travel * 0.65 + _charge_clock * 0.25
		var point := Vector2.from_angle(angle) * lerpf(radius * 0.88, radius * 0.16, travel)
		var extent := (1.0 - travel * 0.6) * (2.0 + progress)
		draw_circle(point, extent + 1.0, PROGRESS_PAPER)
		draw_circle(point, extent, PROGRESS_INK)
	if _completion_elapsed >= 0.0:
		var pulse := clampf(_completion_elapsed / COMPLETION_PULSE_SECONDS, 0, 1)
		var reach := radius + 26.0 * pulse
		draw_arc(Vector2.ZERO, reach, 0, TAU, 80, Color(1, 1, 1, 1.0 - pulse), 8.0, true)
		draw_arc(Vector2.ZERO, reach, 0, TAU, 80, Color(0, 0, 0, 1.0 - pulse), 3.0, true)


func _physics_process(delta: float) -> void:
	var player := _level().get_node_or_null("Player") if _level() != null else null
	if advance_overlap(delta, overlaps_player(player), _editor_active()):
		_activate()


func resolve_destination() -> String:
	if not target_map.is_empty():
		return target_map if target_map.ends_with(".tscn") \
			and ContentPaths.resource_exists(target_map, "PackedScene") \
			and LevelList._has_player(target_map) else ""
	var current := _level().scene_file_path if _level() != null else ""
	var creative := _level().get_node_or_null("Creative") if _level() != null else null
	if creative != null and not str(creative.get("map_path")).is_empty():
		current = str(creative.get("map_path"))
	return LevelList.next_level(current)


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
		var load_path := ContentPaths.resolve(destination)
		var error := ResourceLoader.load_threaded_request(load_path, "PackedScene", false)
		if error == OK:
			while ResourceLoader.load_threaded_get_status(load_path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				await get_tree().process_frame
			if ResourceLoader.load_threaded_get_status(load_path) == ResourceLoader.THREAD_LOAD_LOADED:
				var scene := ResourceLoader.load_threaded_get(load_path) as PackedScene
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
	# 新场景由 PaperFrame 显示；旧地图仍沿用脚本绘制，避免重复画两层纸框。
	if _texture != null and not is_instance_valid(_paper_frame):
		draw_texture_rect(_texture, Rect2(-portal_size * 0.5, portal_size), false)
	if Engine.is_editor_hint() or _editor_active():
		var radius := minf(portal_size.x, portal_size.y) * 0.29
		draw_arc(Vector2.ZERO, radius, 0, TAU, 48, PROGRESS_PAPER, 3.0, true)
		draw_arc(Vector2.ZERO, radius, 0, TAU, 48, Color(0, 0, 0, 0.65), 1.0, true)
	elif _charge_progress() > 0.0:
		_draw_charge(_charge_progress())
	if not _status.is_empty():
		draw_string(ThemeDB.fallback_font, Vector2(-portal_size.x * 0.5, portal_size.y * 0.5 + 24), _status, HORIZONTAL_ALIGNMENT_CENTER, portal_size.x, 18, Color.BLACK)
