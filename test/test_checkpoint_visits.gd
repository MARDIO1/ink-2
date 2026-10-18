extends SceneTree

const RespawnPoint := preload("res://map/src/respawn_point.gd")
var failures := 0
var recovery: Node
var player_input: Node
var body
var support
var notices := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, okay: bool) -> void:
	print("[CheckpointVisits] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1

## 注入物理控制器已结算的真实接触接口，单独验证复活点策略。
func _foot(position: Vector2, grounded := true) -> void:
	body.position = position - recovery._spawn_foot_offset()
	body.refresh_com()
	body.update_aabb()
	player_input.support = support if grounded else null
	player_input.contact_point = position
	recovery._update_visited_points()

func _visit(point: Marker2D, grounded := true, offset := Vector2.ZERO) -> void:
	_foot(point.position + recovery._spawn_foot_offset() + offset, grounded)

func _point(level: Node, name: String, position: Vector2) -> Marker2D:
	var point := RespawnPoint.new()
	point.name = name
	point.position = position
	level.add_child(point)
	point.owner = level
	return point

func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	current_scene = level
	level.process_mode = Node.PROCESS_MODE_DISABLED
	var creative = level.get_node("Creative")
	creative.auto_save_on_exit = false
	creative.auto_save_edits = false
	var player = level.get_node("Player")
	recovery = player.get_node("FallDeath")
	player_input = player.get_node("PlayerInput")
	body = player.body
	support = level.get_node("Ground").body
	var spawn := Marker2D.new()
	spawn.name = "PlayerSpawn"
	spawn.position = Vector2(-10000, -10000)
	level.add_child(spawn)
	var lower := _point(level, "RespawnPointLower", Vector2(10000, -10000))
	var upper := _point(level, "RespawnPointUpper", lower.position - Vector2(0, 80))
	var future := _point(level, "RespawnPointFuture", Vector2(12000, -10000))
	recovery._checkpoints_initialized = false
	recovery.checkpoint_activated.connect(func(_point): notices += 1)
	_check("spawn is initial fallback", recovery._find_respawn_target() == spawn)
	_visit(lower, false)
	_check("airborne crossing does not activate", not recovery._visited_points.has(lower))
	_visit(lower, true, Vector2(60.1, 0))
	_check("outside horizontal strip does not activate", not recovery._visited_points.has(lower))
	_visit(lower, true, Vector2(0, 16.1))
	_check("outside vertical strip does not activate", not recovery._visited_points.has(lower))
	_visit(lower)
	_check("grounded feet activate lower floor only", recovery._find_respawn_target() == lower and not recovery._visited_points.has(upper))
	_check("activation shows feedback once", notices == 1 and recovery._checkpoint_notice.visible)
	_visit(lower)
	_check("standing inside does not retrigger", notices == 1)
	_visit(future)
	_visit(lower, true, Vector2(61, 0))
	_check("nearest old point cannot replace last activation", recovery._find_respawn_target() == future)
	# 查找目标本身不能变成触发入口。
	body.position = upper.position
	body.refresh_com()
	_check("query does not activate a new point", recovery._find_respawn_target() == future and not recovery._visited_points.has(upper))
	_visit(lower)
	_check("backtracking reactivates previously visited point", recovery._find_respawn_target() == lower and notices == 3)
	_visit(upper, false)
	_check("falling past another floor keeps active point", recovery._find_respawn_target() == lower)
	creative.active = true
	_visit(future)
	_check("editor movement cannot switch active point", recovery._find_respawn_target() == lower)
	creative.active = false
	recovery._dead = true
	_visit(upper)
	recovery._respawn()
	_check("death cannot activate point and respawns at last activation", body.position.is_equal_approx(lower.position) and not recovery._visited_points.has(upper))
	# 偏移后的区域独立于出生标记；变换后的关卡仍按本关物理坐标判断。
	future.activation_size = Vector2(40, 12)
	future.activation_offset = Vector2(45, -12)
	level.position = Vector2(300, 160)
	level.rotation = 0.3
	_visit(future)
	_check("custom offset excludes unshifted feet", recovery._find_respawn_target() == lower)
	_visit(future, true, future.activation_offset)
	_check("custom zone works in transformed level", recovery._find_respawn_target() == future)
	var packed := PackedScene.new()
	packed.pack(future)
	var restored = packed.instantiate()
	_check("size and offset persist in scene", restored.activation_size == future.activation_size and restored.activation_offset == future.activation_offset)
	restored.free()
	recovery._dead = true
	recovery._respawn()
	_check("respawn uses marker, not activation offset", body.position.is_equal_approx(future.position))
	future.queue_free()
	_check("queued active point falls back by activation history", recovery._find_respawn_target() == lower)
	lower.free()
	_check("deleted history falls back to spawn", recovery._find_respawn_target() == spawn)
	var legacy := Marker2D.new()
	legacy.name = "RespawnPointLegacy"
	legacy.position = Vector2(14000,-10000)
	level.add_child(legacy)
	recovery._checkpoints_initialized = false
	_visit(legacy)
	_check("legacy bare markers use grounded default strip", recovery._find_respawn_target() == legacy and legacy.get_script() == null)
	var overlap_a := _point(level,"RespawnPointOverlapA",Vector2(16000,-10000))
	var overlap_b := _point(level,"RespawnPointOverlapB",Vector2(16060,-10000))
	recovery._checkpoints_initialized = false
	_visit(overlap_a,true,Vector2(-40,0))
	_check("non-overlap side activates first zone", recovery._find_respawn_target() == overlap_a)
	_visit(overlap_a,true,Vector2(20,0))
	_check("entering overlapping second zone switches once", recovery._find_respawn_target() == overlap_b)
	var before_notice := notices
	_visit(overlap_a,true,Vector2(25,0))
	_check("remaining in overlap cannot oscillate", recovery._find_respawn_target() == overlap_b and notices == before_notice)
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
