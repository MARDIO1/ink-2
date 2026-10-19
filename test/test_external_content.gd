extends SceneTree
## 导出版外部内容探针：验证地图逻辑路径、蓝图目录和 PCK 依赖回退。

const ContentPaths := preload("res://map/src/content_paths.gd")
const LevelSelect := preload("res://ui/level_select/src/level_select.gd")
const BlueprintStore := preload("res://blueprint/src/blueprint_store.gd")

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var expect_external := OS.get_cmdline_user_args().has("--expect-external")
	print("[ExternalContent] base_dir=", ContentPaths.base_dir())
	print("[ExternalContent] map_dir=", ContentPaths.external_map_dir())

	var title := "res://map/asset/imported/扉页.tscn"
	var resolved := ContentPaths.resolve(title)
	print("[ExternalContent] title_resolved=", resolved, " exists=", FileAccess.file_exists(resolved))
	if expect_external:
		_check(resolved != title and FileAccess.file_exists(resolved), "title resolves to external")

	var levels := LevelSelect.find_levels()
	print("[ExternalContent] levels=", levels)
	if expect_external:
		_check(levels.has(title), "level scan includes external title")
		var next_level := LevelSelect.next_level(title)
		print("[ExternalContent] next_level=", next_level)
		_check(next_level == "res://map/asset/imported/第一页.tscn",
			"default portal next level stays logical")
		var created := LevelSelect.create_blank_map()
		_check(not created.is_empty() and FileAccess.file_exists(ContentPaths.resolve(created)),
			"new blank map writes next to executable")
		if not created.is_empty() and FileAccess.file_exists(ContentPaths.resolve(created)):
			DirAccess.remove_absolute(ContentPaths.resolve(created))
		var packed_files := DirAccess.get_files_at("res://map/asset/imported")
		print("[ExternalContent] packed_imported_files=", packed_files)
		_check(not packed_files.has("扉页.tscn") and not packed_files.has("扉页.tscn.remap"),
			"title scene excluded from PCK")

	var dependency := ContentPaths.resolve("res://map/src/respawn_point.gd")
	print("[ExternalContent] dependency_resolved=", dependency)
	if expect_external:
		_check(dependency == "res://map/src/respawn_point.gd", "packed dependency falls back to res://")

	var store := BlueprintStore.new()
	var blueprints := store.list_all()
	print("[ExternalContent] blueprint_dir=", store.directory, " count=", blueprints.size())
	if expect_external:
		_check(store.directory == OS.get_executable_path().get_base_dir().path_join("blueprints"),
			"blueprint directory is next to executable")
		_check(not blueprints.is_empty(), "external blueprints are readable")
		if not blueprints.is_empty():
			var probe: Dictionary = blueprints[0].duplicate(true)
			probe["id"] = ""
			probe["name"] = "external_content_probe"
			var saved := store.save(probe)
			_check(saved, "external blueprint is writable")
			if saved:
				store.trash(str(probe.get("id", "")))

		var source := "res://map/asset/imported/第一页.tscn"
		var app: Node = load("res://root/root.tscn").instantiate()
		app.menu_music = null
		app.level_music = null
		root.add_child(app)
		current_scene = app
		await process_frame
		var packed: PackedScene = load(ContentPaths.resolve(source)) as PackedScene
		var level: Node = await app.load_level(packed, false, ContentPaths.resolve(source))
		if level == null:
			_check(false, "external map can be loaded for editor save")
		else:
			var creative: Node = level.get_node("Creative")
			creative.auto_save_edits = false
			creative.auto_save_on_exit = false
			var invalid_scene := PackedScene.new()
			var invalid_root := Node2D.new()
			invalid_root.name = "Main"
			invalid_scene.pack(invalid_root)
			invalid_root.free()
			var invalid_level: Node = await app.load_level(invalid_scene, false,
				"res://invalid_external_probe.tscn")
			_check(invalid_level == null and app.level_root.get_child(0) == level,
				"invalid map fails without replacing current level")
			var probe_path := ContentPaths.base_dir().path_join(
				"map/asset/imported/external_save_probe.tscn")
			if FileAccess.file_exists(probe_path):
				DirAccess.remove_absolute(probe_path)
			creative.map_path = probe_path
			_check(creative.export_map_to(probe_path) == OK, "external map save succeeds")
			_check(FileAccess.file_exists(probe_path), "external map save creates tscn")
			var saved_scene := ResourceLoader.load(probe_path, "PackedScene",
				ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
			_check(saved_scene != null, "saved external tscn reloads")
			if saved_scene != null:
				var restored: Node = saved_scene.instantiate()
				_check(restored.get_node_or_null("Player") != null,
					"saved external tscn keeps Player")
				restored.free()
			if FileAccess.file_exists(probe_path):
				DirAccess.remove_absolute(probe_path)
		app.queue_free()
		current_scene = null
		await process_frame

	print("[ExternalContent] %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(1 if _failures else 0)


func _check(ok: bool, label: String) -> void:
	print("[ExternalContent] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
