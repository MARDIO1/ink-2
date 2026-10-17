extends "res://tools/build_ink_machine_pages.gd"

func _initialize() -> void:
	_check_pages.call_deferred()

func _frames(count: int) -> void:
	for frame in count:
		await physics_frame

func _join_wire(carrier: Node, a: Vector2, b: Vector2) -> void:
	_wire("TestConnection",carrier.body.position,[a,b])
	await _frames(2)

func _fuel(name_: String, at: Vector2) -> void:
	var fuel: Node=level.get_node(name_)
	fuel.body.position=at
	fuel.body.linear_velocity=Vector2.ZERO
	fuel.body.awake=true
	fuel.body.refresh_com()
	fuel.body.update_aabb()

func _check_pages() -> void:
	var app: Node=load("res://root/root.tscn").instantiate()
	root.add_child(app)
	current_scene=app
	root.get_node("SceneTransition").duration=0.02
	var failures:=0
	for title in PAGES:
		await app.request_level_change("res://map/asset/imported/"+title+".tscn")
		level=app.get_node("Level").get_child(0)
		level.get_node("Creative").auto_save_on_exit=false
		level.get_node("Creative").auto_save_edits=false
		await _frames(20)
		var expected_monsters := 2 if title=="第二页" else 1
		if level.get_node("Monsters").get_child_count() != expected_monsters: failures+=1
		# 机构测试隔离战斗破坏；攻击规则另由 test_monster_attacks.gd 覆盖。
		for monster in level.get_node("Monsters").get_children():
			monster.attacks_enabled=false
		var gate_y: float=level.get_node("GearGate").position.y
		var exit_node: Node=level.get_node("PageExit")
		exit_node._activate()
		if exit_node._pending: failures+=1
		var center: Vector2=level.get_node("DriverBearing").black_position
		level.get_node("Player").teleport_to(center+Vector2(-200,70),0)
		var support: Node=level.get_node("PowerSupport")
		await _join_wire(support,Vector2(16,150),Vector2(106,150))
		await _frames(240)
		var gear: Node=level.get_node("Transmission")
		print("[Machines] ",title," gear complete=",gear.completed," angle=",gear._rotation_total," power=",gear._powered," motor=",level.get_node_or_null("GearMotor"))
		for n in ["DriverGear","FollowerGear","GearFuel","PowerSupport"]:
			var node = level.get_node_or_null(n)
			if node != null: print(n," pos=",node.body.position," rot=",node.body.rotation," mass=",node.body.mass)
		for n in ["SupplyWireA","SupplyWireB","WheelWire","GearMotor"]:
			var node=level.get_node_or_null(n)
			if node != null: print(n," body=",node.body," pos=",node.position)
		print("motor used=",level.get_node("GearMotor").used_power," buffer=",level.get_node("GearMotor").energy_buffer)
		if not gear.completed: failures+=1
		if gear.completed and gate_y-level.get_node("GearGate").body.position.y < 70:
			print("[Machines] gate failed to rise")
			failures+=1
		if title=="第二页":
			var lever: Node=level.get_node("BalanceLever")
			level.get_node("Player").teleport_to(lever.position+Vector2(-40,-10),0)
			_fuel("BalanceWeight",lever.body.position+Vector2(30,-45))
			await _frames(240)
			print("[Machines] balance=",level.get_node("Balance").completed," angle=",lever.body.rotation," spring=",level.get_node_or_null("BalanceSpring"))
			if not level.get_node("Balance").completed: failures+=1
		else:
			var platform: Node=level.get_node("LiftPlatform")
			level.get_node("Player").teleport_to(platform.position+Vector2(100,75),0)
			await _join_wire(platform,Vector2(40,170),Vector2(141,170))
			await _frames(360)
			print("[Machines] lift=",level.get_node("Elevator").completed," height=",level.get_node("Elevator")._origin.y-platform.body.position.y," power=",level.get_node("Elevator")._powered)
			print("lift mass=",platform.body.mass," motor=",level.get_node_or_null("LiftMotor")," fuel=",level.get_node_or_null("LiftFuel"))
			if not level.get_node("Elevator").completed: failures+=1
	print("[Machines] failures=",failures)
	app.queue_free()
	await process_frame
	quit(1 if failures else 0)
