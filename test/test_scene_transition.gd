extends SceneTree

var failures := 0
var checks := 0
var transition: Node

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("[Transition] %s %s" % ["PASS" if condition else "FAIL", label])

func _run() -> void:
	transition = root.get_node("SceneTransition")
	transition.duration = 0.04
	var app: Node = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	current_scene = app
	await process_frame
	await app._show_level_select()
	_check("page opens level select", app.ui_root.get_child(0).has_signal("level_chosen") and not transition.busy)
	var first: bool = await app.request_level_change("res://map/asset/imported/main.tscn")
	_check("ink opens level, unlocks and resumes", first and transition.style == transition.Style.INK and not paused and not transition.busy)
	var old_level: WeakRef = weakref(app.level_root.get_child(0))
	var second: bool = await app.request_level_change("res://map/asset/imported/main.tscn")
	await process_frame
	_check("tear replaces old level", second and transition.style == transition.Style.TEAR and old_level.get_ref() == null)
	var creative: Node = app.level_root.get_child(0).get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.toggle()
	while transition.busy:
		await process_frame
	creative = app.level_root.get_child(0).get_node("Creative")
	_check("draft waits for editor reload", creative.active and transition.style == transition.Style.DRAFT and not paused)
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	await creative.toggle()
	_check("draft returns to play", not creative.active and not paused and not transition.busy)
	await app.request_level_change("res://map/asset/imported/扉页.tscn")
	creative = app.level_root.get_child(0).get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.toggle()
	while transition.busy:
		await process_frame
	creative = app.level_root.get_child(0).get_node("Creative")
	_check("real tutorial editor and snapshot ready before reveal", creative.active and creative._edit_snapshot_loaded and not paused)
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	await creative.toggle()
	_check("real tutorial returns to play", not creative.active and not transition.busy)
	await transition.begin(transition.Style.INK, "测试加载中…")
	_check("cover pauses scene", paused and transition.busy)
	var refused: bool = await app.request_level_change("res://map/asset/imported/main.tscn")
	_check("duplicate request rejected", not refused)
	await transition.finish()
	paused = true
	await transition.begin(transition.Style.PAGE, "测试暂停恢复…")
	await transition.finish()
	_check("preexisting pause preserved", paused)
	paused = false
	if OS.get_cmdline_user_args().has("--preview-transitions"):
		await _preview()
	app.queue_free()
	await process_frame
	print("[Transition] %d checks; %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)

func _preview() -> void:
	transition.duration = 0.15
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(960, 540)
	var app: Node = current_scene
	await app.request_level_change("res://map/asset/imported/扉页.tscn")
	var level: Node = app.level_root.get_child(0)
	var debug_hud: CanvasLayer = level.get_node_or_null("debugHUD")
	if debug_hud != null:
		debug_hud.visible = false
	var output := "C:/Users/youli/.codex/visualizations/2026/10/11/01a12987-d6cc-7a63-9192-35e2107dc184"
	var names := ["page", "ink", "tear", "draft"]
	for style in 4:
		await transition.begin(style, ["翻开关卡目录…", "正在展开第一关…", "穿过纸页，前往下一关…", "展开地图画稿…"][style])
		transition._set_amount(0.67)
		transition._loading.modulate.a = 0.0
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("transition-%s.png" % names[style]))
		if OS.get_cmdline_user_args().has("--animate-transitions"):
			for frame in 25:
				var amount := minf(minf(float(frame) / 8.0, float(24 - frame) / 8.0), 1.0)
				transition._set_amount(amount)
				transition._loading.modulate.a = 1.0 if amount >= 0.999 else 0.0
				await process_frame
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(output.path_join("transition-frame-%03d.png" % (style * 25 + frame)))
		await transition.finish()
