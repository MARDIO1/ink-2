extends SceneTree
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Search := preload("res://actor/player/src/safe_spawn_search.gd")
var failures := 0
var level: Node

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, ok: bool) -> void:
	print("[SafeSpawn] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _block(position: Vector2, size: Vector2i, fixed := true):
	var body := PBody.new()
	body.position = position
	var shape := Shape.new()
	shape.fill_rect(Rect2i(Vector2i.ZERO, size), 1)
	level.world.add_body(body, [shape], Callable(level, "_density_of"), fixed)
	return body

func _remove(body) -> void:
	level.world.remove_body(body)
	for shape in body.shapes:
		shape.owner_body = null
	body.shapes.clear()

func _run() -> void:
	level = load("res://map/main.tscn").instantiate()
	root.add_child(level)
	await process_frame
	paused = true
	var player: Node = level.get_node("Player")
	var recovery: Node = player.get_node("FallDeath")
	var hand: Node = player.get_node("Arm/Hand/HandControl")
	var bounds: Rect2 = player.body.rects[0]
	for rect in player.body.rects:
		bounds = bounds.merge(rect)
	var origin := Vector2(500, -500)
	var floor_body = _block(origin + Vector2(-300, ceilf(bounds.end.y) + 2), Vector2i(700, 16))
	var target := {"position": origin, "rotation": 0.0}
	var search := Search.new()
	search.setup(recovery, level.world, player.body, hand)
	var clear: Dictionary = await search.find([target])
	_check("clear point selected exactly", not clear.is_empty() and clear.position == origin)
	var obstacle = _block(origin + bounds.position - Vector2(3, 3), Vector2i(bounds.size) + Vector2i(6, 6), false)
	var obstacle_position: Vector2 = obstacle.position
	var pixels: int = obstacle.shapes[0].pixel_count()
	search = Search.new()
	search.setup(recovery, level.world, player.body, hand)
	var shifted: Dictionary = await search.find([target])
	_check("blocked point finds nearby safe position", not shifted.is_empty() and shifted.position != origin)
	_check("actual player and hand clear obstacles", not shifted.is_empty() and await search.verify(shifted.position, shifted.rotation))
	_check("items neither moved nor deleted", obstacle.position == obstacle_position and obstacle.shapes[0].pixel_count() == pixels)
	_check("search bounded", search.candidates_checked <= Search.MAX_CANDIDATES and search.pairs_checked <= Search.MAX_PAIRS + 1)
	_remove(obstacle)
	var wall = _block(origin + Vector2(-250, -250), Vector2i(600, 600))
	search = Search.new()
	search.setup(recovery, level.world, player.body, hand)
	_check("fully blocked area rejected", (await search.find([target])).is_empty())
	var second_origin := Vector2(1800, -500)
	var second_floor = _block(second_origin + Vector2(-300, ceilf(bounds.end.y) + 2), Vector2i(700, 16))
	search = Search.new()
	search.setup(recovery, level.world, player.body, hand)
	var fallback: Dictionary = await search.find([target, {"position": second_origin, "rotation": 0.0}])
	_check("blocked checkpoint falls back to next visited target", not fallback.is_empty() and fallback.position == second_origin)
	_remove(wall)
	_remove(floor_body)
	_remove(second_floor)
	search = Search.new()
	search.setup(recovery, level.world, player.body, hand)
	_check("unsupported empty space rejected", (await search.find([target])).is_empty())
	# ESC 失败不移动玩家，并保持暂停和错误提示。
	var ui: Node = load("res://ui/game_ui.tscn").instantiate()
	root.add_child(ui)
	var marker := Marker2D.new()
	marker.position = origin
	level.add_child(marker)
	recovery._visited_points.clear()
	recovery._visited_points.append(marker)
	recovery._checkpoints_initialized = true
	recovery._body = player.body
	var previous: Vector2 = player.body.position
	var esc: Node = get_first_node_in_group(&"esc_menu")
	esc.open_menu()
	var escaped: bool = await esc._on_escape_stuck_button_pressed()
	_check("failed recovery stays paused with message", not escaped and paused and esc.visible and esc._recovery_status.visible)
	_check("failed search leaves player untouched", player.body.position == previous)
	_check("failure releases button lock", not esc._recovery_busy and not esc.continue_button.disabled)
	# 恢复游玩前突然有物品进入已选落点，首个真实物理步应自动重新搜索。
	_block(origin + Vector2(-300, ceilf(bounds.end.y) + 2), Vector2i(700, 16))
	_check("safe recovery succeeds", await esc._on_escape_stuck_button_pressed())
	var chosen: Vector2 = player.body.position
	var intruder = _block(chosen + bounds.position - Vector2(3, 3), Vector2i(bounds.size) + Vector2i(6, 6))
	await physics_frame
	await process_frame
	for i in 120:
		if not recovery.recovering and recovery._pending_safety_check.is_empty() and not esc._recovery_busy:
			break
		await process_frame
	_check("post-physics obstruction automatically relocates", not paused and player.body.position.distance_to(chosen) > 1.0)
	_check("late intruder not deleted", level.world.bodies.has(intruder))
	paused = true
	for i in 200:
		_block(origin + Vector2(-50 + (i % 10) * 7, -80 + (i / 10) * 4), Vector2i(4, 4), false)
	search = Search.new()
	search.setup(recovery, level.world, player.body, hand)
	var clutter_result: Dictionary = await search.find([target])
	_check("clutter search respects bounded work", search.candidates_checked <= Search.MAX_CANDIDATES and search.pairs_checked <= Search.MAX_PAIRS + 1)
	_check("clutter search yields to UI", search.frames_yielded > 0)
	print("[SafeSpawn] 200 fragments: candidates=", search.candidates_checked, " rect-pairs=", search.pairs_checked, " yielded-frames=", search.frames_yielded, " safe=", not clutter_result.is_empty())
	esc._on_continue_button_pressed()
	ui.queue_free()
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
