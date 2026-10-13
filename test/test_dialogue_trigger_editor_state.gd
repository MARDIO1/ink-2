extends SceneTree

const Trigger := preload("res://debug/creative/src/map_dialogue_trigger.gd")
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
	print("[DialogueTriggerEditorState] PASS: null/false/true, missing node, unscripted editor node")
	quit()
