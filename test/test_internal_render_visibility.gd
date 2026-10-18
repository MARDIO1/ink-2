extends SceneTree

const Renderer := preload("res://addons/pixel_destruction/render/pixel_renderer.gd")
const Body := preload("res://addons/pixel_destruction/physics/pbody.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(label: String, okay: bool) -> void:
	print("[RenderVisibility] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1


func _run() -> void:
	var renderer := Renderer.new()
	root.add_child(renderer)
	for index in 3:
		var body := Body.new()
		body.id = index + 1
		var shape := Shape.new()
		shape.fill_rect(Rect2i(0, 0, 16, 24), 1)
		body.shapes = [shape]
		body.internal_render = false
		renderer.sync(body)
		_check("hidden body creates no outline %d" % index, not renderer._nodes.has(body.id))
		body.internal_render = true
		renderer.sync(body)
		_check("visible body creates outline %d" % index, renderer._nodes.has(body.id))
		body.internal_render = false
		renderer.sync(body)
		_check("hiding clears existing outline and textures %d" % index,
			not renderer._nodes.has(body.id) and not renderer._tiles.has(body.id)
			and not renderer._textures.has(body.id) and not renderer._images.has(body.id))
		renderer.sync_all([body])
		_check("batch sync cannot recreate hidden outline %d" % index, not renderer._nodes.has(body.id))
		body.internal_render = true
		renderer.sync(body)
		_check("detached body can become visible again %d" % index, renderer._nodes.has(body.id))
		renderer.forget(body.id)
		body.shapes.clear()
	renderer.queue_free()
	await process_frame
	quit(1 if failures else 0)
