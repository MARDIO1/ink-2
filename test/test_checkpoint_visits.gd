extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, okay: bool) -> void:
	print("[CheckpointVisits] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1

func _move(body, center: Vector2) -> void:
	body.position = center - body.local_com.rotated(body.rotation)
	body.refresh_com()
	body.update_aabb()

func _run() -> void:
	var level = load("res://map/asset/imported/main.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	current_scene = level
	var creative = level.get_node("Creative")
	creative.auto_save_on_exit = false
	creative.auto_save_edits = false
	var player = level.get_node("Player")
	var recovery = player.get_node("FallDeath")
	var body = player.body
	var spawn := Marker2D.new()
	spawn.name = "PlayerSpawn"
	spawn.position = Vector2(-10000, -10000)
	level.add_child(spawn)
	var visited := Marker2D.new()
	visited.name = "RespawnPointVisitTest"
	visited.position = Vector2(10000, -10000)
	level.add_child(visited)
	var future := Marker2D.new()
	future.name = "RespawnPointFutureTest"
	future.position = Vector2(12000, -10000)
	level.add_child(future)
	recovery._checkpoints_initialized = false
	_move(body, visited.position + Vector2(100.1, 0))
	recovery._update_visited_points()
	_check("outside horizontal 100px half extent stays locked", not recovery._visited_points.has(visited))
	_move(body, visited.position + Vector2(0, 100.1))
	recovery._update_visited_points()
	_check("outside vertical 100px half extent stays locked", not recovery._visited_points.has(visited))
	_move(body, visited.position + Vector2(99, 99))
	recovery._update_visited_points()
	_check("inside 200x200 square unlocks checkpoint", recovery._visited_points.has(visited))
	_move(body, future.position + Vector2(101, 0))
	_check("nearest unvisited checkpoint cannot be respawn target", recovery._find_respawn_target() == visited)
	creative.active = true
	_move(body, future.position)
	recovery._update_visited_points()
	_check("editor movement does not unlock checkpoint", not recovery._visited_points.has(future))
	creative.active = false
	recovery._dead = true
	recovery._respawn()
	_check("movement while dead does not unlock future checkpoint", not recovery._visited_points.has(future) and body.position.is_equal_approx(visited.position))
	level.position = Vector2(300, 160)
	level.rotation = 0.3
	_move(body, future.position + Vector2(99, 99))
	recovery._update_visited_points()
	_check("visit bounds use level coordinates even when transformed", recovery._visited_points.has(future))
	recovery._respawn()
	_check("ordinary respawn uses visited checkpoint", body.position.is_equal_approx(future.position))
	future.queue_free()
	_check("queued checkpoint is excluded immediately", recovery._find_respawn_target() == visited)
	visited.free()
	_check("deleted checkpoints fall back to level spawn", recovery._find_respawn_target() == spawn)
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
