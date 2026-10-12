extends Resource
## Player 与 Gym 共用的唯一调参源；只保存现有 Gym 暴露的控制器标量。

@export_group("身体")
@export var body_density_scale := 1.0

@export_group("脚部")
@export var foot_max_force := 6000000.0
@export var foot_max_power := 16800000000.0
@export var foot_move_speed := 200.0
@export var foot_jump_impulse := 1800000.0
@export var foot_upright_stiffness := 500000000.0
@export var foot_upright_damping := 30000000.0
@export var foot_max_upright_torque := 600000000.0

@export_group("手部")
@export var hand_max_force := 16000000.0
@export var hand_max_power := 840000000.0
@export var hand_position_stiffness := 140.0
@export var hand_position_damping := 48.0
