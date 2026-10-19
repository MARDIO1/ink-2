extends Resource
## 各颜色运行规则的共享默认值；Gym 修改运行节点，保存时写回本资源。

@export_group("蓝墨")
@export var blue_force_per_length := 300000.0
@export var blue_power_per_width := 300000000.0
@export var blue_source_power_per_pixel := 300000000.0
@export var blue_idle_power := 10000000.0
@export var blue_energy_per_red_pixel := 600000000.0
@export var blue_fuel_interval := 0.1
@export var blue_fuel_contact_radius := 3
@export var blue_propagation_speed := 600.0
@export var blue_emission_interval := 0.2
@export var blue_motor_buffer_seconds := 0.8
@export var blue_motor_startup_delay := 0.1
@export var blue_motor_power_window := 0.2
@export var blue_motor_force_ramp := 0.15
@export var blue_opposition_recovery := 0.0
@export var blue_energy_lifetime := 20.0
@export var blue_short_falloff_exponent := 1.0
@export var blue_short_min_scale := 0.0
@export var blue_biological_default_power := 1000000000.0
@export var blue_biological_force_weight_ratio := 0.5

@export_group("黄墨")
@export var yellow_opacity := 0.75
@export var yellow_dash_length := 8.0
@export var yellow_dash_gap := 6.0
@export var yellow_stiffness_per_width := 5000.0
@export var yellow_damping_ratio := 0.0
@export var yellow_safe_force_per_width := 1000000.0
@export var yellow_wear_pixels_per_second := 15.0

@export_group("红墨")
@export var red_propagation_decay := 0.9
@export var red_impulse_per_pixel := 300000.0
@export var red_damage_multiplier := 0.05
@export var red_impulse_multiplier := 2.0
@export var red_blast_radius := 48.0
@export var red_ray_count := 32
@export var red_event_chunk_size := 64

@export_group("白墨")
@export var white_corrosion_pixels_per_second := 80.0
@export var white_corrosion_interval := 0.12
@export var white_corrosion_pixels_per_batch := 12
@export var white_corrosion_yield := 3.0
@export var white_player_damage_per_second := 20.0
@export var white_max_travel_from_spawn := 4096.0
