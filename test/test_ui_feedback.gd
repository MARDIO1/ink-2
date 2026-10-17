extends SceneTree
const ThemeInk := preload("res://ui/theme/asset/ink_attack_theme.tres")
const Appearance := preload("res://ui/theme/src/button_appearance.gd")
const Indicator := preload("res://ui/theme/ink_selection_indicator.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	print("[UIFeedback] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1

func settle() -> void:
	for frame in 3:
		await process_frame

func _run() -> void:
	var host := Control.new()
	host.theme = ThemeInk
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(host)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var button := Button.new()
	button.text = "反馈测试"
	button.position = Vector2(40, 40)
	button.size = Vector2(180, 52)
	var calls := [0]
	button.pressed.connect(func(): calls[0] += 1)
	host.add_child(button)
	await settle()
	var feedback := button.get_node("ButtonFeedback")
	check("dynamic button automatically receives feedback", feedback != null)
	var service := root.get_node("UIFeedback")
	for repeat in 3:
		service._install(weakref(button))
	check("reinstallation is idempotent", button.find_children("ButtonFeedback", "Control", false, false).size() == 1)
	check("feedback never adds business pressed callbacks", button.pressed.get_connections().size() == 1)
	check("overlay ignores mouse and keyboard focus", feedback.mouse_filter == Control.MOUSE_FILTER_IGNORE and feedback.focus_mode == Control.FOCUS_NONE)
	check("button color is stable in every enabled state", button.get_theme_stylebox("normal") == button.get_theme_stylebox("hover") and button.get_theme_stylebox("normal") == button.get_theme_stylebox("pressed") and button.get_theme_color("font_color") == button.get_theme_color("font_pressed_color"))
	for variation in ["Button", "PrimaryButton", "DangerButton", "MenuActionButton"]:
		check("no extra focus frame: " + variation, ThemeInk.get_stylebox("focus", variation) is StyleBoxEmpty)
	var hit_rect := button.get_global_rect()
	button.mouse_entered.emit()
	await create_timer(0.12).timeout
	check("hover receives visible animated response", feedback._weight > 0.5)
	button.button_down.emit()
	await create_timer(0.12).timeout
	check("press has stronger response than hover", feedback._held and feedback._weight > 0.9)
	check("animation never changes hit rectangle", button.get_global_rect() == hit_rect)
	button.disabled = true
	await settle()
	check("disabling held button clears held hover state", not feedback._held and not feedback._hovered)
	await create_timer(0.12).timeout
	check("disabled button removes active feedback", feedback._weight < 0.01)
	button.disabled = false
	button.mouse_entered.emit()
	button.button_down.emit()
	button.hide()
	check("hiding held button clears held state immediately", not feedback._held)
	button.show()
	button.button_down.emit()
	root.focus_exited.emit()
	check("losing focus cannot leave pressed feedback stuck", not feedback._held)
	button.toggle_mode = true
	button.set_pressed_no_signal(true)
	await settle()
	check("programmatic toggle gets persistent selection feedback", feedback._selected)
	button.set_pressed_no_signal(false)
	await settle()
	check("programmatic deselection clears indicator", not feedback._selected)
	button.pressed.emit()
	check("one business activation remains one activation", calls[0] == 1)
	var swatch := Button.new()
	host.add_child(swatch)
	Indicator.install(swatch, Color.BLACK)
	await settle()
	check("ink swatches retain their dedicated circular selection", swatch.has_node("InkSelectionIndicator") and not swatch.has_node("ButtonFeedback"))
	var tool := Button.new()
	tool.text = ""
	Appearance.uniform(tool, true)
	var icon := TextureRect.new()
	icon.name = "ToolIcon"
	icon.texture = load("res://ui/asset/nail.tres")
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.size = Vector2(24, 24)
	tool.add_child(icon)
	var caption := Label.new()
	caption.name = "Caption"
	caption.text = "钉子"
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tool.add_child(caption)
	var icon_feedback := Node.new()
	icon_feedback.name = "IconFeedback"
	icon_feedback.set_script(preload("res://actor/canvas/src/tool_icon_feedback.gd"))
	tool.add_child(icon_feedback)
	host.add_child(tool)
	await settle()
	check("image tools keep transparent styles", tool.get_theme_stylebox("normal") is StyleBoxEmpty and tool.get_node("ButtonFeedback").image_tool)
	var caption_position := caption.position
	icon_feedback.pulse()
	check("tool pulse scales only icon", icon.scale.x < 1 and caption.position == caption_position)
	tool.button_down.emit()
	tool.disabled = true
	await settle()
	await create_timer(0.15).timeout
	check("disabled tool clears pressed state and dims icon", not icon_feedback._held and icon.scale.is_equal_approx(Vector2.ONE) and is_equal_approx(icon.modulate.a, 0.6))
	tool.disabled = false
	await settle()
	check("reenabling tool restores original ink color", icon.modulate == Color.WHITE)
	tool.button_down.emit()
	tool.hide()
	check("hidden image tool clears pressed state", not icon_feedback._held)
	# 关卡换屏会先 remove_child 再 queue_free，必须能安全停止动画。
	host.remove_child(button)
	button.queue_free()
	host.queue_free()
	await settle()
	check("removing animated UI leaves no live service references", service.is_inside_tree())
	print("[UIFeedback] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
