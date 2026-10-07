@tool
extends Control
## 烘焙编辑器：预览源图与切出来的连通块，改参数后写 .tres。
## 打开 res://tools/bake_editor.tscn 使用：编辑器里直接看，或 F6 运行。
## 只在编辑器里跑，运行时不加载（本目录不属于游戏资源）。

const BakeArt := preload("res://tools/bake_art.gd")

const MIN_ZOOM := 0.05
const MAX_ZOOM := 16.0
const BG := Color(0.11, 0.12, 0.14)
## 显式文字色：项目默认主题是暗色，靠主题取色会随环境变，这里钉死。
const FG := Color(0.88, 0.90, 0.94)
## 高对比、互相可区分的块配色（黑线稿上也要看得见）。
const BLOCK_COLORS := [
	Color("ff5252"), Color("40c4ff"), Color("ffd740"), Color("69f0ae"),
	Color("e040fb"), Color("ffab40"), Color("18ffff"), Color("b2ff59"),
	Color("ff4081"), Color("8c9eff"),
]

var _art := BakeArt.new()
var _texture: ImageTexture = null
var _analysis: Dictionary = {}
var _parts: Array = []
var _bounds: Array = []

var _source: OptionButton
var _cell: SpinBox
var _scale: SpinBox
var _turn: CheckBox
var _preview: Control
var _report: RichTextLabel
var _zoom_label: Label
var _font: Font

var _zoom := 1.0
var _pan := Vector2.ZERO
var _dragging := false
var _fit_pending := true


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not Engine.is_editor_hint():
		## 项目本身是 960x540 + canvas_items 拉伸；本工具要 1:1 真实像素和更大的地方，
		## 所以关掉拉伸、强制窗口化再给一个够大的窗口。
		var win := get_window()
		win.content_scale_size = Vector2i(0, 0)
		win.mode = Window.MODE_WINDOWED
		win.size = Vector2i(1280, 860)
	_font = ThemeDB.fallback_font
	_build()
	refresh()


func _build() -> void:
	## 铺自己的底色。项目的清屏色是浅色 + 默认主题是暗色（浅字），
	## 不铺底就成了「浅底浅字」，复选框文字几乎看不见。
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	root.add_child(bar)

	bar.add_child(_label("源图"))
	_source = OptionButton.new()
	for src: Array in BakeArt.SOURCES:
		_source.add_item(str(src[0]))
	_source.item_selected.connect(_on_source_selected)
	bar.add_child(_source)

	bar.add_child(_label("格宽"))
	_cell = SpinBox.new()
	_cell.min_value = 2
	_cell.max_value = 128
	_cell.step = 1
	_cell.value = BakeArt.CELL
	_cell.value_changed.connect(_on_changed)
	bar.add_child(_cell)

	bar.add_child(_label("放大"))
	_scale = SpinBox.new()
	_scale.min_value = 1
	_scale.max_value = 8
	_scale.step = 1
	_scale.value = 1
	_scale.value_changed.connect(_on_changed)
	bar.add_child(_scale)

	_turn = CheckBox.new()
	_turn.text = "顺时针90°"
	_turn.button_pressed = bool(BakeArt.SOURCES[0][3])
	_tint(_turn)
	_turn.toggled.connect(_on_changed)
	bar.add_child(_turn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	_zoom_label = _label("")
	bar.add_child(_zoom_label)

	var fit := Button.new()
	fit.text = "适应窗口"
	fit.pressed.connect(_on_fit_pressed)
	bar.add_child(fit)

	var write := Button.new()
	write.text = "写入 .tres"
	write.pressed.connect(_write)
	bar.add_child(write)

	_preview = Control.new()
	_preview.custom_minimum_size = Vector2(0, 200)
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview.clip_contents = true
	_preview.mouse_filter = Control.MOUSE_FILTER_STOP
	_preview.draw.connect(_draw_preview)
	_preview.gui_input.connect(_on_preview_input)
	_preview.resized.connect(_on_preview_resized)
	root.add_child(_preview)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 250)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_report = RichTextLabel.new()
	_report.bbcode_enabled = true
	_report.add_theme_color_override("default_color", FG)
	_report.fit_content = true
	_report.selection_enabled = true
	_report.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_report)


func _on_source_selected(index: int) -> void:
	if index >= 0 and index < BakeArt.SOURCES.size():
		_turn.button_pressed = bool(BakeArt.SOURCES[index][3])
		_cell.value = float(BakeArt.SOURCES[index][5])
	_zoom = 1.0
	_pan = Vector2.ZERO
	refresh()


func _on_changed(_value: float) -> void:
	refresh()


func _on_fit_pressed() -> void:
	_fit_pending = true
	_fit_to_window()


func _on_preview_resized() -> void:
	if _fit_pending:
		_fit_to_window()
	_preview.queue_redraw()


## 把整张源图缩放到能完整看见，并居中。zoom 允许 < 1（大图要能整体缩小）。
func _fit_to_window() -> void:
	if _texture == null:
		return
	var avail: Vector2 = _preview.size
	if avail.x < 8.0 or avail.y < 8.0:
		return
	var size: Vector2 = _texture.get_size()
	if size.x <= 0.0 or size.y <= 0.0:
		return
	_zoom = clampf(minf(avail.x / size.x, avail.y / size.y) * 0.94, MIN_ZOOM, MAX_ZOOM)
	_pan = (avail - size * _zoom) * 0.5
	_fit_pending = false
	_update_zoom_label()
	_preview.queue_redraw()


func _zoom_at(pos: Vector2, factor: float) -> void:
	var before := _zoom
	_zoom = clampf(_zoom * factor, MIN_ZOOM, MAX_ZOOM)
	if is_equal_approx(before, _zoom):
		return
	## 让光标下的那个源图像素保持不动。
	_pan = pos - (pos - _pan) * (_zoom / before)
	_fit_pending = false
	_update_zoom_label()
	_preview.queue_redraw()


func _on_preview_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(mb.position, 1.15)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(mb.position, 1.0 / 1.15)
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = mb.pressed
			if mb.pressed:
				_fit_pending = false
	elif ev is InputEventMouseMotion and _dragging:
		_pan += (ev as InputEventMouseMotion).relative
		_preview.queue_redraw()


func _update_zoom_label() -> void:
	if _zoom_label == null or _cell == null:
		return
	_zoom_label.text = "缩放 %.0f%%   1 格 ≈ %.1f px" % [
		_zoom * 100.0, float(int(_cell.value)) * _zoom]


## 重算网格、连通块和预览；不改磁盘。
func refresh() -> void:
	if _source == null:
		return
	var src: Array = BakeArt.SOURCES[_source.selected]
	_analysis = _art.analyse(str(src[0]), int(_cell.value), _turn.button_pressed, int(src[2]), int(src[4]))
	if _analysis.is_empty():
		_texture = null
		_parts = []
		_bounds = []
		_report.text = "[color=#ff8a80]读不到源图。[/color]"
		_preview.queue_redraw()
		return
	_texture = ImageTexture.create_from_image(_analysis["image"])
	_parts = _art.components(_analysis["solid"], _analysis["w"], _analysis["h"])
	_bounds = _art.boxes(_parts, _analysis["w"])

	var scale := int(_scale.value)
	var origin: Vector2i = _analysis["origin"]
	var lines := PackedStringArray()
	lines.append("[b]%s[/b]   裁切原点 (%d, %d)   网格 [b]%d×%d[/b]   实心 %d 格（高光 %d）   连通块 %d" % [
		str(src[0]), origin.x, origin.y,
		_analysis["w"], _analysis["h"], _analysis["count"],
		_analysis["highlights"], _parts.size()])
	for i: int in _bounds.size():
		var bound: Rect2i = _bounds[i]
		var color: Color = BLOCK_COLORS[i % BLOCK_COLORS.size()]
		lines.append("[color=#%s]■[/color] %s_%d.tres   position = Vector2(%d, %d)   格 %d×%d -> 输出 %d×%d 像素    %d 格" % [
			color.to_html(false), str(src[1]), i,
			bound.position.x * scale, bound.position.y * scale,
			bound.size.x, bound.size.y,
			bound.size.x * scale, bound.size.y * scale,
			_parts[i].size()])
	lines.append("「格宽」= 重新抽样：1 格宽的线稿可能整段消失；要换尺寸请改源图。")
	lines.append("「放大」N（无损）= 1 格变 N×N 格：质量 ×N²，position ×N（上面已换算）。滚轮缩放 · 拖拽平移 · 适应窗口复位。")
	_report.text = "\n".join(lines)
	_update_zoom_label()
	_fit_pending = true
	if _preview.size.x > 8.0 and _preview.size.y > 8.0:
		_fit_to_window()
	else:
		_preview.queue_redraw()


func _write() -> void:
	if _parts.is_empty():
		return
	var src: Array = BakeArt.SOURCES[_source.selected]
	var keep: Dictionary = {}
	for item: Dictionary in _art.write(str(src[1]), _analysis["mat"], _analysis["w"], _parts, _bounds, int(_scale.value)):
		keep[item["name"]] = true
		print("  ", item["name"], " save=", item["save"])
	_art.prune(str(src[1]), keep)
	print("烘焙写入完成：", str(src[1]), " 共 ", keep.size(), " 块")
	refresh()


func _draw_preview() -> void:
	_preview.draw_rect(Rect2(Vector2.ZERO, _preview.size), BG)
	if _texture == null:
		return
	var size: Vector2 = _texture.get_size()
	_preview.draw_texture_rect(_texture, Rect2(_pan, size * _zoom), false)

	var origin: Vector2i = _analysis["origin"]
	var cell: int = int(_cell.value)
	var w: int = _analysis["w"]
	var h: int = _analysis["h"]
	var step := float(cell) * _zoom
	## 裁切区（= 真正参与烘焙的部分）在屏幕上的矩形。
	var used := Rect2(_pan + Vector2(origin) * _zoom, Vector2(w, h) * step)

	if step >= 5.0:
		var grid := Color(0.0, 0.0, 0.0, 0.18)
		for cx: int in w + 1:
			var x: float = used.position.x + float(cx) * step
			_preview.draw_line(Vector2(x, used.position.y), Vector2(x, used.end.y), grid)
		for cy: int in h + 1:
			var y: float = used.position.y + float(cy) * step
			_preview.draw_line(Vector2(used.position.x, y), Vector2(used.end.x, y), grid)

	for i: int in _bounds.size():
		var bound: Rect2i = _bounds[i]
		var color: Color = BLOCK_COLORS[i % BLOCK_COLORS.size()]
		## ⚠️ bound.position 是**格**，used.position 是**屏幕像素**：
		##    必须先把格换算成像素（×step）再加到屏幕上，不能直接相加。
		var r := Rect2(
			used.position + Vector2(bound.position) * step,
			Vector2(bound.size) * step)
		_preview.draw_rect(r, Color(color.r, color.g, color.b, 0.22), true)
		_preview.draw_rect(r, color, false, 2.0)
		if _font != null and r.size.x > 16.0 and r.size.y > 16.0:
			var tag := str(i)
			var fs := 12
			var baseline := r.position + Vector2(3.0, float(fs) + 2.0)
			var tw := _font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
			_preview.draw_rect(
				Rect2(baseline - Vector2(2.0, float(fs)), tw + Vector2(4.0, 2.0)),
				Color(0.0, 0.0, 0.0, 0.7), true)
			_preview.draw_string(_font, baseline, tag, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)

	_preview.draw_rect(used, Color(1.0, 1.0, 1.0, 0.35), false, 1.0)


func _label(text: String) -> Label:
	var node := Label.new()
	node.text = text
	node.add_theme_color_override("font_color", FG)
	return node


## CheckBox 这类自带文字的控件，文字色同样钉死。
func _tint(node: Control) -> void:
	node.add_theme_color_override("font_color", FG)
	node.add_theme_color_override("font_hover_color", FG)
	node.add_theme_color_override("font_pressed_color", FG)