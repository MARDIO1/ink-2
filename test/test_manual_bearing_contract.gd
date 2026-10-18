extends SceneTree
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Centers := preload("res://actor/canvas/src/gear_centers.gd")
const Bearings := preload("res://actor/canvas/src/gear_bearings.gd")
const Axle := preload("res://ink/yellow/src/axle.gd")
const InkItem := preload("res://actor/ink_item/src/ink_item.gd")
const Codec := preload("res://actor/canvas/blueprint/src/blueprint_codec.gd")
const Place := preload("res://actor/canvas/blueprint/src/blueprint_place.gd")
const Format := preload("res://blueprint/src/blueprint_format.gd")
const Store := preload("res://blueprint/src/blueprint_store.gd")
var checks := 0
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(label: String, okay: bool) -> void:
	checks += 1
	failures += int(not okay)
	print("[ManualContract] %s %s" %["PASS" if okay else "FAIL",label])
func fixture() -> Node:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	level.get_node("Creative").auto_save_edits = false
	level.get_node("Creative").auto_save_on_exit = false
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000,-10000)
	canvas.canvas_size = Vector2i(256,256)
	canvas.active = true
	canvas.show()
	canvas.set_map_editor_mode(true)
	canvas.surface.ink_free = true
	return level
func gears(level) -> Array:
	return level.get_children().filter(func(n):return n is Axle and not n.is_queued_for_deletion())
func draw_gear(surface, material: Resource, point := Vector2(80,80)) -> void:
	for index in Palette.INKS.size():
		if Palette.ink_at(index) == material:
			surface.selected_ink = index
			break
	surface.gear_tool.begin(point,12)
	surface.gear_tool.finish(point+Vector2(22,0))
func support(level, point: Vector2, material: int, node_name: String):
	var node := InkItem.new()
	node.name = node_name
	node.position = point - Vector2(8,2)
	node.rect_size = Vector2i(16,4)
	node.material_id = material
	level.add_child(node)
	node.owner = level
	level.add_body_node(node)
	return node
func screenshot(level: Node, name: String) -> void:
	if not OS.get_cmdline_user_args().has("--visual") or DisplayServer.get_name() == "headless":
		return
	root.size = Vector2i(1000,700)
	var camera = level.get_node("Camera2D")
	camera.set_process(false)
	camera.set_physics_process(false)
	camera.position_smoothing_enabled = false
	camera.global_position = level.get_node("MapCanvas").surface.to_global(Vector2(110,100))
	camera.zoom = Vector2(3,3)
	camera.make_current()
	camera.force_update_scroll()
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.codex-tmp/"+name+".png")

func _run() -> void:
	var level := fixture()
	var canvas = level.get_node("MapCanvas")
	var surface = canvas.surface
	draw_gear(surface,Palette.YELLOW)
	check("yellow gear adds no rod pixels or pending bearing", surface.rod_layer.pixels.get_used_rect().size == Vector2i.ZERO and surface.draft_bearings.is_empty())
	canvas.generate()
	var target := Centers.query(surface,level,Vector2(80.5,80.5))
	check("yellow gear solidifies as a free dynamic body", target.get("kind") == "body" and not target.body.is_static and gears(level).is_empty())
	var node = Centers.node_for_body(level,target.body)
	check("free entity has a separate center marker", node.has_node("GearCenterMarkers"))
	await screenshot(level,"manual_yellow_free")
	var mask := {"circle_rect":Rect2i(55,55,52,52)}
	var taken := Centers.take_in_rect(surface,level,Rect2i(50,50,60,60),mask)
	check("circle selection transfers entity center", taken.size() == 1 and Centers.body_records(target.body).is_empty())
	Centers.attach(surface,level,taken)
	var canvas_point := Vector2(80.5,80.5)
	var first = support(level,surface.to_global(canvas_point),Palette.GREY.id,"SupportA")
	var second = support(level,surface.to_global(canvas_point),Palette.RED.id,"SupportB")
	var ambiguous := Bearings.resolve_target(surface,canvas_point)
	check("overlapping supports require explicit choice", ambiguous.has("error") and ambiguous.get("support_count") == 2)
	check("ambiguous click cannot fall back to world", not surface.rod_layer.place_anchor(canvas_point) and gears(level).is_empty())
	var chosen := Bearings.resolve_target(surface,canvas_point,{"support_index":1})
	check("chosen support is previewed as a body connection", chosen.get("support") != null and not chosen.fixed_to_world)
	var identity_target := Bearings.resolve_target(surface,canvas_point,{"support_body":chosen.support,"support_index":0})
	check("selected support identity overrides changed candidate order", identity_target.get("support") == chosen.support)
	check("explicit support selection installs", surface.rod_layer.place_anchor(canvas_point,{"support_index":1}))
	check("installed joint uses exactly the chosen support", gears(level).size() == 1 and gears(level)[0].black_anchor.body == chosen.support and not gears(level)[0].fixed_to_world)
	await screenshot(level,"manual_yellow_supported")
	var selected_path: NodePath = gears(level)[0].support_path
	check("undo removes only the bearing", surface.undo_last_edit() and gears(level).is_empty())
	check("redo restores one bearing", surface.redo_last_edit())
	await process_frame
	check("redo preserves chosen support identity", gears(level).size() == 1 and gears(level)[0].support_path == selected_path)
	var current_wheel = gears(level)[0].yellow_anchor.body
	var wheel_shape = current_wheel.shapes[0]
	var support_body = gears(level)[0].black_anchor.body
	var support_shape = support_body.shapes[0]
	canvas._move_selection(Rect2i(50,50,70,70),Vector2i(10,0))
	check("whole assembly move retains wheel and support body identities", gears(level).size() == 1 and gears(level)[0].yellow_anchor.body == current_wheel and gears(level)[0].black_anchor.body == support_body)
	check("whole assembly move never resamples local pixels", current_wheel.shapes[0] == wheel_shape and support_body.shapes[0] == support_shape)
	surface._selected_rect = Rect2i(50,50,85,85)
	surface._selected_circle = false
	check("whole assembly rotation succeeds", canvas._selection_rotation.apply(canvas))
	check("whole assembly rotation retains independent shapes", gears(level).size() == 1 and gears(level)[0].yellow_anchor.body == current_wheel and current_wheel.shapes[0] == wheel_shape and support_body.shapes[0] == support_shape)
	var assembly := Codec.capture(canvas,Rect2i(50,50,85,85))
	check("assembly blueprint retains explicit support relation", not assembly.has("error") and assembly.gears.size() == 1 and not assembly.gears[0].world and assembly.gears[0].support >= 0)
	check("assembly blueprint copies", Place.place(canvas,assembly,Vector2i(150,150)).is_empty())
	check("copied assembly uses its own support", gears(level).size() == 2 and gears(level)[1].black_anchor.body != support_body and not gears(level)[1].fixed_to_world)
	var invalid := Axle.new()
	invalid.world = level.world
	invalid.explicit = true
	invalid.fixed_to_world = false
	invalid.yellow_anchor = gears(level)[0].yellow_anchor
	invalid.connect_joint()
	check("missing explicit support never creates a world joint", invalid.joint == null)
	invalid.free()
	check("circular selection can take the installed bearing", Bearings.take(surface,level,Rect2i(50,50,60,60),mask).size() == 1 and gears(level).size() == 1)
	var live_record: Dictionary = Centers.body_records(current_wheel)[0]
	var center_cell := Vector2i(Centers.position_of(live_record).floor())
	for shape in current_wheel.shapes:
		shape.clear_pixel(center_cell.x,center_cell.y)
	Centers.prune(current_wheel)
	check("erased center removes entity snap target", Centers.body_records(current_wheel).is_empty())
	var center_node = Centers.node_for_body(level,current_wheel)
	center_node.apply_nails(current_wheel,false)
	check("nail refresh cannot resurrect a removed center", Centers.body_records(current_wheel).is_empty() and center_node.gear_centers.is_empty())
	level.queue_free()
	await process_frame
	# Alt 偏心安装不依赖中心吸附，且不会新增中心记录。
	level = fixture()
	canvas = level.get_node("MapCanvas")
	surface = canvas.surface
	draw_gear(surface,Palette.YELLOW)
	check("Alt installs a draft bearing away from center", surface.rod_layer.place_anchor(Vector2(85.5,80.5),{"snap":false}))
	check("eccentric placement does not add another center", surface.gear_centers.size() == 1 and surface.draft_bearings.size() == 1)
	canvas.generate()
	check("eccentric bearing connects the selected point", gears(level).size() == 1 and Vector2(gears(level)[0].yellow_anchor.local).is_equal_approx(Vector2(85.5,80.5)))
	level.queue_free()
	await process_frame
	# 草稿手动轴承必须跨蓝图保存、复制、固化保留，且各副本独立。
	level = fixture()
	canvas = level.get_node("MapCanvas")
	surface = canvas.surface
	draw_gear(surface,Palette.YELLOW)
	check("manual draft bearing installs", surface.rod_layer.place_anchor(Vector2(80.5,80.5)))
	var blueprint := Codec.capture(canvas,Rect2i(55,55,52,52))
	check("blueprint captures pending manual bearing", not blueprint.has("error") and blueprint.draft_bearings.size() == 1)
	check("pending bearing schema validates", Format.validate(blueprint))
	var folder := "user://manual_contract_%d" % Time.get_ticks_usec()
	var store := Store.new()
	store.directory = folder
	blueprint.name = "手动轴承"
	check("pending bearing JSON saves", store.save(blueprint))
	var reloaded := store.read(blueprint.id)
	check("pending bearing survives JSON reload", reloaded.get("draft_bearings",[]).size() == 1)
	check("first copy places", Place.place(canvas,reloaded,Vector2i(145,40)).is_empty())
	check("second copy places", Place.place(canvas,reloaded,Vector2i(40,145)).is_empty())
	var identities := {}
	for record in surface.gear_centers:
		identities[int(record.id)] = true
	check("copies allocate distinct center identities", identities.size() == 3)
	check("all pending bearings target their own copied center", surface.draft_bearings.all(func(record):return identities.has(int(record.center_id))))
	canvas.generate()
	check("only three explicitly copied bearings materialize", gears(level).size() == 3)
	var packed_blueprint := Codec.capture(canvas,Rect2i(0,0,256,256))
	check("installed bearings blueprint validates", not packed_blueprint.has("error") and Format.validate(packed_blueprint))
	var old := reloaded.duplicate(true)
	old.version = 3
	old.erase("draft_bearings")
	var migrated := Store.migrate_v3(old)
	check("old blueprint migration never invents bearings", migrated.draft_bearings.is_empty() and migrated.version == Format.VERSION)
	var malformed := packed_blueprint.duplicate(true)
	if not malformed.gears.is_empty():
		malformed.gears[0].world = false
		malformed.gears[0].support = -1
	check("incomplete support cannot silently become world connection", not Format.validate(malformed))
	# Root 加载和试玩回退也只能恢复已经记录的三条连接。
	var root_path := "res://.codex-tmp/manual_installed_root.tscn"
	check("installed bearings save without conversion", level.get_node("Creative").export_map_to(root_path) == OK)
	var document: PackedScene = ResourceLoader.load(root_path,"PackedScene",ResourceLoader.CACHE_MODE_IGNORE)
	var app = load("res://root/root.tscn").instantiate()
	app.menu_music = null
	app.level_music = null
	root.add_child(app)
	current_scene = app
	var root_level: Node = await app.load_level(document,true)
	var editor = root_level.get_node("Creative")
	editor.auto_save_edits = false
	editor._activate_restored_editor()
	check("Root restores exactly the installed connections", gears(root_level).size() == 3 and gears(root_level).all(func(a):return a.joint != null))
	editor.set_active(false)
	var old_id: int = root_level.get_instance_id()
	for axle in gears(root_level):
		axle.remove_joint()
		axle.queue_free()
	editor.set_active(true)
	var deadline := Time.get_ticks_msec()+30000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var candidate: Node = app.level_root.get_child(0)
		if candidate.get_instance_id() != old_id and candidate.get_node("Creative").active and not app._loading_level:
			root_level = candidate
			break
	check("preview rollback undoes runtime bearing removal", gears(root_level).size() == 3 and gears(root_level).all(func(a):return a.joint != null))
	check("preview rollback retains all free center metadata", root_level.world.bodies.filter(func(b):return not Centers.body_records(b).is_empty()).size() == 3)
	current_scene = null
	app.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(root_path))
	# 删除后保存与重新加载应保持自由。
	for axle in gears(level):
		Bearings.erase_at(surface,surface.to_local(axle.yellow_position),1.0)
	var path := "res://.codex-tmp/manual_contract_saved.tscn"
	check("deleted bearings document saves", level.get_node("Creative").export_map_to(path) == OK)
	var saved: PackedScene = ResourceLoader.load(path,"PackedScene",ResourceLoader.CACHE_MODE_IGNORE)
	var restored := saved.instantiate()
	restored.auto_step = false
	root.add_child(restored)
	await process_frame
	check("save reload does not recreate deleted bearings", gears(restored).is_empty())
	check("save reload retains all free centers", restored.world.bodies.filter(func(b):return not Centers.body_records(b).is_empty()).size() == 3)
	restored.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	for file in DirAccess.get_files_at(folder):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(folder.path_join(file)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(folder))
	level.queue_free()
	await process_frame
	level = fixture()
	canvas = level.get_node("MapCanvas")
	surface = canvas.surface
	var source_support = support(level,surface.to_global(Vector2(80.5,80.5)),Palette.GREY.id,"DraftSupport")
	draw_gear(surface,Palette.YELLOW)
	check("draft bearing resolves existing physical support", surface.rod_layer.place_anchor(Vector2(80.5,80.5)) and not surface.draft_bearings[0].fixed_to_world and not surface.draft_bearings[0].support_path.is_empty())
	var draft_support_blueprint := Codec.capture(canvas,Rect2i(55,55,52,52))
	check("draft blueprint includes physical support identity", not draft_support_blueprint.has("error") and Format.validate(draft_support_blueprint) and draft_support_blueprint.draft_bearings[0].support >= 0)
	check("draft support blueprint copy places", Place.place(canvas,draft_support_blueprint,Vector2i(145,145)).is_empty())
	canvas.generate()
	check("draft and copied bearing use independent supports", gears(level).size() == 2 and gears(level)[0].black_anchor.body != gears(level)[1].black_anchor.body and gears(level).all(func(a): return not a.fixed_to_world and a.joint != null and a.yellow_anchor.body != a.black_anchor.body))
	level.queue_free()
	await process_frame
	print("[ManualContract] %d checks, %d failures" %[checks,failures])
	quit(1 if failures else 0)

