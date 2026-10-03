#先搞最简单的版本，暂时没有抽象出接口出来，就是AD 空格直接控制
#我希望模块化一点，不是一堆参数在代码一起，是应函数名字上面放己的参数
#region 依赖
extends Node
const Query := preload("res://addons/pixel_destruction/physics/query.gd")
@onready var body = get_parent().get("body")
#endregion

#region 移动
## 加速度
@export var move_accel := 1300.0
## 最大速度
@export var max_speed := 210.0
## 执行移动
func _apply_move(body, dt: float) -> void:
	## 一个输入映射轴
	var axis := Input.get_axis("move_left", "move_right")
	var target_speed := axis * max_speed
	var dv: float = target_speed - body.linear_velocity.x
	var accel := clampf(dv / dt, -move_accel, move_accel)
	body.add_force(Vector2(accel * body.mass, 0.0))
#endregion


#region 跳跃
##起跳初速度，后续换算为冲量
@export var jump_speed := 400.0

func _apply_jump(body) -> void:
	if not Input.is_action_just_pressed("jump"):
		return
	if not _is_grounded(body):
		return
	body.apply_central_impulse(
		Vector2.UP * jump_speed * body.mass
	)
#endregion


#region 地面检测
@export var ground_probe := 4.0
func _is_grounded(body) -> bool:
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
	#代码规范，控制器必须为一级子节点
	var body = get_parent().get("body")
	
	body.clear_forces()
	body.awake = true
	body.sleep_timer = 0.0

	_apply_move(body, dt)
	_apply_jump(body)
#endregion
