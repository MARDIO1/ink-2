extends SceneTree
const Portal := preload("res://actor/portal/src/map_portal.gd")
const PortalScene := preload("res://actor/portal/map_portal.tscn")
var failures := 0
var checks := 0

class EditorProbe extends Node:
	var active := false

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	print("[PortalCharge] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1

func _render_checks() -> void:
	var viewports: Array[SubViewport] = []
	var paper_frames: Array[Sprite2D] = []
	for progress in [0.0, 0.25, 0.65, 1.0]:
		var viewport := SubViewport.new()
		viewport.size = Vector2i(240, 240)
		viewport.world_2d = World2D.new()
		viewport.transparent_bg = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		var host := Node2D.new()
		viewport.add_child(host)
		var portal = PortalScene.instantiate()
		host.add_child(portal)
		portal.position = Vector2(120, 120)
		portal.set_process(false)
		portal.set_physics_process(false)
		if progress > 0.0:
			portal.advance_overlap(progress * Portal.OVERLAP_SECONDS, true, false)
		portal._process(0.1)
		# 原纸框包含暖纸色；单独验证新增特效，不改变或误判已有美术资源。
		var paper_frame := portal.get_node("PaperFrame") as Sprite2D
		paper_frame.hide()
		paper_frames.append(paper_frame)
		viewports.append(viewport)
	await process_frame
	await RenderingServer.frame_post_draw
	var sheet := Image.create_empty(960, 240, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.88, 0.88, 0.88))
	for index in viewports.size():
		var frame := viewports[index].get_texture().get_image()
		var monochrome := true
		var changed := false
		for y in frame.get_height():
			for x in frame.get_width():
				var color := frame.get_pixel(x, y)
				if color.a > 0.01 and (absf(color.r - color.g) > 0.01 or absf(color.g - color.b) > 0.01):
					monochrome = false
				if color.a > 0.5:
					changed = true
		check("rendered stage %d stays black and white" % index, monochrome and changed)
	for paper_frame in paper_frames:
		paper_frame.show()
	await process_frame
	await RenderingServer.frame_post_draw
	for index in viewports.size():
		var frame := viewports[index].get_texture().get_image()
		sheet.blend_rect(frame, Rect2i(0, 0, 240, 240), Vector2i(index * 240, 0))
	var output := OS.get_user_data_dir().path_join("portal_charge_preview.png")
	check("charge preview rendered", sheet.save_png(output) == OK)
	print("PORTAL_CHARGE_PREVIEW=", output)
	for viewport in viewports:
		viewport.queue_free()
	await process_frame

func _run() -> void:
	var host := Node2D.new()
	root.add_child(host)
	var editor := EditorProbe.new()
	editor.name = "Creative"
	host.add_child(editor)
	var portal = PortalScene.instantiate()
	host.add_child(portal)
	portal.set_process(false)
	portal.set_physics_process(false)
	portal._process(0)
	check("idle portal has no charging effect", portal._charge_progress() == 0.0 and portal._charge_clock == 0.0 and portal._completion_elapsed == -1.0)
	check("progress uses neutral black and white", Portal.PROGRESS_INK == Color.BLACK and Portal.PROGRESS_PAPER == Color.WHITE)
	var position: Vector2 = portal.position
	var scale_before: Vector2 = portal.scale
	var size_before: Vector2 = portal.portal_size
	var pick_before: bool = portal.contains_world_point(Vector2(30, 0))
	check("first half second does not fire", not portal.advance_overlap(0.5, true, false))
	portal._process(0.1)
	check("quarter progress reaches shader exactly", is_equal_approx(portal._charge_progress(), 0.25) and is_equal_approx(portal._spiral_material.get_shader_parameter("charge"), 0.25))
	var first_step: float = portal._spiral_phase
	portal.advance_overlap(1.4, true, false)
	portal._process(0.1)
	check("vortex speeds up toward completion", portal._spiral_phase - first_step > first_step)
	check("effects do not move or resize trigger", portal.position == position and portal.scale == scale_before and portal.portal_size == size_before and portal.contains_world_point(Vector2(30, 0)) == pick_before)
	portal.advance_overlap(0, false, false)
	portal._process(0)
	check("leaving clears progress shader and pulse", portal._charge_progress() == 0.0 and portal._charge_clock == 0.0 and portal._completion_elapsed == -1.0 and portal._spiral_material.get_shader_parameter("charge") == 0.0)
	check("continuous two seconds still fires once", portal.advance_overlap(2.0, true, false) and not portal.advance_overlap(3.0, true, false))
	check("completion begins one outward pulse", portal._completion_elapsed == 0.0)
	portal._process(0.5)
	check("completion pulse finishes without looping", portal._completion_elapsed == -1.0 and not portal.advance_overlap(5, true, false))
	portal._status = "目标不可用"
	portal._process(0)
	check("unavailable destination stops charging feedback", portal._charge_progress() == 0.0 and portal._spiral_material.get_shader_parameter("charge") == 0.0)
	portal.advance_overlap(0, false, false)
	portal.advance_overlap(1, true, false)
	editor.active = true
	portal._process(0.1)
	check("editor hides charging effects", portal._spiral_material.get_shader_parameter("charge") == 0.0 and portal._charge_clock == 0.0)
	portal.advance_overlap(0.1, true, true)
	check("editor still resets overlap timer", portal.overlap_time == 0.0)
	editor.active = false
	portal.advance_overlap(1, true, false)
	portal.set_process(true)
	var phase_before: float = portal._spiral_phase
	var clock_before: float = portal._charge_clock
	paused = true
	for _frame in 3:
		await process_frame
	check("pause freezes vortex and charging motion", portal._spiral_phase == phase_before and portal._charge_clock == clock_before)
	paused = false
	portal.set_process(false)
	var second = PortalScene.instantiate()
	host.add_child(second)
	second.set_process(false)
	second.set_physics_process(false)
	second._process(0)
	portal._process(0)
	check("charging material is isolated per portal", second._spiral_material != portal._spiral_material and second._spiral_material.get_shader_parameter("charge") == 0.0 and portal._spiral_material.get_shader_parameter("charge") == 0.5)
	var legacy := Portal.new()
	host.add_child(legacy)
	legacy.set_process(false)
	legacy.set_physics_process(false)
	legacy.advance_overlap(1, true, false)
	legacy._process(0)
	check("legacy map portals receive the same charge effect", legacy._charge_progress() == 0.5 and legacy._spiral_material.get_shader_parameter("charge") == 0.5)
	host.queue_free()
	await process_frame
	if OS.get_cmdline_user_args().has("--render"):
		await _render_checks()
	print("[PortalCharge] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
