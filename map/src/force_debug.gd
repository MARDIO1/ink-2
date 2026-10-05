extends Node2D
## HUD 上的力观察器：接触冲量按固定步累加；关节合力用动量差扣除已知力得到。
## 引擎未暴露逐关节矢量，余项不冒充某一个关节的精确反力。F3 开关。
@export var enabled: bool = true
@export var force_scale: float = 0.000015
@onready var main = $"../.."
@onready var hand = $"../../Player/Arm/Hand/HandControl"
@onready var feet = $"../../Player/PlayerInput"
var arrows: Array = []
var momentum: Dictionary = {}
var contact_impulses: Dictionary = {}
var indices: Dictionary = {}
var support = null
var step_time: float = 0.0
const COLORS: Array[Color] = [Color.CYAN, Color.ORANGE, Color.LIME_GREEN, Color.YELLOW, Color.GRAY, Color.CORNFLOWER_BLUE, Color.MAGENTA, Color.RED]

#region 固定步采样
func _ready() -> void:
	process_physics_priority = -40

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		enabled = not enabled
		queue_redraw()

func _physics_process(_delta: float) -> void:
	if not enabled:
		return
	arrows.clear()
	momentum.clear()
	contact_impulses.clear()
	indices.clear()
	step_time = 0.0
	support = feet.support
	for body in main.world.bodies:
		momentum[body] = body.linear_velocity * body.mass

func sample_contacts(contacts: Array, delta: float) -> void:
	if not enabled:
		return
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

func finish(delta: float) -> void:
	if not enabled or step_time <= 0.0:
		return
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
		if body.is_static or not momentum.has(body):
			continue
		var gravity: Vector2 = main.world.gravity * body.mass * body.gravity_scale
		_add(body, "gravity", body.com_world(), gravity, 4)
		if not body.awake:
			continue
		var residual: Vector2 = (body.linear_velocity * body.mass - momentum[body]
			- active.get(body, Vector2.ZERO) - contact_impulses.get(body, Vector2.ZERO)) / delta - gravity
		_add(body, "constraint/residual", body.com_world(), residual, 7)
	queue_redraw()

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
	var font: Font = ThemeDB.fallback_font
	draw_string(font, Vector2(12, 20), "F3 力矢量 | 青 P / 橙 D / 绿 AD / 黄 跳跃", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.DARK_SLATE_GRAY)
	draw_string(font, Vector2(12, 36), "灰 重力 / 蓝 支撑 / 紫 摩擦 / 红 约束余项", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.DARK_SLATE_GRAY)
	# 两个 CanvasItem 的变换相除，抵消全屏拉伸；否则箭头会被再次放大到屏幕外。
	var transform: Transform2D = get_global_transform_with_canvas().affine_inverse() * main.get_global_transform_with_canvas()
	var row: int = 0
	for arrow in arrows:
		var force: Vector2 = arrow.force
		if force.length() < 100.0:
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
		var text_position: Vector2 = Vector2(12, 56 + row * 13)
		if text_position.y < get_viewport_rect().size.y - 12:
			draw_string(font, text_position, "body %d | %s (%+.2f, %+.2f) M" % [arrow.body.id, arrow.title, force.x / 1e6, force.y / 1e6], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, color)
		row += 1
#endregion
