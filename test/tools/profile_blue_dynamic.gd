extends "res://test/test_blue_ink.gd"
## 动态蓝墨实测：真实关卡 + 两台电机。运行时内存插桩，不修改 addon 或正式脚本。
## -- before/after；输出 reports/blue_performance/<variant>.json（含 Chrome Trace spans）。

func run() -> void:
	var args := OS.get_cmdline_user_args()
	var variant := args[0] if not args.is_empty() else "after"
	scene = load("res://map/asset/imported/扉页.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	await process_frame
	canvas = scene.get_node("SmallCanvas")
	surface = canvas.surface
	runtime = scene.get_node("SimulationRuntime")
	var old = runtime.get_node("BlueInk")
	runtime.remove_child(old)
	old.free()
	var source := FileAccess.get_file_as_string("res://reports/blue_performance/before_source.txt" if variant == "before" else "res://ink/src/blue_ink.gd")
	var script := GDScript.new()
	script.source_code = instrument(source)
	if script.reload() != OK:
		quit(2)
		return
	rule = script.new()
	rule.name = "BlueInk"
	runtime.add_child(rule)
	runtime._discover_extensions()
	canvas.position = Vector2(5000, 5000)
	canvas.canvas_size = Vector2i(800, 180)
	surface.ink_free = true
	paint(Rect2i(20, 20, 700, 90), Color.BLACK)
	paint(Rect2i(10, 25, 10, 70), Palette.RED.color)
	surface.brush_size = 7
	for y in [35.5, 85.5]:
		surface.blue_layer.begin(Vector2(20.5, y))
		surface.blue_layer.extend(Vector2(700.5, y))
		surface.blue_layer.finish()
		rule.begin(surface, Vector2(650.5, y))
		rule.finish(surface, Vector2(700.5, y))
	canvas.generate(false)
	rule.energy_per_red_pixel = 1.0e15
	var carrier = rule.objects(Wire)[0].body
	carrier.is_static = true
	var probe := PBody.new()
	probe.position = canvas.position + Vector2(400, 70)
	var shape := Shape.new()
	shape.fill_rect(Rect2i(0, 0, 12, 12), Palette.BLACK.id)
	scene.world.add_body(probe, [shape])
	var results: Array = []
	for scenario in ["stationary", "nearby_motion", "living_motion", "irrelevant_fracture"]:
		var samples: Array[int] = []
		rule.trace_spans.clear()
		probe.tags.erase("living")
		if scenario == "living_motion":
			probe.tags["living"] = true
			probe.tags["supply_power"] = 100000000.0
			probe.position.y = canvas.position.y + 32.0
		for frame in 65:
			if frame == 5:
				rule.trace_spans.clear()
			if scenario in ["nearby_motion", "living_motion"]:
				probe.position.x += 0.05
				probe.refresh_com()
				probe.update_aabb()
			if scenario == "irrelevant_fracture":
				rule.observe_fracture(scene.world, probe, [probe])
			var start := Time.get_ticks_usec()
			rule.resolve_fixed(runtime._context())
			var elapsed := Time.get_ticks_usec() - start
			if frame >= 5:
				samples.append(elapsed)
			await process_frame
		samples.sort()
		results.append({"scenario": scenario, "samples_us": samples, "median_us": samples[30], "p95_us": samples[57], "max_us": samples[-1], "spans": rule.trace_spans.duplicate(true)})
		print("BLUE_DYNAMIC %s %s median_us=%d p95_us=%d max_us=%d" % [variant, scenario, samples[30], samples[57], samples[-1]])
	if "--full" in args:
		runtime.set_physics_process(false)
		scene.auto_step = true
		probe.tags["living"] = true
		probe.tags["supply_power"] = 100000000.0
		probe.is_static = true
		probe.collision_layer = 0
		probe.collision_mask = 0
		probe.position.y = canvas.position.y + 32.0
		rule.trace_move_body = probe
		for steps in [1, 4]:
			var samples: Array[int] = []
			var walls: Array[int] = []
			var scenario := "full_pipeline_%dsteps" % steps
			for frame in 35:
				if frame == 5:
					rule.trace_spans.clear()
				var start := Time.get_ticks_usec()
				rule.trace_stack.append(scenario)
				runtime._physics_process(scene.fixed_dt * steps)
				var elapsed := Time.get_ticks_usec() - start
				rule.trace_spans.append({"name": scenario, "ts": start, "dur": elapsed, "stack": rule.trace_stack.duplicate()})
				rule.trace_stack.pop_back()
				await process_frame
				if frame >= 5:
					samples.append(elapsed)
					walls.append(Time.get_ticks_usec() - start)
			walls.sort()
			samples.sort()
			results.append({"scenario": scenario, "samples_us": samples, "median_us": samples[15], "p95_us": samples[28], "max_us": samples[-1], "wall_median_us": walls[15], "spans": rule.trace_spans.duplicate(true)})
			print("BLUE_FRAME %s %s median_us=%d p95_us=%d wall_median_us=%d" % [variant, scenario, samples[15], samples[28], walls[15]])
	var chunks := 0
	for body in scene.world.bodies:
		for body_shape in body.shapes:
			chunks += body_shape.chunks.size()
	var wire_pixels := 0
	for wire in rule.objects(Wire):
		wire_pixels += wire.cells.size()
	var payload := {"variant": variant, "source_sha256": source.sha256_text(), "bodies": scene.world.bodies.size(), "world_chunks": chunks, "wire_pixels": wire_pixels, "results": results}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://reports/blue_performance"))
	var file := FileAccess.open("res://reports/blue_performance/%s.json" % variant, FileAccess.WRITE)
	file.store_string(JSON.stringify(payload))
	file.close()
	scene.queue_free()
	await process_frame
	quit(0)

func instrument(source: String) -> String:
	var methods := {
		"resolve_fixed": ["context: Dictionary", "context", "Dictionary"],
		"_build_graph": ["", "", "void"],
		"_topology_stamp": ["physics, motors: Array", "physics, motors", "Array"],
		"_refresh_sources": ["physics", "physics", "void"],
		"_rebuild_circuit": ["physics, motors: Array", "physics, motors", "void"],
		"_contact_graph": ["physics", "physics", "Dictionary"],
		"_source_contact": ["wire, body", "wire, body", "Dictionary"],
		"_motor_ports": ["motor", "motor", "Array"],
		"widest_tree": ["links: Array, roots: Dictionary", "links, roots", "Dictionary"],
		"consume_fuel": ["physics", "physics", "Dictionary"],
		"observe_fracture": ["physics, body, pieces: Array", "physics, body, pieces", "void"],
		"drive": ["motor, available: float, delta: float", "motor, available, delta", "float"]}
	var wrappers := "\nvar trace_spans: Array = []\nvar trace_stack: Array = []\nvar trace_move_body = null\n"
	for name in methods:
		if not source.contains("func " + name + "("):
			continue
		var spec: Array = methods[name]
		source = source.replace("func " + name + "(", "func __measured" + name + "(")
		wrappers += "\nfunc %s(%s) -> %s:\n" % [name, spec[0], spec[2]]
		wrappers += "\tvar started := Time.get_ticks_usec()\n\ttrace_stack.append(\"%s\")\n" % name
		if name == "resolve_fixed":
			wrappers += "\tif trace_move_body != null:\n\t\ttrace_move_body.position.x += 0.05\n\t\ttrace_move_body.refresh_com()\n\t\ttrace_move_body.update_aabb()\n"
		wrappers += ("\t" if spec[2] == "void" else "\tvar result = ") + "__measured%s(%s)\n" % [name, spec[1]]
		wrappers += "\ttrace_spans.append({\"name\": \"%s\", \"ts\": started, \"dur\": Time.get_ticks_usec() - started, \"stack\": trace_stack.duplicate()})\n\ttrace_stack.pop_back()\n" % name
		if spec[2] != "void":
			wrappers += "\treturn result\n"
	return source + wrappers
