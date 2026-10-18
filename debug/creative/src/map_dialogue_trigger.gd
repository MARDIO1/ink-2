@tool
class_name MapDialogueTrigger
extends Node2D

## 地图对话触发点：编辑模式显示 100×100 像素预览，游玩时隐藏并检测玩家进入。

const TRIGGER_SIZE := Vector2(100.0, 100.0)
const GROUP := &"map_dialogue_trigger"

@export var lines: PackedStringArray = PackedStringArray()
@export var editor_id := ""

var _player_was_inside := false
var _editor_visible := false
var _triggered := false


func _ready() -> void:
	add_to_group(GROUP)
	visible = false
	set_process(true)
	set_physics_process(not Engine.is_editor_hint())
	_refresh_editor_visibility()


func _process(_delta: float) -> void:
	_refresh_editor_visibility()


func _physics_process(_delta: float) -> void:
	if _is_map_editor_active():
		_player_was_inside = false
		return
	if _triggered:
		return
	var player := _find_player()
	var body = player.get("body") if player != null else null
	if body == null:
		return
	var inside := trigger_rect().intersects(body.aabb)
	if inside and not _player_was_inside:
		# UI 比关卡晚一帧装配；没找到对话框或已有对话播放时保持未触发，后续帧重试。
		if _start_dialogue():
			_player_was_inside = true
	elif not inside:
		_player_was_inside = false


func trigger_rect() -> Rect2:
	return Rect2(global_position - TRIGGER_SIZE * 0.5, TRIGGER_SIZE)


func _start_dialogue() -> bool:
	if _triggered or lines.is_empty():
		return false
	var dialogue := get_tree().get_first_node_in_group(&"dialogue_box")
	if dialogue == null or not dialogue.has_method("start_dialogue"):
		return false
	var dialogue_root: Control = dialogue.get("root")
	if dialogue_root != null and dialogue_root.visible:
		return false
	dialogue.start_dialogue(lines)
	_triggered = true
	return true


func _find_player() -> Node:
	var level := get_parent()
	if level != null and level.name == "DialogueTriggers":
		level = level.get_parent()
	return level.get_node_or_null("Player") if level != null else null


func _is_map_editor_active() -> bool:
	if Engine.is_editor_hint():
		return true
	var level := get_parent()
	if level != null and level.name == "DialogueTriggers":
		level = level.get_parent()
	var creative := level.get_node_or_null("Creative") if level != null else null
	return creative != null and creative.get("active") == true


func _refresh_editor_visibility() -> void:
	var next_visible := _is_map_editor_active()
	_editor_visible = next_visible
	# 不能只在状态变化时赋值：快照/父节点会直接把 visible 写成 false，
	# 而 _editor_visible 仍是 true，之后就会一直看不到对话点。
	visible = next_visible
	if next_visible:
		var container := get_parent()
		if container is CanvasItem:
			container.visible = true
		queue_redraw()


func _draw() -> void:
	if not _editor_visible:
		return
	var rect := Rect2(-TRIGGER_SIZE * 0.5, TRIGGER_SIZE)
	draw_rect(rect, Color(0.95, 0.75, 0.12, 0.22), true)
	draw_rect(rect, Color(0.08, 0.06, 0.02, 0.95), false, 3.0)
	draw_line(Vector2(-12, 0), Vector2(12, 0), Color.BLACK, 2.0)
	draw_line(Vector2(0, -12), Vector2(0, 12), Color.BLACK, 2.0)
