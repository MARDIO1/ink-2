extends Node2D
## 维修区的断电开关，只切换真实固定导线，不移动或驱动平台。
@export var feed_path: NodePath
var powered := true
var button: Button

func _ready() -> void:
	button = Button.new()
	button.size = Vector2(112,30)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size",16)
	button.add_theme_color_override("font_color",Color.BLACK)
	var paper := StyleBoxFlat.new()
	paper.bg_color = Color("eeeadd")
	paper.set_border_width_all(2)
	paper.border_color = Color.BLACK
	button.add_theme_stylebox_override("normal",paper)
	add_child(button)
	button.text = "断电召回"
	button.pressed.connect(_toggle)
	z_index = 100

func _toggle() -> void:
	var feed = get_node_or_null(feed_path)
	if feed == null: return
	powered = not powered
	feed.active = powered
	button.text = "断电召回" if powered else "恢复供电"
