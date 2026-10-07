#创造模式（= 地图编辑模式）：F2 进/出。
#进去后本体没有碰撞、没有重力，WASD 直接改位置（上帝手感，不走惯性）；
#数字键 1/2/3/4 切画布工具；F5 先把画布固化，再把世界里的墨水物品导出成地图场景。

#region 依赖
extends Node

const MapExport := preload("res://map/src/map_export.gd")

@export var player_path: NodePath = ^"../Player"
## 普通模式的小画布；创造模式里让位给大地图。
@export var canvas_path: NodePath = ^"../Canvas"
## 创造模式的大画布（铺满全图）；平时隐藏。
@export var map_canvas_path: NodePath = ^"../MapCanvas"
@export_file("*.tscn") var map_path: String = "res://map/asset/map.tscn"
## 上帝位移速度，单位 px/s。
@export var fly_speed := 600.0
## 按住 Shift 的倍率。
@export var fast_multiplier := 3.0
#endregion


#region 状态
var active := false
var _player = null
var _body = null
var _canvas = null
var _map_canvas = null
var _saved_layer := 1
var _saved_mask := 0xFFFFFFFF
var _saved_gravity := 1.0
#endregion


#region 生命周期
func _ready() -> void:
	process_physics_priority = 15      # 世界步进(10)之后、相机(20)之前
	set_physics_process(false)
	_player = get_node_or_null(player_path)
	_canvas = get_node_or_null(canvas_path)
	_map_canvas = get_node_or_null(map_canvas_path)
	if _map_canvas != null:
		_map_canvas.dev_save_enabled = false   # 大地图的 F5 只走导出
	_show_canvas(_map_canvas, false)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("creative"):
		toggle()
	elif active and event.is_action_pressed("canvas_save"):
		export_map()
#endregion


#region 开关
func toggle() -> void:
	set_active(not active)


func set_active(value: bool) -> void:
	if value == active:
		return
	active = value
	if active:
		_enter()
	else:
		_exit()


func _enter() -> void:
	if _player == null:
		push_error("Creative: 找不到 Player")
		return
	_body = _player.get("body")
	if _body == null:
		push_error("Creative: Player 还没烘焙出 body")
		return
	_saved_layer = _body.collision_layer
	_saved_mask = _body.collision_mask
	_saved_gravity = _body.gravity_scale
	_body.collision_layer = 0          # 不在任何层：碰不到任何东西
	_body.collision_mask = 0
	_body.gravity_scale = 0.0
	_body.linear_velocity = Vector2.ZERO
	_body.angular_velocity = 0.0
	var canvas := get_node_or_null(canvas_path)
	_show_canvas(_canvas, false)
	_show_canvas(_map_canvas, true)
	_set_ink_free(true)
	if _player != null:
		var health = _player.get_node_or_null("InkHealth")
		if health != null:
			health.damage_enabled = false   # 创造模式不许掉血
	set_physics_process(true)
	print("CREATIVE on")


func _exit() -> void:
	set_physics_process(false)
	if _body != null:
		_body.collision_layer = _saved_layer
		_body.collision_mask = _saved_mask
		_body.gravity_scale = _saved_gravity
		_body.linear_velocity = Vector2.ZERO
		_body.angular_velocity = 0.0
		_body.awake = true
		_body.sleep_timer = 0.0
	_show_canvas(_map_canvas, false)
	_show_canvas(_canvas, true)
	_set_ink_free(false)
	if _player != null:
		var health = _player.get_node_or_null("InkHealth")
		if health != null:
			health.damage_enabled = true
	print("CREATIVE off")


#切换哪块画布在工作：可见 + 收不收输入。
func _show_canvas(canvas, on: bool) -> void:
	if canvas == null:
		return
	canvas.visible = on
	canvas.active = on


#创造模式画图不花墨水：两张画布都免账，免得切回去时账目错位。
func _set_ink_free(free: bool) -> void:
	for canvas in [_canvas, _map_canvas]:
		if canvas != null:
			canvas.set_ink_free(free)
#endregion


#region 上帝位移
func _physics_process(delta: float) -> void:
	if _body == null:
		return
	var direction := Input.get_vector("fly_left", "fly_right", "fly_up", "fly_down")
	if direction != Vector2.ZERO and Input.is_key_pressed(KEY_SHIFT):
		direction *= fast_multiplier
	#⚠️ 直接**设速度**而不是瞬移位置。起步/停止仍然是瞬时的（没有惯性手感），
	#   但位移交给物理积分 —— 挂在本体上的手臂关节才有连续的锚点可跟。
	#   瞬移会把锚点一下子拉开，求解器为了追上会把轻手臂抽到几万 px/s（实测 331 子步/帧）。
	_body.linear_velocity = direction * fly_speed
	_body.angular_velocity = 0.0
	_body.awake = true
	_body.sleep_timer = 0.0
#endregion


#region 导出地图
## 先把画布上剩的墨水固化掉，再把世界里所有墨水物品打包成地图场景。
func export_map() -> void:
	if _map_canvas == null:
		push_error("Creative: 找不到 MapCanvas")
		return
	_map_canvas.generate()
	var result: Dictionary = MapExport.build(get_tree(), map_path)
	if result["saved"]:
		print("MAP saved: %s  ink=%d" % [ProjectSettings.globalize_path(map_path), result["count"]])
	else:
		push_error("Map save failed: %s (%d)" % [map_path, result["error"]])
#endregion
