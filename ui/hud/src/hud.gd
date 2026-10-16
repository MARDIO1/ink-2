extends CanvasLayer
## 成品 HUD：瓶内液面显示玩家黑墨生命值（来源 InkHealth），顶部横条只留空框。
## Tab 在成品 HUD 与 debugHUD 之间切换。

## 退出按钮先打开 ESC 菜单，由菜单决定继续、回主菜单或退出。
const ESC_SCENE := preload("res://ui/esc/esc.tscn")
const InkPalette := preload("res://ink/general/src/ink_palette.gd")
## UI 与关卡不在同一棵子树时的兜底查找：玩家 / 调试 HUD 都按组找（场景里挂的组见
## `map/main.tscn` 的 `Player` 与 `debug/hud/debug_hud.tscn` 的根节点）。
const PLAYER_GROUP := "player"
const DEBUG_HUD_GROUP := "debug_hud"

## 接不到墨水源时瓶内液面的静态占位比例，0-1。
@export_range(0.0, 1.0, 0.01) var bar_ratio: float = 0.72
## 玩家墨水生命值节点的相对路径（本节点是 Main 的子级）。
@export var health_path: NodePath = ^"../Player/InkHealth"
## 同树时的显式路径；找不到就按组找。
@export var debug_hud_path: NodePath = ^"../debugHUD"

@onready var bottle_fill: TextureProgressBar = $Root/HealthUI/BottleFill
@onready var ink_meter: Label = $Root/HealthUI/InkMeter
var debug_hud = null
var _creative = null
var _debug_requested := false

var _health = null


func _ready() -> void:
	_bind_level()

func _process(_delta: float) -> void:
	# F2 会复载关卡，但外层 GameUI 不重建；旧的玩家/HUD 引用必须一起换掉。
	if not is_instance_valid(debug_hud) or not debug_hud.is_inside_tree():
		_bind_level()

func _bind_level() -> void:
	if is_instance_valid(_creative) and _creative.mode_changed.is_connected(_on_editor_mode_changed):
		_creative.mode_changed.disconnect(_on_editor_mode_changed)
	if is_instance_valid(_health) and _health.changed.is_connected(_refresh_ink):
		_health.changed.disconnect(_refresh_ink)
	_creative = null
	var explicit_hud := get_node_or_null(debug_hud_path)
	debug_hud = explicit_hud if explicit_hud != null else get_tree().get_first_node_in_group(DEBUG_HUD_GROUP)
	if debug_hud != null:
		debug_hud.visible = false
		debug_hud.forces.enabled = false   # 力采样默认开着：Tab 没按过就不能让它一直跑
		_creative = debug_hud.get_parent().get_node_or_null("Creative")
		if _creative != null:
			_creative.mode_changed.connect(_on_editor_mode_changed)
	_health = get_node_or_null(health_path)
	if _health == null:
		var player := get_tree().get_first_node_in_group(PLAYER_GROUP)
		_health = player.get_node_or_null("InkHealth") if player != null else null
	if _health != null:
		_health.changed.connect(_refresh_ink)
	_refresh_ink()
	if debug_hud != null:
		_on_editor_mode_changed(_creative.active if _creative != null else false)


## 瓶内液面 = 黑墨生命值。只有接不到生命值节点时才退回 bar_ratio 占位。
func _refresh_ink() -> void:
	if _health == null:
		bottle_fill.value = bar_ratio * 100.0
		ink_meter.text = "墨水 -- px"
		return
	var black_id: int = InkPalette.material_id_of(InkPalette.BLACK)
	bottle_fill.value = _health.ratio_of(black_id) * 100.0
	#只读瓶子自己的余量。画布各有各的账，屏幕上不该出现"全局已消耗"这种和画布绑在一起的概念。
	ink_meter.text = "黑墨 %d px" % int(round(_health.ink_of(black_id)))


## 走 `_input` 不走 `_unhandled_input`：画布工具按钮（`Canvas/Buttons/*`）点过之后会占住焦点，
## 那时 Godot 的 GUI 会把 Tab 当 ui_focus_next 吃掉，`_unhandled_input` 收不到。
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("debug") and not event.is_echo():
		# 编辑器保留自己的键盘焦点导航，不让 Tab 恢复力视图覆盖 F2 工具栏。
		if is_instance_valid(_creative) and _creative.active:
			return
		get_viewport().set_input_as_handled()
		_switch_debug_hud()


func _switch_debug_hud() -> void:
	if debug_hud == null:
		return
	_debug_requested = not _debug_requested
	_on_editor_mode_changed(_creative.active if _creative != null else false)

func _on_editor_mode_changed(editing: bool) -> void:
	debug_hud.visible = _debug_requested and not editing
	debug_hud.forces.enabled = debug_hud.visible
	debug_hud.forces.queue_redraw()
	visible = not debug_hud.visible


func _on_exit_button_pressed() -> void:
	var esc_menu := get_tree().get_first_node_in_group(&"esc_menu")
	if esc_menu == null:
		esc_menu = ESC_SCENE.instantiate()
		get_parent().add_child(esc_menu)
	esc_menu.open_menu()


func _on_log_button_pressed() -> void:
	var dialogue := get_tree().get_first_node_in_group(&"dialogue_box")
	if dialogue != null and dialogue.has_method("toggle_log"):
		dialogue.toggle_log()
