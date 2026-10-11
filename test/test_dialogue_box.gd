extends SceneTree

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	printerr("[DialogueBox] FAIL: ", message)


func _run() -> void:
	var game_ui_scene: PackedScene = load("res://ui/game_ui.tscn")
	var game_ui: Node = game_ui_scene.instantiate()
	root.add_child(game_ui)
	await process_frame
	var integrated_dialogue := game_ui.get_node_or_null("Dialogue") as DialogueBox
	var integrated_esc := game_ui.get_node_or_null("Esc") as CanvasLayer
	var integrated_log_button := game_ui.get_node_or_null("Hud/Root/LogButton") as TextureButton
	_check(integrated_dialogue != null, "GameUI 应装配 DialogueBox")
	_check(integrated_dialogue.lines.size() == 3, "GameUI 中的对话框应加载默认台词")
	_check(integrated_esc != null, "GameUI 应装配 ESC 菜单")
	_check(integrated_esc.layer > integrated_dialogue.layer,
		"ESC 菜单及压暗遮罩必须绘制在剧情框之上（ESC=%d，剧情=%d）" % [
			integrated_esc.layer, integrated_dialogue.layer
		])
	_check(integrated_log_button != null and integrated_log_button.texture_normal != null,
		"HUD should provide an icon-backed dialogue Log button")
	integrated_log_button.pressed.emit()
	await process_frame
	_check(integrated_dialogue.log_root.visible, "Log button should open dialogue history")
	integrated_dialogue.hide_log()
	game_ui.queue_free()
	await process_frame

	var packed: PackedScene = load("res://ui/dialogue/dialogue_box.tscn")
	var dialogue: DialogueBox = packed.instantiate()
	root.add_child(dialogue)
	dialogue.set_process(false)
	await process_frame

	var pixel_text: SubViewportContainer = dialogue.get_node(
		"Root/DialoguePanel/PixelText"
	)
	var viewport: SubViewport = pixel_text.get_node("TextViewport")
	var dialogue_font: Font = dialogue.dialogue_label.get_theme_font("font")
	_check(dialogue.viewed_lines.size() == 1,
		"history should initially contain only the first displayed line")
	_check(dialogue.lines.size() == 3, "应从 JSON 读入三句示例台词")
	_check(dialogue.current_line == 0, "应自动从第一句开始")
	_check(dialogue.dialogue_label.visible_characters == 0, "第一句应从零个字符开始打字")
	_check(not dialogue.next_hint.visible, "打字时不应显示继续提示")
	_check(pixel_text.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"低分辨率文字必须以最近邻方式放大")
	_check(pixel_text.stretch_shrink == 1,
		"文字内部不得再次二倍放大；只允许项目全局视口缩放一次")
	_check(viewport.size == Vector2i(864, 144),
		"文字视口应与对话框内容区保持一比一逻辑像素")
	_check(pixel_text.material is ShaderMaterial, "文字视口应使用硬边像素化材质")
	_check(dialogue_font.resource_path.ends_with("ipix_ui_font.tres"),
		"对话文字必须使用 IPix 显式回退链")
	_check(dialogue.dialogue_label.get_theme_color("font_color") == Color.BLACK,
		"正文颜色必须是纯黑色")
	_check(dialogue.dialogue_label.get_theme_font_size("font_size") == 16,
		"正文应以 16px 逻辑字号绘制，不得在对话框内部重复放大")
	_check(dialogue.next_hint.get_theme_color("font_color") == Color.BLACK,
		"继续提示颜色必须是纯黑色")
	var shader: Shader = (pixel_text.material as ShaderMaterial).shader
	_check("step(alpha_threshold, coverage)" in shader.code,
		"硬边阈值应通过可调参数完成二值化")
	_check(is_equal_approx(
		(pixel_text.material as ShaderMaterial).get_shader_parameter("alpha_threshold"), 0.25),
		"16px 正文必须使用 0.25 阈值，避免中文细笔画断裂")
	_check("vec4(0.0, 0.0, 0.0, hard_alpha)" in shader.code,
		"像素化输出必须把 RGB 强制为纯黑")
	_check(dialogue.dialogue_label.position.y + dialogue.dialogue_label.size.y
		<= dialogue.next_hint.position.y,
		"正文区域不得侵入继续提示区域")

	# 字形覆盖自检：当前所有台词和操作提示中的字符都必须能由 IPix 本身绘制。
	var checked_characters := 0
	for text: String in dialogue.lines + PackedStringArray([dialogue.next_hint.text]):
		for index in text.length():
			var codepoint := text.unicode_at(index)
			if codepoint <= 32:
				continue
			checked_characters += 1
			_check(dialogue_font.has_char(codepoint),
				"IPix 缺少字符：%s (U+%04X)" % [text.substr(index, 1), codepoint])
	_check(checked_characters > 0, "字形覆盖自检必须实际检查字符")

	dialogue._process(0.05)
	_check(dialogue.dialogue_label.visible_characters == 1, "打字机应按速度逐字显示")
	dialogue.advance()
	_check(dialogue.dialogue_label.visible_characters == -1, "首次单击应补全当前句")
	_check(dialogue.next_hint.visible, "句子完整后应显示继续提示")
	dialogue.advance()
	_check(dialogue.current_line == 1, "再次单击应进入下一句")
	_check(dialogue.dialogue_label.visible_characters == 0, "新句应重新逐字显示")

	dialogue.set_lines(PackedStringArray(["甲", "乙"]))
	dialogue.advance()
	dialogue.advance()
	dialogue.advance()
	dialogue.advance()
	_check(not dialogue.root.visible, "最后一句完成后再次单击应隐藏文本框")

	_check(dialogue.viewed_lines.size() >= 4,
		"history should append each later line only when it is displayed")
	dialogue.show_log()
	_check(dialogue.log_root.visible, "dialogue history should open independently")
	_check(dialogue.history_label.text.length() > 0,
		"dialogue history should display viewed lines")
	dialogue.hide_log()

	print("[DialogueBox] %d checks (%d glyphs), %d failures" % [
		_checks, checked_characters, _failures
	])
	quit(1 if _failures else 0)
