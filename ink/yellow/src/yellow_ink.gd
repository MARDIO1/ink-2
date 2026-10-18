extends Node2D

#region 配置与状态
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Stroke := preload("res://ink/yellow/src/stroke.gd")
const Hinge := preload("res://ink/yellow/src/hinge.gd")
const Rail := preload("res://ink/yellow/src/rail.gd")
const SliderPin := preload("res://ink/yellow/src/slider_pin.gd")
const SelectionMask := preload("res://actor/canvas/src/selection_mask.gd")
@export_range(0.0, 1.0, 0.01) var yellow_opacity: float = 0.75
@export_range(1.0, 64.0, 1.0) var dash_length: float = 8.0
@export_range(1.0, 64.0, 1.0) var dash_gap: float = 6.0
## 默认 7 px 支撑主角；较低阻尼保留弹弓的回弹能量。
@export var stiffness_per_width: float = 5000.0
@export var damping_ratio: float = 0.0
## 劲度变软后仍保留约 200 px 的静态安全拉伸量。
@export var safe_force_per_width: float = 1000000.0
@export var wear_pixels_per_second: float = 15.0
@export_group("弹簧音效")
@export var tension_stream: AudioStream
@export var release_stream: AudioStream
@export_range(0.01, 1.0, 0.01) var tension_sound_threshold: float = 0.15
@export_range(0.0, 0.5, 0.01) var release_sound_threshold: float = 0.05
@export_range(1, 8, 1) var spring_voice_count: int = 4
var drawing = null
var strokes: Array = []
var _world = null
var _player = null
var _mask: ImageTexture
var _mask_image: Image
var _mask_bounds: Rect2i
var _mask_revision: int = -1
var _wear_cursor: int = 0
var _spring_audio: Dictionary = {}
var _splashed_strokes: Dictionary = {}
var _spring_voices: Array[AudioStreamPlayer2D] = []
var _next_spring_voice: int = 0
var _render_opacity: float = -1.0
const OVERLAP_SHADER := preload("res://ink/yellow/asset/overlap.gdshader")
#endregion

#region 绘制与固化
func _ready() -> void:
	_world = get_parent().get_parent()
	for child in _world.get_children():
		if child is Stroke:
			strokes.append(child)
	for index in spring_voice_count:
		var voice := AudioStreamPlayer2D.new()
		voice.name = "SpringVoice%d" % index
		voice.bus = &"SFX"
		voice.max_distance = 2400.0
		voice.attenuation = 1.0
		add_child(voice)
		_spring_voices.append(voice)

func begin(surface, point: Vector2) -> void:
	cancel()
	if not valid_anchor(surface, point):
		return
	drawing = Stroke.new()
	drawing.preview = true
	drawing.compact_raster = true
	drawing.dashed = true
	drawing.dash_length = dash_length
	drawing.dash_gap = dash_gap
	drawing.source_surface = surface
	drawing.brush_width = surface.brush_size
	drawing.path.append(_world.to_local(surface.to_global(point.floor() + Vector2.ONE * 0.5)))
	_world.add_child(drawing)
	drawing.queue_redraw()

func extend(surface, point: Vector2) -> void:
	if drawing == null or drawing.source_surface != surface:
		return
	if not surface._inside(point):
		cancel()
		return
	var p: Vector2 = _world.to_local(surface.to_global(point))
	if drawing.path.size() == 1:
		drawing.path.append(p)
	else:
		drawing.path[1] = p
	if drawing.path.size() > 1:
		drawing.queue_redraw()

## 被否掉的笔画（太短 / 没锚点 / 没连通 / 超墨量）不再"啪"地消失：先短淡出再 free。
## ⚠️ 判据一个字没改，只是给它一个收场 —— 观感上不该有东西凭空不见。
## 被否掉的正是 preview 状态，而 preview 笔画才是可见的那一份（见 yellow_stroke.gd 的 _draw）。
const DISCARD_FADE := 0.18


func _discard(stroke) -> void:
	if not is_instance_valid(stroke):
		return
	if not stroke.is_inside_tree():
		stroke.queue_free()
		return
	var tween: Tween = stroke.create_tween()
	tween.tween_property(stroke, "modulate:a", 0.0, DISCARD_FADE)
	tween.tween_callback(stroke.queue_free)


func finish(surface, point: Vector2) -> bool:
	if drawing == null or drawing.source_surface != surface:
		return false
	var stroke = drawing
	drawing = null
	stroke.path.append(_world.to_local(surface.to_global(point.floor() + Vector2.ONE * 0.5)))
	if not surface._inside(point) or not valid_anchor(surface, point) \
	or not endpoint_legal(stroke.path[0]) or not endpoint_legal(stroke.path[-1]):
		_discard(stroke)
		return false
	var distance: float = stroke.path[0].distance_to(stroke.path[-1])
	if distance > 0.001 and distance < 9.0:
		_discard(stroke)
		return false
	stroke.preview = false
	if not stroke.build_pixels() or not stroke.connected():
		_discard(stroke)
		return false
	if not surface.ink_free and stroke.original_area > surface._drawable_ink_room(Palette.YELLOW.id):
		surface._warn_ink_shortage(stroke.original_area + surface.MIN_PAINT_INK - 1)
		_discard(stroke)
		return false
	stroke.paid = not surface.ink_free
	var health = surface._health_node()
	if stroke.paid and health != null:
		health.reduce(Palette.YELLOW.id, stroke.original_area)
	strokes.append(stroke)
	stroke.source_canvas = _world.get_path_to(surface)
	stroke.owner = _world
	stroke.set_meta(&"canvas_undo_identity", stroke.get_instance_id())
	surface.push_undo_step({"yellow": stroke, "yellow_id": stroke.get_instance_id()})
	stroke.queue_redraw()
	return true

func cancel() -> void:
	if is_instance_valid(drawing):
		_discard(drawing)
	drawing = null

func endpoint_legal(point: Vector2) -> bool:
	for stroke in strokes:
		if stroke.state > Stroke.State.ACTIVE:
			continue
		var points: Array = [stroke.path[0], stroke.path[-1]]
		if stroke.state == Stroke.State.ACTIVE and stroke.anchors.size() == 2:
			points = [Stroke.anchor_world(stroke.anchors[0]), Stroke.anchor_world(stroke.anchors[1])]
		for other: Vector2 in points:
			var distance: float = point.distance_to(other)
			if distance > 0.001 and distance < 9.0:
				return false
	return true

func valid_anchor(surface, point: Vector2) -> bool:
	if not surface._inside(point):
		return false
	var cell: Vector2i = Vector2i(point.floor())
	return surface.material_at(cell.x, cell.y) == Palette.BLACK.id

func erase_spring_ends(surface, from: Vector2, to: Vector2) -> void:
	for stroke in strokes.duplicate():
		if stroke.state != Stroke.State.EDITING or stroke.source_surface != surface:
			continue
		if stroke.path.size() < 2:
			continue
		var a: Vector2 = surface.to_local(_world.to_global(stroke.path[0]))
		var b: Vector2 = surface.to_local(_world.to_global(stroke.path[-1]))
		var reach: float = (surface.brush_size + stroke.brush_width) * 0.5
		if Geometry2D.segment_intersects_segment(from, to, a, b) != null \
		or a.distance_to(Geometry2D.get_closest_point_to_segment(a, from, to)) <= reach \
		or b.distance_to(Geometry2D.get_closest_point_to_segment(b, from, to)) <= reach \
		or from.distance_to(Geometry2D.get_closest_point_to_segment(from, a, b)) <= reach \
		or to.distance_to(Geometry2D.get_closest_point_to_segment(to, a, b)) <= reach:
			undo(stroke, surface)


func erase_strokes_in_rect(surface, rect: Rect2i, mask: Dictionary = {}) -> bool:
	var erased := false
	for stroke in strokes.duplicate():
		if not is_instance_valid(stroke) or stroke.source_surface != surface \
		or stroke.state >= Stroke.State.DYING:
			continue
		var hit := false
		for cell: Vector2i in stroke.cells:
			var point := Vector2i(surface.to_local(stroke.pixel_world(Vector2(cell) + Vector2.ONE * 0.5)).floor())
			if rect.has_point(point) and SelectionMask.contains(mask, point):
				hit = true
				break
		if not hit:
			continue
		stroke.remove_joint()
		refund(stroke, surface, stroke.cells.size())
		strokes.erase(stroke)
		stroke.get_parent().remove_child(stroke)
		stroke.queue_free()
		erased = true
	return erased


## 只有整条弹簧位于框内才移动，避免只搬走一个端点破坏约束。
func move_drafts_in_rect(surface, rect: Rect2i, offset: Vector2i, mask: Dictionary = {}) -> bool:
	if offset == Vector2i.ZERO:
		return false
	var delta: Vector2 = _world.to_local(surface.to_global(Vector2(offset))) \
		- _world.to_local(surface.to_global(Vector2.ZERO))
	var global_delta: Vector2 = surface.to_global(Vector2(offset)) - surface.to_global(Vector2.ZERO)
	var moved := false
	for stroke in strokes:
		if not is_instance_valid(stroke) or stroke.source_surface != surface \
		or stroke.state != Stroke.State.EDITING or not stroke.compact_raster \
		or stroke.path.size() < 2:
			continue
		var first := Vector2i(surface.to_local(_world.to_global(stroke.path[0])).floor())
		var last := Vector2i(surface.to_local(_world.to_global(stroke.path[-1])).floor())
		if not rect.has_point(first) or not rect.has_point(last):
			continue
		if not SelectionMask.contains(mask, first) or not SelectionMask.contains(mask, last):
			continue
		for index in stroke.path.size():
			stroke.path[index] += delta
		if is_instance_valid(stroke.visual):
			stroke.visual.position += delta
		if is_instance_valid(stroke.endpoint_a):
			stroke.endpoint_a.global_position += global_delta
		if is_instance_valid(stroke.endpoint_b):
			stroke.endpoint_b.global_position += global_delta
		stroke.queue_redraw()
		moved = true
	return moved

func draft_data(surface) -> Array:
	var data: Array = []
	for stroke in strokes:
		if stroke.source_surface == surface and stroke.state == Stroke.State.EDITING:
			data.append({"path": stroke.path, "width": stroke.brush_width, "paid": stroke.paid,
				"worn": stroke.worn, "dash_length": stroke.dash_length, "dash_gap": stroke.dash_gap})
	return data

func restore_drafts(surface, data: Array, charge := false) -> void:
	clear_drafts(surface)
	for saved in data:
		var stroke := Stroke.new()
		stroke.path = saved.path
		stroke.brush_width = saved.width
		stroke.worn = saved.worn
		stroke.compact_raster = true
		stroke.dashed = true
		stroke.dash_length = saved.dash_length
		stroke.dash_gap = saved.dash_gap
		stroke.paid = saved.paid
		stroke.source_surface = surface
		stroke.source_canvas = _world.get_path_to(surface)
		_world.add_child(stroke)
		stroke.owner = _world
		strokes.append(stroke)
		if charge and stroke.paid:
			var health = surface._health_node()
			if health != null:
				health.reduce(Palette.YELLOW.id, stroke.cells.size())

func solidify(surface) -> void:
	for stroke in strokes.duplicate():
		if stroke.source_surface != surface or stroke.state != Stroke.State.EDITING:
			continue
		stroke.anchors = [Stroke.find_anchor(_world.world, stroke.path[0]),
			Stroke.find_anchor(_world.world, stroke.path[-1])]
		if stroke.anchors[0].is_empty() or stroke.anchors[1].is_empty():
			refund(stroke, surface, stroke.cells.size())
			strokes.erase(stroke)
			stroke.queue_free()
			continue
		stroke.rest_length = stroke.path[0].distance_to(stroke.path[-1])
		stroke.saved_anchor_a = stroke.path[0]
		stroke.saved_anchor_b = stroke.path[-1]
		stroke.state = Stroke.State.ACTIVE
		stroke.activated = true
		stroke.owner = _world
		connect_stroke(stroke, _world.world)

func clear_drafts(surface) -> void:
	if drawing != null and drawing.source_surface == surface:
		cancel()
	for stroke in strokes.duplicate():
		if stroke.source_surface == surface and stroke.state == Stroke.State.EDITING:
			refund(stroke, surface, stroke.cells.size())
			strokes.erase(stroke)
			stroke.queue_free()

func reclaim(surface, keep_drafts := false, preserved: Dictionary = {}) -> void:
	for stroke in strokes.duplicate():
		if stroke.get_meta(&"corroded", false):
			continue
		if stroke.state == Stroke.State.EDITING:
			continue
		if not preserved.is_empty() and not stroke.anchors.is_empty():
			var kept := false
			for anchor: Dictionary in stroke.anchors:
				if preserved.has(anchor.get("body")):
					kept = true
					break
			if kept:
				continue
		var selected: Array[Vector2i] = []
		for cell: Vector2i in stroke.cells:
			if surface._inside(surface.to_local(stroke.pixel_world(Vector2(cell) + Vector2.ONE * 0.5))):
				selected.append(cell)
		if selected.is_empty():
			continue
		if keep_drafts and selected.size() == stroke.cells.size() and stroke.state == Stroke.State.ACTIVE:
			# 编辑器需要保留整条黄墨弹簧：卸掉关节，转回可再次固化的草稿。
			stroke.remove_joint()
			stroke.anchors.clear()
			stroke.activated = false
			stroke.state = Stroke.State.EDITING
			stroke.source_surface = surface
			stroke.source_canvas = _world.get_path_to(surface)
			continue
		refund(stroke, surface, selected.size())
		for cell in selected:
			stroke.cells.erase(cell)
			stroke.occupancy.clear_pixel(cell.x, cell.y)
			stroke.worn.append(Vector2(cell))
			if stroke.image != null:
				stroke.image.set_pixelv(cell - stroke.bounds.position, Color.TRANSPARENT)
		if stroke.texture != null:
			stroke.texture.update(stroke.image)
		if stroke.state == Stroke.State.ACTIVE:
			stroke.fail()
		if stroke.cells.is_empty():
			strokes.erase(stroke)
			stroke.queue_free()

func refund(stroke, surface, amount: int) -> void:
	var health = surface._health_node()
	if stroke.paid and health != null:
		health.add(Palette.YELLOW.id, amount)


## 缩小地图时只裁掉旧画布中被移除的区域，不影响画布外的其他黄墨。
func crop_to_surface(surface, kept: Rect2i) -> void:
	if drawing != null and drawing.source_surface == surface:
		cancel()
	var original := Rect2i(Vector2i.ZERO, surface.canvas_size)
	for stroke in strokes.duplicate():
		var removed: Array[Vector2i] = []
		for cell: Vector2i in stroke.cells:
			var pixel := Vector2i(surface.to_local(stroke.pixel_world(Vector2(cell) + Vector2.ONE * 0.5)).floor())
			if original.has_point(pixel) and not kept.has_point(pixel):
				removed.append(cell)
		if removed.is_empty():
			continue
		refund(stroke, surface, removed.size())
		for cell in removed:
			stroke.cells.erase(cell)
			stroke.occupancy.clear_pixel(cell.x, cell.y)
			stroke.worn.append(Vector2(cell))
			if stroke.image != null:
				stroke.image.set_pixelv(cell - stroke.bounds.position, Color.TRANSPARENT)
		if stroke.texture != null:
			stroke.texture.update(stroke.image)
		if stroke.state == Stroke.State.ACTIVE:
			stroke.fail()
		if stroke.cells.is_empty():
			strokes.erase(stroke)
			stroke.queue_free()

func undo(stroke, surface) -> void:
	if not is_instance_valid(stroke) or not strokes.has(stroke) or stroke.state != Stroke.State.EDITING:
		return
	refund(stroke, surface, stroke.cells.size())
	strokes.erase(stroke)
	stroke.queue_free()
#endregion

#region 物理与破坏
func service_name() -> StringName:
	return &"yellow"

## 化学擦除立即移除约束；沿用死亡动画，保证静止弹簧也播放释放声。
func dissolve(stroke) -> void:
	if stroke.state != Stroke.State.ACTIVE:
		return
	var at: Vector2 = stroke.pixel_world(Vector2(stroke.bounds.get_center()))
	_spring_audio.erase(stroke.get_instance_id())
	_play_spring(release_stream, at, spring_volume_db(1.0), 1.0)
	stroke.fail()
	# 消散后的笔画不再可回收，也不再计入地图存档。
	stroke.paid = false
	stroke.set_meta(&"corroded", true)

func connect_stroke(stroke, world) -> void:
	if stroke.joint != null and stroke.joint.is_active():
		return
	var a = stroke.anchors[0].body
	var b = stroke.anchors[1].body
	if a == b or (a.is_static and b.is_static):
		return
	var inverse_mass: float = a.inv_mass + b.inv_mass
	var stiffness: float = stiffness_per_width * stroke.brush_width
	var damping: float = 2.0 * damping_ratio * sqrt(stiffness / maxf(inverse_mass, 0.000001))
	stroke.joint = world.add_spring(a, b, Stroke.anchor_world(stroke.anchors[0]),
		Stroke.anchor_world(stroke.anchors[1]), stroke.rest_length, stiffness, damping)
	stroke.joint.contacts_enabled = true

func spring_load(stroke) -> float:
	return absf(_spring_tension(stroke))

## 作用在第一个锚点上的力；与关节相同的弹簧/阻尼模型估算，供磨损和 Tab 共用。
func spring_force(stroke) -> Vector2:
	if stroke.anchors.size() != 2:
		return Vector2.ZERO
	var a: Vector2 = Stroke.anchor_world(stroke.anchors[0])
	var b: Vector2 = Stroke.anchor_world(stroke.anchors[1])
	return (b - a).normalized() * _spring_tension(stroke)

func _spring_tension(stroke) -> float:
	if stroke.joint == null:
		return 0.0
	var a: Vector2 = Stroke.anchor_world(stroke.anchors[0])
	var b: Vector2 = Stroke.anchor_world(stroke.anchors[1])
	var direction: Vector2 = (b - a).normalized()
	var speed: float = (stroke.anchors[1].body.velocity_at(b) - stroke.anchors[0].body.velocity_at(a)).dot(direction)
	# SpringJoint 的马达冲量没有包含在当前桥接器的线性冲量读回里。
	# 按相同弹簧/阻尼模型估算载荷，避免把持续受力误读成零。
	return stroke.joint.stiffness * (a.distance_to(b) - stroke.rest_length) + stroke.joint.damping * speed

func observe_fracture(world, body, pieces: Array) -> void:
	for child in _world.get_children().duplicate():
		if child is Hinge and not child.is_queued_for_deletion():
			child.rebind(world, body, pieces)
		elif child is Rail and not child.is_queued_for_deletion():
			child.rebind(world, body, pieces)
		elif child is SliderPin and not child.is_queued_for_deletion():
			child.rebind(world, body, pieces)
	for stroke in strokes:
		stroke.rebind(world, body, pieces)
		if stroke.state == Stroke.State.ACTIVE and stroke.anchors.size() == 2:
			connect_stroke(stroke, world)

func resolve_fixed(context: Dictionary) -> Dictionary:
	var world = context.world
	var delta: float = _world.fixed_dt
	_player = context.get("player_body")
	# SLIDER 本身没有有限端点；每个固定物理步都按关节真实行程检查脱轨，
	# 不依赖渲染帧或画布是否正在显示。
	for child in _world.get_children():
		if child is SliderPin and not child.is_queued_for_deletion():
			child.update_constraint_state()
	var wear_started: int = Time.get_ticks_usec()
	for offset in strokes.size():
		var stroke = strokes[(offset + _wear_cursor) % strokes.size()]
		if stroke.state != Stroke.State.ACTIVE:
			if stroke.state == Stroke.State.DYING:
				_emit_stroke_splash(stroke)
			_release_tracked_spring(stroke.get_instance_id())
			continue
		for index in stroke.anchors.size():
			var anchor: Dictionary = stroke.anchors[index]
			if not world.bodies.has(anchor.body) or not Stroke.has_black(anchor.body, anchor.cell):
				stroke.fail(index)
				break
		if stroke.state != Stroke.State.ACTIVE:
			continue
		connect_stroke(stroke, world)
		if stroke.joint == null:
			continue
		var load: float = spring_load(stroke)
		var safe_load := maxf(safe_force_per_width * stroke.brush_width, 0.001)
		_update_spring_audio(stroke, load / safe_load)
		stroke.wear_credit += wear_pixels_per_second * maxf(0.0,
			load / (safe_force_per_width * stroke.brush_width) - 1.0) * delta
		stroke.wear_elapsed += delta
		if stroke.wear_elapsed >= 0.1 and stroke.wear_credit >= 1.0 \
		and Time.get_ticks_usec() - wear_started < 2000:
			var count: int = mini(256, int(stroke.wear_credit))
			stroke.wear_credit -= count
			stroke.wear_elapsed = 0.0
			stroke.erode(count)
	_wear_cursor = (_wear_cursor + 1) % maxi(1, strokes.size())
	return {}


## 黄色不是 PBody 像素删除；整根进入死亡态时显式交给通用飞溅层，且只发一次。
func _emit_stroke_splash(stroke) -> void:
	var key: int = stroke.get_instance_id()
	if _splashed_strokes.has(key):
		return
	_splashed_strokes[key] = true
	var splash = get_parent().get_node_or_null("InkSplash")
	if splash == null or not splash.has_method("emit_splash"):
		return
	var center: Vector2 = stroke.pixel_world(Vector2(stroke.bounds.get_center()))
	var direction := Vector2.UP
	if stroke.raster_path.size() >= 2:
		direction = (stroke.pixel_world(stroke.raster_path[-1])
			- stroke.pixel_world(stroke.raster_path[0])).orthogonal().normalized()
	splash.emit_splash(center, direction, float(stroke.cells.size()), Palette.YELLOW.id)


## 载荷分为三档；每跨一档重放一次紧绷声，使用至少 6 dB 的级差，避免听感挤在一起。
func _update_spring_audio(stroke, ratio: float) -> void:
	var key: int = stroke.get_instance_id()
	var position := (Stroke.anchor_world(stroke.anchors[0]) + Stroke.anchor_world(stroke.anchors[1])) * 0.5
	if ratio < tension_sound_threshold:
		if ratio <= release_sound_threshold:
			_release_tracked_spring(key, position)
		return
	var state: Dictionary = _spring_audio.get(key, {"peak": 0.0, "band": 0, "position": position})
	state.peak = maxf(float(state.peak), ratio)
	state.position = position
	var band := spring_load_band(ratio)
	if band > int(state.band):
		_play_spring(tension_stream, position, spring_volume_db(band / 3.0), lerpf(1.08, 0.94, band / 3.0))
		state.band = band
	_spring_audio[key] = state


func _release_tracked_spring(key: int, position: Vector2 = Vector2.INF) -> void:
	if not _spring_audio.has(key):
		return
	var state: Dictionary = _spring_audio[key]
	var at: Vector2 = state.position if position == Vector2.INF else position
	_play_spring(release_stream, at, spring_volume_db(float(state.peak)), 1.0)
	_spring_audio.erase(key)


func spring_load_band(ratio: float) -> int:
	if ratio < tension_sound_threshold:
		return 0
	var span := maxf(1.0 - tension_sound_threshold, 0.001)
	return clampi(1 + floori((ratio - tension_sound_threshold) / span * 3.0), 1, 3)


func spring_volume_db(ratio: float) -> float:
	return lerpf(-14.0, 0.0, sqrt(clampf(ratio, 0.0, 1.0)))


func _play_spring(stream: AudioStream, position: Vector2, volume_db: float, pitch: float) -> void:
	if stream == null or _spring_voices.is_empty():
		return
	var voice: AudioStreamPlayer2D = _spring_voices[_next_spring_voice]
	_next_spring_voice = (_next_spring_voice + 1) % _spring_voices.size()
	voice.stream = stream
	voice.global_position = position
	voice.volume_db = volume_db
	voice.pitch_scale = pitch * randf_range(0.98, 1.02)
	voice.play()

func _process(delta: float) -> void:
	var color: Color = Palette.YELLOW.color
	if not is_equal_approx(_render_opacity, yellow_opacity):
		_render_opacity = yellow_opacity
		color.a = yellow_opacity
		_world.renderer.set_material_color(Palette.YELLOW.id, color)
		_world.renderer.mark_all_dirty()
	for stroke in strokes.duplicate():
		stroke.modulate.a = yellow_opacity
		if stroke.state == Stroke.State.ACTIVE:
			stroke.update_visual()
		elif stroke.state == Stroke.State.DYING:
			stroke.animate_death(delta)
		elif stroke.state == Stroke.State.REMOVED and stroke.get_meta(&"corroded", false):
			strokes.erase(stroke)
			stroke.queue_free()
		elif stroke.state == Stroke.State.EDITING and is_instance_valid(stroke.source_surface):
			stroke.visible = stroke.source_surface.is_visible_in_tree()
	_update_overlap()

func _update_overlap() -> void:
	if strokes.is_empty() or _player == null or not _world.visible:
		return
	var revision: int = 0
	for shape in _player.shapes:
		revision += shape.revision
	if revision != _mask_revision:
		_mask_revision = revision
		_mask_bounds = Rect2i()
		for shape in _player.shapes:
			var rect: Rect2i = shape.local_aabb()
			_mask_bounds = rect if _mask_bounds.size == Vector2i.ZERO else _mask_bounds.merge(rect)
		if _mask_bounds.size == Vector2i.ZERO:
			return
		_mask_image = Image.create_empty(_mask_bounds.size.x, _mask_bounds.size.y, false, Image.FORMAT_RGBA8)
		for shape in _player.shapes:
			for y in range(_mask_bounds.position.y, _mask_bounds.end.y):
				for x in range(_mask_bounds.position.x, _mask_bounds.end.x):
					if shape.get_pixel(x, y) != 0:
						_mask_image.set_pixelv(Vector2i(x, y) - _mask_bounds.position, Color.WHITE)
		_mask = ImageTexture.create_from_image(_mask_image)
	for stroke in strokes:
		if stroke.visual == null or not stroke.visible:
			continue
		var material: ShaderMaterial = stroke.visual.material
		if material == null:
			material = ShaderMaterial.new()
			material.shader = OVERLAP_SHADER
			stroke.visual.material = material
		material.set_shader_parameter("player_mask", _mask)
		material.set_shader_parameter("player_origin", _player.position)
		material.set_shader_parameter("player_angle", _player.rotation)
		material.set_shader_parameter("mask_origin", Vector2(_mask_bounds.position))
		material.set_shader_parameter("mask_size", Vector2(_mask_bounds.size))
		var player_node = _world.get_node_or_null("Player")
		material.set_shader_parameter("mask_enabled", player_node != null and player_node.is_visible_in_tree())
		stroke.endpoint_a.material = material
		stroke.endpoint_b.material = material
#endregion
