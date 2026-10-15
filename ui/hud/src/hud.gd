extends CanvasLayer
## 成品 HUD：瓶身显示黑墨；横条分色显示灰、红、黄、白墨的独立余额。
## Tab 在成品 HUD 与 debugHUD 之间切换。

## 退出按钮先打开 ESC 菜单，由菜单决定继续、回主菜单或退出。
const ESC_SCENE := preload("res://ui/esc/esc.tscn")
const InkPalette := preload("res://ink/src/ink_palette.gd")
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
@onready var health_bar: ProgressBar = $Root/HealthUI/HealthBar
@onready var color_ink_bar: Control = $Root/HealthUI/ColorInkBar
@onready var ink_meter: Label = $Root/HealthUI/InkMeter
var debug_hud = null

var _health = null
var _debug_enabled := false
var _bound_level: Node
var _level_router: Node


func _ready() -> void:
	_level_router = get_tree().get_first_node_in_group(&"level_router")
	if _level_router != null:
		_level_router.level_changed.connect(_bind_level)
	_bind_level(_current_level())


func _current_level() -> Node:
	if is_instance_valid(_level_router) and _level_router.level_root.get_child_count() > 0:
		return _level_router.level_root.get_child(0)
	var player := get_tree().get_first_node_in_group(PLAYER_GROUP)
	return player.get_parent() if player != null else null


## F2 会替换关卡，但成品 UI 继续复用；重新绑定调试面板与生命值信号。
func _bind_level(level: Node) -> void:
	if is_instance_valid(_health) and _health.changed.is_connected(_refresh_ink):
		_health.changed.disconnect(_refresh_ink)
	_bound_level = level
	debug_hud = level.get_node_or_null("debugHUD") if level != null else get_node_or_null(debug_hud_path)
	if debug_hud == null:
		debug_hud = get_tree().get_first_node_in_group(DEBUG_HUD_GROUP)
	_health = level.get_node_or_null("Player/InkHealth") if level != null else get_node_or_null(health_path)
	if is_instance_valid(_health):
		_health.changed.connect(_refresh_ink)
	_apply_debug_visibility()
	_refresh_ink()


func _apply_debug_visibility() -> void:
	var enabled: bool = _debug_enabled and is_instance_valid(debug_hud)
	if is_instance_valid(debug_hud):
		debug_hud.visible = enabled
		debug_hud.forces.enabled = enabled
		debug_hud.forces.queue_redraw()
	visible = not enabled


## 瓶内液面 = 黑墨生命值。只有接不到生命值节点时才退回 bar_ratio 占位。
func _refresh_ink() -> void:
	if not is_instance_valid(_health):
		bottle_fill.value = bar_ratio * 100.0
		health_bar.value = bottle_fill.value
		color_ink_bar.set_health(null)
		ink_meter.text = "墨水 -- px"
		return
	var black_id: int = InkPalette.material_id_of(InkPalette.BLACK)
	bottle_fill.value = _health.ratio_of(black_id) * 100.0
	health_bar.value = bottle_fill.value
	color_ink_bar.set_health(_health)
	#只读瓶子自己的余量。画布各有各的账，屏幕上不该出现"全局已消耗"这种和画布绑在一起的概念。
	ink_meter.text = "黑墨 %d px" % int(round(_health.ink_of(black_id)))


## 走 `_input` 不走 `_unhandled_input`：画布工具按钮（`Canvas/Buttons/*`）点过之后会占住焦点，
## 那时 Godot 的 GUI 会把 Tab 当 ui_focus_next 吃掉，`_unhandled_input` 收不到。
func _input(event: InputEvent) -> void:
	var blueprints := get_node_or_null("/root/Blueprints")
	if blueprints != null and blueprints.is_world_input_blocked():
		return
	if event.is_action_pressed("debug"):
		if _switch_debug_hud():
			get_viewport().set_input_as_handled()


func _switch_debug_hud() -> bool:
	var level := _current_level()
	if not is_instance_valid(debug_hud) or debug_hud.is_queued_for_deletion() or level != _bound_level:
		_bind_level(level)
	if not is_instance_valid(debug_hud):
		return false
	_debug_enabled = not _debug_enabled
	_apply_debug_visibility()
	return true


func _on_exit_button_pressed() -> void:
	get_node("/root/Blueprints").cancel_placement()
	var esc_menu := get_tree().get_first_node_in_group(&"esc_menu")
	if esc_menu == null:
		esc_menu = ESC_SCENE.instantiate()
		get_parent().add_child(esc_menu)
	esc_menu.open_menu()


func _on_log_button_pressed() -> void:
	get_node("/root/Blueprints").cancel_placement()
	var dialogue := get_tree().get_first_node_in_group(&"dialogue_box")
	if dialogue != null and dialogue.has_method("toggle_log"):
		dialogue.toggle_log()


func _on_blueprint_button_pressed() -> void:
	get_node("/root/Blueprints").open_library()
