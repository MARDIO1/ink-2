extends SceneTree

const Query := preload("res://addons/pixel_destruction/physics/query.gd")
const PWorld := preload("res://addons/pixel_destruction/physics/pworld.gd")
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, ok: bool) -> void:
	print("[PortalGrip] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _run() -> void:
	var app: Node = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	current_scene = app
	root.get_node("SceneTransition").duration = 0.01
	for path in ["res://map/asset/imported/扉页（教程关）.tscn", "res://map/asset/imported/第一关.tscn", "res://map/asset/imported/扉页（教程关）.tscn", "res://map/asset/imported/第一关.tscn"]:
		await app.request_level_change(path)
		await process_frame
		await process_frame
		var level: Node = app.level_root.get_child(0)
		var hand: Node = level.get_node("Player/Arm/Hand/HandControl")
		_check(path.get_file() + " hand enabled", hand.enabled and hand.is_physics_processing())
		_check(path.get_file() + " query belongs to live world", is_same(Query._bodies, level.world.bodies))
		var target = null
		for candidate in level.world.bodies:
			if candidate != hand.body and candidate != hand.player_body and candidate != hand.arm_body and not candidate.shapes.is_empty():
				target = candidate
				break
		_check("target exists", target != null)
		if target != null:
			var hit = Query.closest_point_on_shape(target.shapes[0], target.com_world())
			hand._remove_arm()
			hand.body.rotation = 0.0
			hand.body.position = hit.point - hand.FINGERTIP - hand.body.local_com
			hand.body.refresh_com()
			hand.body.update_aabb()
			hand.set_grip(true)
			hand._update_grip(0.0)
			_check("finger actually grabs current map", hand.grabbed_body != null and level.world.bodies.has(hand.grabbed_body))
			hand.set_grip(false)
			hand._release_grab()
			# 辅助世界和全局过滤器不应干扰当前玩家；旧世界释放不应撤销新注册。
			var auxiliary = PWorld.new()
			Query.require(0)
			hand.body.rotation = 0.0
			hand.body.position = hit.point - hand.FINGERTIP - hand.body.local_com
			hand.body.refresh_com()
			hand.body.update_aabb()
			hand.set_grip(true)
			hand._update_grip(0.0)
			_check("grip isolated from other worlds and filters", hand.grabbed_body != null and level.world.bodies.has(hand.grabbed_body))
			Query.attach(level.world)
			Query.require(1)
			auxiliary = null
			_check("old world cleanup preserves new registry and filters", is_same(Query._bodies, level.world.bodies) and Query._require_mask == 1)
			Query.clear_filters()
			hand.set_grip(false)
			hand._release_grab()
	app.queue_free()
	await process_frame
	quit(1 if failures else 0)
