extends CanvasLayer
## 编辑器右侧视图：拥有控件，不拥有文档、撤销或地图写入权限。
signal action_requested(action: StringName, arguments: Array)
const EDITOR_THEME := preload("res://ui/theme/asset/ink_attack_theme.tres")
const InkPalette := preload("res://ink/general/src/ink_palette.gd")
const InkSelectionIndicator := preload("res://ui/theme/ink_selection_indicator.gd")
## 模式常量只在 `application/editor_modes.gd` 定义一处。
const Modes := preload("res://debug/creative/application/editor_modes.gd")
const MONSTER_MODE_NONE := Modes.MONSTER_MODE_NONE
const MONSTER_MODE_DELETE := Modes.MONSTER_MODE_DELETE
const MONSTER_MODE_ADJUST := Modes.MONSTER_MODE_ADJUST
const DIALOGUE_MODE_PLACE := Modes.DIALOGUE_MODE_PLACE
const DIALOGUE_MODE_DELETE := Modes.DIALOGUE_MODE_DELETE
const TEXT_MODE_PLACE := Modes.TEXT_MODE_PLACE
const TEXT_MODE_DELETE := Modes.TEXT_MODE_DELETE
const LAYOUT_MODE_MOVE_SPAWN := Modes.LAYOUT_MODE_MOVE_SPAWN
const LAYOUT_MODE_PLACE_RESPAWN := Modes.LAYOUT_MODE_PLACE_RESPAWN
const LAYOUT_MODE_MOVE_RESPAWN := Modes.LAYOUT_MODE_MOVE_RESPAWN
const LAYOUT_MODE_PLACE_CANVAS := Modes.LAYOUT_MODE_PLACE_CANVAS
const LAYOUT_MODE_MOVE_CANVAS := Modes.LAYOUT_MODE_MOVE_CANVAS
const LAYOUT_MODE_PLACE_PORTAL := Modes.LAYOUT_MODE_PLACE_PORTAL
const LAYOUT_MODE_DELETE_PORTAL := Modes.LAYOUT_MODE_DELETE_PORTAL
const LAYOUT_MODE_FOUNTAIN := Modes.LAYOUT_MODE_FOUNTAIN
const LAYOUT_MODE_DELETE_CANVAS := Modes.LAYOUT_MODE_DELETE_CANVAS
const LAYOUT_MODE_DELETE_RESPAWN := Modes.LAYOUT_MODE_DELETE_RESPAWN
const MONSTER_NAMES := ["炸弹狂", "小兵", "盾兵"]
const MONSTER_NODE_NAMES := ["BombSide", "LittleSoldier", "GreatShield"]
const MapMonsterScript := preload("res://actor/monster/src/map_monster.gd")
const MONSTER_KINDS := [MapMonsterScript.Kind.BOMB_SIDE, MapMonsterScript.Kind.LITTLE_SOLDIER, MapMonsterScript.Kind.SHIELD_SOLDIER]

var _editor_ink_buttons: Array[Button] = []
var _editor_ink_label: Label
var _gear_button: Button
var _gear8_button: Button
var _infinite_nail_button: Button
var _ink_quota_fields: Dictionary = {}
var _portal_destination: PopupMenu = null
var _layout_buttons: Dictionary = {}
var _layout_status_label: Label = null
var _monster_palette_panel: PanelContainer = null
var _monster_palette_toggle: Button = null
var _monster_buttons: Array[Button] = []
var _delete_monster_button: Button = null
var _adjust_monster_button: Button = null
var _reset_monster_scale_button: Button = null
var _monster_status_label: Label = null
var _place_dialogue_button: Button = null
var _delete_dialogue_button: Button = null
var _place_text_button: Button = null
var _delete_text_button: Button = null
var _editor_nail_visibility: Button
var _map_canvas: Node
var _brush_slider: HSlider
var _brush_label: Label
var _view: Dictionary = {}
var query_ink_quota: Callable

func bind_canvas(canvas: Node, initial: Dictionary = {}) -> void:
	_map_canvas = canvas
	_view = initial
	_build_monster_palette()

func ink_quota_of(material_id: int) -> float:
	return float(query_ink_quota.call(material_id))

func _build_monster_palette() -> void:
	if get_child_count() > 0:
		return
	var layer := self
	layer.layer = 10
	layer.visible = false

	var root := Control.new()
	root.name = "Root"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	var palette_toggle := Button.new()
	palette_toggle.name = "PaletteToggle"
	palette_toggle.anchor_left = 1.0
	palette_toggle.anchor_right = 1.0
	palette_toggle.offset_left = -96.0
	# 避开右上角现有的日志、ESC 等按钮。
	palette_toggle.offset_top = 85.0
	palette_toggle.offset_right = -16.0
	palette_toggle.offset_bottom = 129.0
	palette_toggle.text = "工具\nCapslock"
	palette_toggle.tooltip_text = "收起 / 展开右侧地图编辑工具栏"
	palette_toggle.focus_mode = Control.FOCUS_NONE
	palette_toggle.theme = EDITOR_THEME
	palette_toggle.add_theme_font_size_override("font_size", 15)
	palette_toggle.pressed.connect(_toggle_monster_palette_panel)
	root.add_child(palette_toggle)
	_monster_palette_toggle = palette_toggle

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -592.0
	panel.offset_top = 134.0
	panel.offset_right = -16.0
	# 三列紧凑排布，并始终贴合视口底部，避免按钮落到地面/窗口外。
	panel.offset_bottom = -16.0
	panel.theme = EDITOR_THEME
	panel.theme_type_variation = &"OverlayPanel"
	root.add_child(panel)
	_monster_palette_panel = panel

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)
	var column := VBoxContainer.new()
	column.name = "VBox"
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	var color_title := Label.new()
	color_title.name = "ColorTitle"
	color_title.text = "色盘"
	color_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	color_title.theme_type_variation = &"TitleLabel"
	column.add_child(color_title)
	var color_grid := GridContainer.new()
	color_grid.name = "ColorGrid"
	color_grid.columns = InkPalette.ink_count()
	color_grid.add_theme_constant_override("h_separation", 18)
	color_grid.add_theme_constant_override("v_separation", 12)
	column.add_child(color_grid)
	for index in InkPalette.ink_count():
		var color := InkPalette.color_at(index)
		var color_style := StyleBoxFlat.new()
		color_style.bg_color = color
		color_style.corner_radius_top_left = 32
		color_style.corner_radius_top_right = 32
		color_style.corner_radius_bottom_left = 32
		color_style.corner_radius_bottom_right = 32
		color_style.border_width_left = 2
		color_style.border_width_top = 2
		color_style.border_width_right = 2
		color_style.border_width_bottom = 2
		color_style.border_color = Color(0.035, 0.031, 0.024, 1.0)
		var color_button := Button.new()
		color_button.name = "Ink%dButton" % index
		color_button.custom_minimum_size = Vector2(64.0, 64.0)
		color_button.tooltip_text = InkPalette.ink_name(index)
		color_button.focus_mode = Control.FOCUS_NONE
		color_button.toggle_mode = true
		color_button.add_theme_stylebox_override("normal", color_style)
		color_button.add_theme_stylebox_override("hover", color_style)
		color_button.add_theme_stylebox_override("pressed", color_style)
		color_button.pressed.connect(_select_editor_ink.bind(index))
		color_grid.add_child(color_button)
		_editor_ink_buttons.append(color_button)
		InkSelectionIndicator.install(color_button, color)
	_editor_ink_label = Label.new()
	_editor_ink_label.name = "SelectedInkLabel"
	_editor_ink_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_editor_ink_label.text = "当前：黑墨"
	column.add_child(_editor_ink_label)
	if _map_canvas != null:
		if not _map_canvas.ink_selected.is_connected(_refresh_editor_ink):
			_map_canvas.ink_selected.connect(_refresh_editor_ink)
		_refresh_editor_ink(int(_view.get("selected_ink", 0)), false)
	var brush_row := HBoxContainer.new()
	brush_row.name = "BrushSizeRow"
	brush_row.add_theme_constant_override("separation", 12)
	column.add_child(brush_row)
	var brush_label := Label.new()
	brush_label.name = "BrushSizeLabel"
	brush_label.custom_minimum_size.x = 100.0
	brush_row.add_child(brush_label)
	var brush_slider := HSlider.new()
	brush_slider.name = "BrushSizeSlider"
	brush_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brush_slider.custom_minimum_size = Vector2(160, 32)
	brush_slider.focus_mode = Control.FOCUS_NONE
	brush_slider.min_value = float(_view.get("brush_min", 1))
	brush_slider.max_value = float(_view.get("brush_max", 65))
	brush_slider.step = float(_view.get("brush_step", 1))
	brush_slider.value = float(_view.get("brush_size", 7))
	brush_label.text = "粗细：%d px" % int(brush_slider.value)
	brush_slider.tooltip_text = "调整画笔、橡皮和形状的笔触直径"
	brush_row.add_child(brush_slider)
	_brush_slider = brush_slider
	_brush_label = brush_label
	# 用户拖动只发动作；画布确认后经 brush_changed 回填，两个控件不会互相触发。
	brush_slider.value_changed.connect(func(value: float):
		action_requested.emit(&"set_brush_size", [int(round(value))])
		brush_label.text = "粗细：%d px" % int(round(value))
	)
	if _map_canvas != null and not _map_canvas.brush_changed.is_connected(_on_brush_changed):
		_map_canvas.brush_changed.connect(_on_brush_changed)
	var color_separator := HSeparator.new()
	column.add_child(color_separator)
	var edit_actions := HBoxContainer.new()
	edit_actions.name = "EditActions"
	column.add_child(edit_actions)
	var history := preload("res://actor/canvas/src/history_actions.gd").new()
	history.name = "HistoryActions"
	history.canvas = _map_canvas
	history.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit_actions.add_child(history)
	var save_map_button := Button.new()
	save_map_button.name = "SaveMapButton"
	save_map_button.text = "保存地图"
	save_map_button.tooltip_text = "打开地图保存窗口（F5），确认后才写入地图"
	save_map_button.focus_mode = Control.FOCUS_NONE
	save_map_button.pressed.connect(_open_map_save_window)
	edit_actions.add_child(save_map_button)
	var view_actions := HBoxContainer.new()
	view_actions.name = "ViewActions"
	column.add_child(view_actions)
	_editor_nail_visibility = Button.new()
	_editor_nail_visibility.name = "NailVisibility"
	_editor_nail_visibility.text = "显示钉子"
	_editor_nail_visibility.tooltip_text = "只切换钉子外观，保留固定点；不修改工具栏图标"
	_editor_nail_visibility.toggle_mode = true
	_editor_nail_visibility.focus_mode = Control.FOCUS_NONE
	_editor_nail_visibility.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_editor_nail_visibility.toggled.connect(func(on: bool):
		action_requested.emit(&"set_nails_visible", [on])
	)
	if not _map_canvas.nails_visibility_changed.is_connected(_on_nails_visibility_changed):
		_map_canvas.nails_visibility_changed.connect(_on_nails_visibility_changed)
	view_actions.add_child(_editor_nail_visibility)
	_refresh_editor_visibility()

	var mechanism_title := Label.new()
	mechanism_title.name = "MechanismTitle"
	mechanism_title.text = "机关部件"
	mechanism_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mechanism_title.theme_type_variation = &"TitleLabel"
	column.add_child(mechanism_title)
	var mechanism_grid := GridContainer.new()
	mechanism_grid.name = "MechanismGrid"
	mechanism_grid.columns = 3
	column.add_child(mechanism_grid)
	_gear8_button = Button.new()
	_gear8_button.name = "Gear8ToolButton"
	_gear8_button.text = "八齿齿轮"
	_gear8_button.tooltip_text = "八齿齿轮：按下定圆心，拖动定半径；使用当前墨水颜色；框选移动，R 旋转 2°，绘制时自带黄色圆轴"
	_gear8_button.toggle_mode = true
	_gear8_button.focus_mode = Control.FOCUS_NONE
	_gear8_button.custom_minimum_size = Vector2(96.0, 44.0)
	_gear8_button.pressed.connect(select_gear_tool.bind(8))
	mechanism_grid.add_child(_gear8_button)
	_gear_button = Button.new()
	_gear_button.name = "GearToolButton"
	_gear_button.text = "十二齿齿轮"
	_gear_button.tooltip_text = "十二齿齿轮：按下定圆心，拖动定半径；使用当前墨水颜色；框选移动，R 旋转 2°，绘制时自带黄色圆轴；再次点击退出"
	_gear_button.toggle_mode = true
	_gear_button.focus_mode = Control.FOCUS_NONE
	_gear_button.custom_minimum_size = Vector2(96.0, 44.0)
	_gear_button.pressed.connect(select_gear_tool.bind(12))
	mechanism_grid.add_child(_gear_button)
	# 无限标签属于机关：它靠"钉在红墨上提供无尽能源"这一条参与机关，是工具不是画刷。
	_infinite_nail_button = Button.new()
	_infinite_nail_button.name = "InfiniteNailToolButton"
	_infinite_nail_button.text = "无限标签"
	_infinite_nail_button.tooltip_text = "无限标签：不可破坏；钉在红色墨水上提供无尽能源；仅创造模式可用；再次点击退出"
	_infinite_nail_button.toggle_mode = true
	_infinite_nail_button.focus_mode = Control.FOCUS_NONE
	_infinite_nail_button.custom_minimum_size = Vector2(96.0, 44.0)
	_infinite_nail_button.pressed.connect(select_infinite_nail_tool)
	mechanism_grid.add_child(_infinite_nail_button)
	sync_gear_buttons(false, false)
	column.add_child(HSeparator.new())

	var title := Label.new()
	title.name = "MonsterTitle"
	title.text = "小怪放置"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.theme_type_variation = &"TitleLabel"
	column.add_child(title)
	var monster_hint_label := Label.new()
	monster_hint_label.name = "MonsterHint"
	monster_hint_label.text = "左键选中拖动 · 右键删除"
	monster_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	monster_hint_label.add_theme_font_size_override("font_size", 14)
	monster_hint_label.add_theme_color_override("font_color", Color(0.35, 0.3, 0.2, 0.8))
	column.add_child(monster_hint_label)
	var monster_grid := GridContainer.new()
	monster_grid.name = "MonsterGrid"
	monster_grid.columns = 3
	monster_grid.add_theme_constant_override("h_separation", 6)
	monster_grid.add_theme_constant_override("v_separation", 6)
	column.add_child(monster_grid)
	for index in MONSTER_NAMES.size():
		var button := Button.new()
		button.name = MONSTER_NODE_NAMES[index] + "Button"
		button.set_meta("monster_kind", MONSTER_KINDS[index])
		button.text = MONSTER_NAMES[index]
		button.tooltip_text = "选择后在地图上单击放置%s" % MONSTER_NAMES[index]
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(96.0, 44.0)
		button.pressed.connect(select_monster_tool.bind(MONSTER_KINDS[index]))
		monster_grid.add_child(button)
		_monster_buttons.append(button)

	_delete_monster_button = Button.new()
	_delete_monster_button.name = "DeleteMonsterButton"
	_delete_monster_button.text = "删除怪物"
	_delete_monster_button.tooltip_text = "选择后左键点击怪物删除；右键也可删除，Ctrl+Z 撤销"
	_delete_monster_button.toggle_mode = true
	_delete_monster_button.focus_mode = Control.FOCUS_NONE
	_delete_monster_button.custom_minimum_size = Vector2(96.0, 44.0)
	_delete_monster_button.pressed.connect(select_monster_tool.bind(MONSTER_MODE_DELETE))
	monster_grid.add_child(_delete_monster_button)

	_reset_monster_scale_button = Button.new()
	_reset_monster_scale_button.name = "ResetMonsterScaleButton"
	_reset_monster_scale_button.text = "恢复原始大小"
	_reset_monster_scale_button.tooltip_text = "恢复当前选中小怪的原始大小"
	_reset_monster_scale_button.focus_mode = Control.FOCUS_NONE
	_reset_monster_scale_button.custom_minimum_size = Vector2(96.0, 44.0)
	_reset_monster_scale_button.pressed.connect(_reset_selected_monster_scale)
	monster_grid.add_child(_reset_monster_scale_button)

	var separator := HSeparator.new()
	column.add_child(separator)
	var dialogue_title := Label.new()
	dialogue_title.name = "DialogueTitle"
	dialogue_title.text = "对话触发点"
	dialogue_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dialogue_title.theme_type_variation = &"TitleLabel"
	column.add_child(dialogue_title)
	var dialogue_grid := GridContainer.new()
	dialogue_grid.name = "DialogueGrid"
	dialogue_grid.columns = 3
	dialogue_grid.add_theme_constant_override("h_separation", 6)
	dialogue_grid.add_theme_constant_override("v_separation", 6)
	column.add_child(dialogue_grid)

	_place_dialogue_button = Button.new()
	_place_dialogue_button.name = "PlaceDialogueTriggerButton"
	_place_dialogue_button.text = "放置对话点"
	_place_dialogue_button.tooltip_text = "选择后单击地图，输入按顺序播放的多句文案"
	_place_dialogue_button.toggle_mode = true
	_place_dialogue_button.focus_mode = Control.FOCUS_NONE
	_place_dialogue_button.custom_minimum_size = Vector2(96.0, 44.0)
	_place_dialogue_button.pressed.connect(select_monster_tool.bind(DIALOGUE_MODE_PLACE))
	dialogue_grid.add_child(_place_dialogue_button)

	_delete_dialogue_button = Button.new()
	_delete_dialogue_button.name = "DeleteDialogueTriggerButton"
	_delete_dialogue_button.text = "删除对话点"
	_delete_dialogue_button.tooltip_text = "选择后单击 100×100 对话触发区域进行删除"
	_delete_dialogue_button.toggle_mode = true
	_delete_dialogue_button.focus_mode = Control.FOCUS_NONE
	_delete_dialogue_button.custom_minimum_size = Vector2(96.0, 44.0)
	_delete_dialogue_button.pressed.connect(select_monster_tool.bind(DIALOGUE_MODE_DELETE))
	dialogue_grid.add_child(_delete_dialogue_button)

	var text_separator := HSeparator.new()
	column.add_child(text_separator)
	var text_title := Label.new()
	text_title.name = "TextTitle"
	text_title.text = "文本放置"
	text_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text_title.theme_type_variation = &"TitleLabel"
	column.add_child(text_title)
	var text_grid := GridContainer.new()
	text_grid.name = "TextGrid"
	text_grid.columns = 3
	text_grid.add_theme_constant_override("h_separation", 6)
	text_grid.add_theme_constant_override("v_separation", 6)
	column.add_child(text_grid)

	_place_text_button = Button.new()
	_place_text_button.name = "PlaceTextButton"
	_place_text_button.text = "放置文本"
	_place_text_button.tooltip_text = "选择后单击地图，输入要显示的手写文本"
	_place_text_button.toggle_mode = true
	_place_text_button.focus_mode = Control.FOCUS_NONE
	_place_text_button.custom_minimum_size = Vector2(96.0, 44.0)
	_place_text_button.pressed.connect(select_monster_tool.bind(TEXT_MODE_PLACE))
	text_grid.add_child(_place_text_button)

	_delete_text_button = Button.new()
	_delete_text_button.name = "DeleteTextButton"
	_delete_text_button.text = "删除文本"
	_delete_text_button.tooltip_text = "选择后单击地图上的文本进行删除"
	_delete_text_button.toggle_mode = true
	_delete_text_button.focus_mode = Control.FOCUS_NONE
	_delete_text_button.custom_minimum_size = Vector2(96.0, 44.0)
	_delete_text_button.pressed.connect(select_monster_tool.bind(TEXT_MODE_DELETE))
	text_grid.add_child(_delete_text_button)

	var stop_button := Button.new()
	stop_button.name = "StopMonsterToolButton"
	stop_button.text = "停止放置"
	stop_button.focus_mode = Control.FOCUS_NONE
	stop_button.custom_minimum_size = Vector2(96.0, 44.0)
	stop_button.pressed.connect(select_monster_tool.bind(MONSTER_MODE_NONE))
	text_grid.add_child(stop_button)

	var layout_separator := HSeparator.new()
	column.add_child(layout_separator)
	var layout_title := Label.new()
	layout_title.name = "LayoutTitle"
	layout_title.text = "地图与布局"
	layout_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layout_title.theme_type_variation = &"TitleLabel"
	column.add_child(layout_title)
	var layout_grid := GridContainer.new()
	layout_grid.name = "LayoutGrid"
	layout_grid.columns = 3
	layout_grid.add_theme_constant_override("h_separation", 6)
	layout_grid.add_theme_constant_override("v_separation", 6)
	column.add_child(layout_grid)
	var layout_tools := [
		[LAYOUT_MODE_PLACE_RESPAWN, "PlaceRespawnButton", "新增复活点", "单击空地新增橙色复活点；按在已有复活点上拖动即可移动；右键删除"],
		[LAYOUT_MODE_MOVE_RESPAWN, "MoveRespawnButton", "移动复活点", "拖动橙色标记调整复活位置；右键删除"],
		[LAYOUT_MODE_DELETE_RESPAWN, "DeleteRespawnButton", "删除复活点", "单击橙色复活点删除；Ctrl+Z 撤销"],
		[LAYOUT_MODE_PLACE_CANVAS, "PlacePlayCanvasButton", "新增画布", "先设置宽高，再单击地图放置画布；按在已有画布上拖动即可移动；右键删除"],
		[LAYOUT_MODE_MOVE_CANVAS, "MovePlayCanvasButton", "移动画布", "左键拖动画布；右键删除画布；Ctrl+Z 撤销"],
		[LAYOUT_MODE_DELETE_CANVAS, "DeletePlayCanvasButton", "删除画布", "单击画布删除；Ctrl+Z 撤销"],
		[LAYOUT_MODE_PLACE_PORTAL, "PlacePortalButton", "新增传送门", "选择目标地图后单击地图放置；按在已有传送门上拖动即可移动；右键删除"],
		[LAYOUT_MODE_DELETE_PORTAL, "DeletePortalButton", "删除传送门", "单击传送门删除；Ctrl+Z 撤销"],
		[LAYOUT_MODE_FOUNTAIN, "InkFountainButton", "墨泉", "左键放置固定尺寸墨泉，按在已有墨泉上拖动即可移动；右键删除；Ctrl+Z 撤销"],
	]
	for tool in layout_tools:
		var layout_button := Button.new()
		layout_button.name = str(tool[1])
		layout_button.text = str(tool[2])
		layout_button.tooltip_text = str(tool[3])
		layout_button.toggle_mode = true
		layout_button.focus_mode = Control.FOCUS_NONE
		layout_button.custom_minimum_size = Vector2(96.0, 44.0)
		if int(tool[0]) == LAYOUT_MODE_PLACE_PORTAL:
			layout_button.pressed.connect(_open_portal_menu)
		elif int(tool[0]) == LAYOUT_MODE_PLACE_CANVAS:
			layout_button.pressed.connect(_open_canvas_size_dialog)
		else:
			layout_button.pressed.connect(select_monster_tool.bind(int(tool[0])))
		layout_grid.add_child(layout_button)
		_layout_buttons[int(tool[0])] = layout_button
	_build_canvas_size_dialog(root)
	var respawn_area_button := Button.new()
	respawn_area_button.name = "RespawnAreaButton"
	respawn_area_button.text = "复活点激活区域"
	respawn_area_button.tooltip_text = "先选中橙色复活点，再设置脚底激活区的宽高和偏移；出生位置不变"
	respawn_area_button.focus_mode = Control.FOCUS_NONE
	respawn_area_button.pressed.connect(func(): action_requested.emit(&"_open_respawn_area_dialog", []))
	column.add_child(respawn_area_button)
	_portal_destination = PopupMenu.new()
	_portal_destination.name = "PortalMapMenu"
	_portal_destination.theme = EDITOR_THEME
	_portal_destination.min_size = Vector2i(300, 0)
	root.add_child(_portal_destination)
	_refresh_portal_choices()
	_portal_destination.index_pressed.connect(_on_portal_destination_selected)

	_layout_status_label = Label.new()
	_layout_status_label.name = "LayoutStatus"
	_layout_status_label.text = "出生点 1 个；复活点和画布可新增"
	_layout_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_layout_status_label)

	_monster_status_label = Label.new()
	_monster_status_label.name = "MonsterStatus"
	_monster_status_label.text = "未选中小怪"
	_monster_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_monster_status_label)

	var hint := Label.new()
	hint.text = "放置：左键单击　对话：Enter 下一句　Ctrl+Z 撤销"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(hint)
	_build_ink_quota_table(column)
	panel.visible = false


## 「关卡墨水配额」：每种墨水的满瓶量，保存进关卡根节点的 starting_ink，
## 所以只对当前地图生效。没填的颜色沿用玩家自己的 max_ink。

func _build_ink_quota_table(column: VBoxContainer) -> void:
	column.add_child(HSeparator.new())
	var title := Label.new()
	title.name = "InkQuotaTitle"
	title.text = "关卡墨水配额（本图生效）"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.theme_type_variation = &"TitleLabel"
	column.add_child(title)
	var grid := GridContainer.new()
	grid.name = "InkQuotaGrid"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 4)
	column.add_child(grid)
	for index in InkPalette.ink_count():
		var material: Resource = InkPalette.ink_at(index)
		var id: int = InkPalette.material_id_of(material)
		var label := Label.new()
		label.text = InkPalette.ink_name(index)
		label.custom_minimum_size.x = 64.0
		grid.add_child(label)
		var field := SpinBox.new()
		field.name = "InkQuota%d" % id
		# SpinBox 默认宽度只能容纳末尾的“0 px”，需留足完整配额和单位的空间。
		field.custom_minimum_size.x = 160.0
		field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		field.min_value = 0.0
		field.max_value = 200000.0
		field.step = 100.0
		field.value = ink_quota_of(id)
		field.suffix = " px"
		field.tooltip_text = "%s在本关的满瓶量；只写进当前地图，不填就沿用玩家默认值" % InkPalette.ink_name(index)
		field.value_changed.connect(_on_ink_quota_changed.bind(id))
		grid.add_child(field)
		_ink_quota_fields[id] = field
	var reset := Button.new()
	reset.name = "ResetInkQuotaButton"
	reset.text = "恢复默认配额"
	reset.tooltip_text = "清空本图的自定义配额，所有颜色回到玩家默认满瓶量"
	reset.focus_mode = Control.FOCUS_NONE
	reset.pressed.connect(reset_ink_quota)
	column.add_child(reset)


## 本关该墨水的满瓶量：地图根节点 starting_ink 里有就用自己的，没有就用玩家默认值。

func _refresh_editor_visibility() -> void:
	if _map_canvas == null:
		return
	if is_instance_valid(_editor_nail_visibility):
		_editor_nail_visibility.set_pressed_no_signal(bool(_view.get("nails_visible", true)))

func _on_brush_changed(px: int) -> void:
	_view["brush_size"] = px
	if is_instance_valid(_brush_slider):
		_brush_slider.set_value_no_signal(float(px))
	if is_instance_valid(_brush_label):
		_brush_label.text = "粗细：%d px" % px


func _on_nails_visibility_changed(show_nails: bool) -> void:
	_view["nails_visible"] = show_nails
	if is_instance_valid(_editor_nail_visibility):
		_editor_nail_visibility.set_pressed_no_signal(show_nails)


func _toggle_monster_palette_panel() -> void:
	if _monster_palette_panel == null or _monster_palette_toggle == null:
		return
	_monster_palette_panel.visible = not _monster_palette_panel.visible
	_monster_palette_toggle.text = "关闭" if _monster_palette_panel.visible else "工具\nCapslock"
	_monster_palette_toggle.tooltip_text = (
		"收起右侧地图编辑工具栏" if _monster_palette_panel.visible
		else "展开右侧地图编辑工具栏"
	)
	# 展开和收起时都固定在屏幕最右侧，不再横跨画布中央区域。
	_monster_palette_toggle.offset_left = -96.0
	_monster_palette_toggle.offset_right = -16.0

func _select_editor_ink(index: int) -> void:
	if _map_canvas != null and _map_canvas.has_method("select_ink"):
		_map_canvas.call("select_ink", index)

func _refresh_editor_ink(index: int, animate := true) -> void:
	for i in _editor_ink_buttons.size():
		var button := _editor_ink_buttons[i]
		button.set_pressed_no_signal(i == index)
		button.get_node("InkSelectionIndicator").set_selected(i == index, animate)
	if is_instance_valid(_editor_ink_label):
		_editor_ink_label.text = "当前墨水：%s" % InkPalette.ink_name(index)

func select_monster_tool(mode: int) -> void:
	action_requested.emit(&"select_monster_tool", [mode])

func select_gear_tool(teeth := 12) -> void:
	action_requested.emit(&"select_gear_tool", [teeth])

func gear_tool_button(teeth: int) -> Button:
	return _gear8_button if teeth == 8 else _gear_button

## 画布工具状态由 Creative 同步，按钮只展示，不反向抓取 Creative。
func sync_gear_buttons(gear12: bool, gear8: bool) -> void:
	if _gear_button != null:
		_gear_button.set_pressed_no_signal(gear12)
	if _gear8_button != null:
		_gear8_button.set_pressed_no_signal(gear8)

func _open_map_save_window() -> void:
	action_requested.emit(&"_open_map_save_window", [])

func _reset_selected_monster_scale() -> void:
	action_requested.emit(&"_reset_selected_monster_scale", [])

func select_infinite_nail_tool() -> void:
	action_requested.emit(&"select_infinite_nail_tool", [])

## 按钮状态由 creative 按画布当前工具回填，和齿轮按钮同一套路。
func sync_infinite_nail_button(active: bool) -> void:
	if _infinite_nail_button != null:
		_infinite_nail_button.set_pressed_no_signal(active)

func _build_canvas_size_dialog(parent: Control) -> void:
	action_requested.emit(&"_build_canvas_size_dialog", [parent])

func _refresh_portal_choices() -> void:
	action_requested.emit(&"_refresh_portal_choices", [])

func _on_portal_destination_selected(index: int) -> void:
	action_requested.emit(&"_on_portal_destination_selected", [index])

func _open_portal_menu() -> void:
	action_requested.emit(&"_open_portal_menu", [])

func _open_canvas_size_dialog() -> void:
	action_requested.emit(&"_open_canvas_size_dialog", [])

func _on_ink_quota_changed(value: float, material_id: int) -> void:
	action_requested.emit(&"_on_ink_quota_changed", [value, material_id])

func reset_ink_quota() -> void:
	action_requested.emit(&"reset_ink_quota", [])
