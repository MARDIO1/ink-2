extends Node2D
## HUD 上的力观察器：接触冲量按固定步累加；关节合力用动量差扣除已知力得到。
## 引擎未暴露逐关节矢量，余项不冒充某一个关节的精确反力。由 HUD 的 Tab 统一开关。
## 是否采样并绘制力矢量；HUD 的 Tab 显隐另行控制。
@export var enabled: bool = true
## 力到箭头长度的显示倍率，只影响调试画面，不修改物理力。
@export var force_scale: float = 0.000015
@onready var main = $"../.."
@onready var hand = $"../../Player/Arm/Hand/HandControl"
@onready var feet = $"../../Player/PlayerInput"
var arrows: Array = []
var momentum: Dictionary = {}
var contact_impulses: Dictionary = {}
var known_impulses: Dictionary = {}
var indices: Dictionary = {}
var support = null
var step_time: float = 0.0
var profile_enabled: bool = false
var _profile: Dictionary = {}
const COLORS: Array[Color] = [Color.CYAN, Color.ORANGE, Color.LIME_GREEN, Color.YELLOW, Color.GRAY, Color.CORNFLOWER_BLUE, Color.MAGENTA, Color.RED, Color.DODGER_BLUE, Color.DARK_GOLDENROD]

#region 固定步采样
func _ready() -> void:
	process_physics_priority = -40

func _physics_process(_delta: float) -> void:
	if not enabled:
		return
	arrows.clear()
	momentum.clear()
	contact_impulses.clear()
	known_impulses.clear()
	indices.clear()
	step_time = 0.0
	support = feet.support
	for body in main.world.bodies:
		if body.frozen:
			continue
		momentum[body] = body.linear_velocity * body.mass

## 每个规则固定步采样，保留每支箭头/弹簧，不能把同体上相反的两支先合并隐藏。
func sample_rule_forces(delta: float) -> void:
	if not enabled:
		return
	var blue = main.get_node_or_null("SimulationRuntime/BlueInk")
	if blue != null:
		for motor in blue.objects(blue.Motor):
			if not motor.active or motor.body == null or motor.is_queued_for_deletion():
				continue
			var force: Vector2 = motor.tip.normalized().rotated(motor.rotation) * motor.applied_force
			var title := "blue #%d" % motor.get_index()
			_record_rule_force(motor.body, title, motor.position, force, delta, 8)
			arrows[indices[motor.body][title]]["power"] = motor.received_power
	var yellow = main.get_node_or_null("SimulationRuntime/YellowInk")
	if yellow != null:
		for stroke in yellow.strokes:
			if stroke.joint == null or not stroke.joint.is_active() or stroke.anchors.size() != 2:
				continue
			var force: Vector2 = yellow.spring_force(stroke)
			for index in 2:
				var anchor: Dictionary = stroke.anchors[index]
				_record_rule_force(anchor.body, "spring~ #%d" % stroke.get_index(), yellow.Stroke.anchor_world(anchor), force if index == 0 else -force, delta, 9)

func _record_rule_force(body, title: String, point: Vector2, force: Vector2, delta: float, color: int) -> void:
	_add(body, title, point, force * delta, color)
	known_impulses[body] = known_impulses.get(body, Vector2.ZERO) + force * delta

func sample_contacts(contacts: Array, delta: float) -> void:
	if not enabled:
		return
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	step_time += delta
	for contact in contacts:
		# 休眠流形可能保留上次冲量，不能把缓存当成当前子步的新力。
		if (contact.a.is_static or not contact.a.awake) and (contact.b.is_static or not contact.b.awake):
			continue
		for point in contact.points:
			var normal: Vector2 = point.normal * point.impulse
			var friction: Vector2 = Vector2(-point.normal.y, point.normal.x) * point.tangent_impulse
			for side in [[contact.a, -1.0], [contact.b, 1.0]]:
				var body = side[0]
				contact_impulses[body] = contact_impulses.get(body, Vector2.ZERO) + (normal + friction) * side[1]
				# 同点各分量分别画，子步同类箭头合并，避免越多子步越多图元。
				_add(body, "N", point.position, normal * side[1], 5)
				_add(body, "friction", point.position, friction * side[1], 6)
	if profile_enabled:
		_profile.sample_us = _profile.get("sample_us", 0) + Time.get_ticks_usec() - profile_start

func finish(delta: float) -> void:
	if not enabled or step_time <= 0.0:
		return
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	for arrow in arrows:
		arrow.force /= step_time
	var active: Dictionary = {}
	for side in [[hand.body, 1.0], [hand.player_body, -1.0]]:
		_add(side[0], "hand P", side[0].com_world(), hand.debug_p_force * side[1], 0)
		_add(side[0], "hand D", side[0].com_world(), hand.debug_d_force * side[1], 1)
		active[side[0]] = hand.debug_force_vector * side[1] * delta
	for side in [[feet.player.body, 1.0], [support, -1.0]]:
		if side[0] == null:
			continue
		_add(side[0], "AD", feet.contact_point, feet.debug_drive_impulse * side[1] / delta, 2)
		_add(side[0], "jump", feet.contact_point, feet.debug_jump_impulse * side[1] / delta, 3)
		active[side[0]] = active.get(side[0], Vector2.ZERO) + (feet.debug_drive_impulse + feet.debug_jump_impulse) * side[1]
	for body in main.world.bodies:
		if body.is_static or body.frozen or not momentum.has(body):
			continue
		var gravity: Vector2 = main.world.gravity * body.mass * body.gravity_scale
		_add(body, "gravity", body.com_world(), gravity, 4)
		if not body.awake:
			continue
		var residual: Vector2 = (body.linear_velocity * body.mass - momentum[body]
			- active.get(body, Vector2.ZERO) - known_impulses.get(body, Vector2.ZERO) - contact_impulses.get(body, Vector2.ZERO)) / delta - gravity
		_add(body, "constraint/residual", body.com_world(), residual, 7)
	queue_redraw()
	if profile_enabled:
		_profile.finish_us = _profile.get("finish_us", 0) + Time.get_ticks_usec() - profile_start

func _add(body, title: String, point: Vector2, force: Vector2, color: int) -> void:
	if not indices.has(body):
		indices[body] = {}
	if indices[body].has(title):
		arrows[indices[body][title]].force += force
		return
	indices[body][title] = arrows.size()
	arrows.append({"body": body, "title": title, "point": point, "force": force, "color": color})
#endregion

#region 屏幕绘制
func _draw() -> void:
	if not enabled:
		return
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var font: Font = ThemeDB.fallback_font
	draw_string(font, Vector2(12, 20), "Tab 调试 | 青 P / 橙 D / 绿 AD / 黄 跳跃", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.DARK_SLATE_GRAY)
	draw_string(font, Vector2(12, 36), "灰 重力 / 蓝 支撑 / 紫 摩擦 / 红 约束余项", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.DARK_SLATE_GRAY)
	draw_string(font, Vector2(12, 52), "亮蓝 蓝墨推力 / 金 弹力~（模型估算）", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.DARK_SLATE_GRAY)
	# 两个 CanvasItem 的变换相除，抵消全屏拉伸；否则箭头会被再次放大到屏幕外。
	var transform: Transform2D = get_global_transform_with_canvas().affine_inverse() * main.get_global_transform_with_canvas()
	var row: int = 0
	var ordered: Array = arrows.duplicate()
	ordered.sort_custom(func(a, b): return int(a.color < 8) < int(b.color < 8))
	for arrow in ordered:
		var force: Vector2 = arrow.force
		if force.length() < 100.0 and arrow.color != 8:
			continue
		var start: Vector2 = transform * arrow.point
		var offset: Vector2 = (transform.basis_xform(force) * force_scale).limit_length(180.0)
		var end: Vector2 = start + offset
		var color: Color = COLORS[arrow.color]
		draw_line(start, end, color, 2.0, true)
		var direction: Vector2 = offset.normalized()
		draw_line(end, end - direction.rotated(0.5) * 7.0, color, 2.0, true)
		draw_line(end, end - direction.rotated(-0.5) * 7.0, color, 2.0, true)
		# 数值放左侧逐行排列；小力的箭头接近重叠时文字仍可读。
		var text_position: Vector2 = Vector2(12, 72 + row * 15)
		if text_position.y < get_viewport_rect().size.y - 12:
			var text := "body %d | %s (%+.2f, %+.2f) M" % [arrow.body.id, arrow.title, force.x / 1e6, force.y / 1e6]
			if arrow.has("power"):
				text += " | P %.1f MW" % (arrow.power / 1e6)
			draw_string(font, text_position, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)
		row += 1
	if profile_enabled:
		_profile.draw_us = _profile.get("draw_us", 0) + Time.get_ticks_usec() - profile_start


func set_profile_enabled(value: bool) -> void:
	profile_enabled = value
	_profile.clear()


func take_profile() -> Dictionary:
	var result: Dictionary = _profile.duplicate()
	_profile.clear()
	return result
#endregion
