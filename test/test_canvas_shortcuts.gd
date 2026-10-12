extends "res://test/test_collision_damage.gd"

const SurfaceScript := preload("res://actor/canvas/src/canvas_surface.gd")

var _actions: Array[String] = []


func _initialize() -> void:
	call_deferred("_run_shortcuts")


func _press(canvas: Node, keycode: int, ctrl := false, echo := false) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	event.ctrl_pressed = ctrl
	event.echo = echo
	canvas._input(event)


func _run_shortcuts() -> void:
	var scene := MAIN.instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	var canvas := scene.get_node("SmallCanvas")
	canvas.dev_save_enabled = false
	var grid := canvas.get_node("WorkbenchUI/Buttons/Grid")
	_press(canvas, KEY_1)
	_check("1 brush", canvas.surface.tool == SurfaceScript.Tool.BRUSH)
	_press(canvas, KEY_2)
	_check("2 eraser", canvas.surface.tool == SurfaceScript.Tool.ERASER)
	_press(canvas, KEY_3)
	var popup := canvas.get_node("ShapePopup") as PopupMenu
	_check("3 opens shape submenu", popup.visible and popup.item_count == 3)
	for shape in [SurfaceScript.Tool.RECT, SurfaceScript.Tool.CIRCLE, SurfaceScript.Tool.LINE]:
		popup.id_pressed.emit(shape)
		_check("shape selection %d" % shape, canvas.surface.tool == shape)
	popup.hide()
	_press(canvas, KEY_4)
	_check("4 bucket", canvas.surface.tool == SurfaceScript.Tool.BUCKET)
	_press(canvas, KEY_6)
	_check("6 selection delete", canvas.surface.tool == SurfaceScript.Tool.SELECT_DELETE)
	_press(canvas, KEY_9)
	_check("hidden nail shortcut ignored", canvas.surface.tool == SurfaceScript.Tool.SELECT_DELETE)
	canvas.set_map_editor_mode(true)
	_press(canvas, KEY_9)
	_check("9 nail", canvas.surface.tool == SurfaceScript.Tool.NAIL)
	_press(canvas, KEY_0)
	var expand := canvas.get_node("ExpandCanvasWindow") as Window
	_check("0 opens expand window", expand.visible)
	_press(canvas, KEY_1)
	_check("window keeps numeric input", canvas.surface.tool == SurfaceScript.Tool.NAIL)
	expand.hide()
	_press(canvas, KEY_COLON)
	_check("non-digit does not trigger expand", not expand.visible)
	# 验证三个操作键走对应按钮信号，避免测试修改关卡地形。
	for action in ["Redraw", "Generate", "ReturnToCanvas"]:
		var button := grid.get_node(action) as Button
		for connection in button.pressed.get_connections():
			button.pressed.disconnect(connection.callable)
		button.pressed.connect(func(): _actions.append(action))
	_press(canvas, KEY_5)
	_press(canvas, KEY_7)
	_press(canvas, KEY_8)
	_check("5 clear / 7 solidify / 8 reclaim", _actions == ["Redraw", "Generate", "ReturnToCanvas"])
	_press(canvas, KEY_1, true)
	_press(canvas, KEY_1, false, true)
	_check("modified and repeated digits ignored", canvas.surface.tool == SurfaceScript.Tool.NAIL)
	var field := LineEdit.new()
	root.add_child(field)
	field.grab_focus()
	_press(canvas, KEY_1)
	_check("text entry keeps numeric input", canvas.surface.tool == SurfaceScript.Tool.NAIL)
	field.release_focus()
	_press(canvas, KEY_F)
	_check("F hand preserved", canvas.surface.tool == SurfaceScript.Tool.HAND)
	field.queue_free()
	scene.queue_free()
	await process_frame
	print("[CanvasShortcuts] %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
