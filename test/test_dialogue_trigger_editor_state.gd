extends SceneTree

const Trigger := preload("res://map/src/map_dialogue_trigger.gd")
const Portal := preload("res://actor/portal/src/map_portal.gd")

class CreativeProbe extends Node:
	var active: Variant = null

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var level := Node2D.new()
	root.add_child(level)
	var creative := CreativeProbe.new()
	creative.name = "Creative"
	level.add_child(creative)
	var triggers := Node2D.new()
	triggers.name = "DialogueTriggers"
	level.add_child(triggers)
	var trigger := Node2D.new()
	trigger.set_script(Trigger)
	triggers.add_child(trigger)
	trigger.set_physics_process(false)
	var portal := Node2D.new()
	portal.set_script(Portal)
	level.add_child(portal)
	portal.set_physics_process(false)
	await process_frame
	await process_frame
	for state in [null, false, true]:
		creative.active = state
		var expected: bool = state == true
		assert(trigger._is_map_editor_active() == expected)
		assert(portal._editor_active() == expected)
		trigger._refresh_editor_visibility()
		assert(trigger.visible == expected)
	# 快照/父节点可能把 visible 直接写成 false；再次刷新必须恢复，而不是被旧状态拦截。
	trigger.visible = false
	trigger._refresh_editor_visibility()
	assert(trigger.visible)
	triggers.visible = false
	trigger._refresh_editor_visibility()
	assert(triggers.visible and trigger.visible)
	level.remove_child(creative)
	assert(not trigger._is_map_editor_active())
	assert(not portal._editor_active())
	creative.free()
	var unscripted := Node.new()
	unscripted.name = "Creative"
	level.add_child(unscripted)
	assert(not trigger._is_map_editor_active())
	assert(not portal._editor_active())
	await process_frame
	level.queue_free()
	await process_frame
	# Real F2 lifecycle must reveal a container saved hidden by an older map.
	var real_level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	real_level.auto_step = false
	root.add_child(real_level)
	current_scene = real_level
	await process_frame
	var real_creative = real_level.get_node("Creative")
	real_creative.auto_save_edits = false
	real_creative.auto_save_on_exit = false
	var hidden_container := Node2D.new()
	hidden_container.name = "DialogueTriggers"
	hidden_container.visible = false
	real_level.add_child(hidden_container)
	var real_trigger := Trigger.new()
	real_trigger.position = Vector2(10000, -10000)
	hidden_container.add_child(real_trigger)
	for round_index in 2:
		real_creative.set_active(true)
		await process_frame
		assert(hidden_container.visible and real_trigger.is_visible_in_tree(), "F2 must reveal hidden parent and trigger")
		real_creative.set_active(false)
		await process_frame
		assert(not hidden_container.visible and not real_trigger.is_visible_in_tree(), "Play mode must hide editor regions")
	real_level.queue_free()
	await process_frame
	print("[DialogueTriggerEditorState] PASS: null/false/true, missing node, unscripted editor node")
	print("[DialogueTriggerEditorState] PASS: hidden parent, two real F2 enter/exit cycles")
	quit()
