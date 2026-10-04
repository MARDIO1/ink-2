#AD 移动、空格跳跃；对玩家质心施加单帧冲量。

#region 依赖
extends Node
const Query := preload("res://addons/pixel_destruction/physics/query.gd")
#body 不能 @onready 拿：PixelWorld 在 Main._ready 里烘焙，比本节点 _ready 晚，运行时才拿得到
var body = null
#endregion

#region 初始化
func _ready() -> void:
	# 先处理移动，再由 Hand 施加内冲量，最后交给世界求解。
	process_priority = -30
#endregion


#region 移动
## 加速度
@export var move_accel := 1300.0
## 最大速度
@export var max_speed := 210.0

## 执行移动
func _apply_move(dt: float) -> void:
	## 一个输入映射轴
	var axis := Input.get_axis("move_left", "move_right")
	var target_speed := axis * max_speed
	var dv: float = target_speed - body.linear_velocity.x
	var accel := clampf(dv / dt, -move_accel, move_accel)
	# 单帧积分，不向刚体的持久力累加器写入。
	body.apply_central_impulse(Vector2(accel * body.mass * dt, 0.0))
#endregion


#region 跳跃
##起跳初速度，后续换算为冲量
@export var jump_speed := 400.0

func _apply_jump() -> void:
	if not Input.is_action_just_pressed("jump"):
		return
	if not _is_grounded():
		return
	body.apply_central_impulse(
		Vector2.UP * jump_speed * body.mass
	)
#endregion


#region 地面检测
@export var ground_probe := 4.0

func _is_grounded() -> bool:
	var box: Rect2 = body.aabb
	var start := Vector2(box.get_center().x, box.end.y + 1.0)
	var hit = Query.raycast(
		start,
		Vector2.DOWN,
		ground_probe,
		0.0,
		[body]
	)
	return hit.hit and hit.normal.y < -0.5
#endregion


#region 物理帧主过程
func _physics_process(dt: float) -> void:
	#控制器为刚体的一级子节点；世界烘焙后才能取得 body。
	if body == null:
		body = get_parent().get("body")
	if body == null:
		return

	body.awake = true
	body.sleep_timer = 0.0

	_apply_move(dt)
	_apply_jump()
#endregion
