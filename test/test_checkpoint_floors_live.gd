extends SceneTree

const LayoutTools := preload("res://debug/creative/features/layout_tools.gd")
const Body := preload("res://addons/pixel_destruction/physics/pbody.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, condition: bool) -> void:
	print("[CheckpointFloors] ", label, ": ", "PASS" if condition else "FAIL")
	if not condition:
		failures += 1

func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	for obstacle in ["Box", "Gym"]:
		level.get_node(obstacle).free()
	level.get_node("Ground").position = Vector2(-800, 0)
	level.get_node("Ground/Shape").rect_size = Vector2i(1600, 30)
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	root.add_child(level)
	current_scene = level
	level.get_node("SimulationRuntime/PhysicsStep").freeze_view_scale = 32.0
	level.get_node("debugHUD").process_mode = Node.PROCESS_MODE_DISABLED
	var player = level.get_node("Player")
	player.get_node("InkHealth").damage_enabled = false
	var recovery = player.get_node("FallDeath")
	var foot: Vector2 = recovery._spawn_foot_offset()
	var lower := LayoutTools.create_respawn_point(level, -foot)
	var upper := LayoutTools.create_respawn_point(level, -foot + Vector2(0,-180))
	var platform := Body.new()
	platform.make_static()
	platform.position = Vector2(-120,-180)
	var shape := Shape.new()
	shape.fill_rect(Rect2i(0,0,240,12),1)
	level.world.add_body(platform,[shape],Callable(level,"_density_of"),true)
	level.realign_body_nodes()
	recovery._checkpoints_initialized = false
	player.teleport_to(lower.position - Vector2(0,2),0)
	for frame in 60:
		await physics_frame
	_check("real lower-floor contact activates only lower point", player.get_node("PlayerInput").support != null and recovery._find_respawn_target() == lower and not recovery._visited_points.has(upper))
	player.teleport_to(upper.position - Vector2(0,2),0)
	for frame in 60:
		await physics_frame
	_check("real upper-floor landing activates upper point", recovery._find_respawn_target() == upper)
	player.teleport_to(lower.position + Vector2(180,-2),0)
	for frame in 60:
		await physics_frame
	_check("moving close to an old floor does not change respawn", recovery._find_respawn_target() == upper)
	recovery._dead = true
	recovery._respawn()
	_check("death returns to last activated upper floor", player.body.position.distance_to(upper.position) < 0.01)
	player.teleport_to(lower.position - Vector2(0,2),0)
	for frame in 60:
		await physics_frame
	_check("backtracking and landing reactivates lower floor", recovery._find_respawn_target() == lower)
	level.world.remove_body(platform)
	shape.owner_body = null
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
