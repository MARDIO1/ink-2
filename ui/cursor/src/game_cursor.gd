extends CanvasLayer
## 软件指针只接管游戏窗口；不拦截 GUI 或改变绘画、选框的鼠标坐标。

const CANVAS_TEXTURE := preload("res://ui/cursor/asset/canvas_cursor.png")
const WORLD_TEXTURE := preload("res://ui/cursor/asset/world_cursor.png")
const CANVAS_HOTSPOT := Vector2(30, 30)
const WORLD_HOTSPOT := Vector2(8, 4)

## 原素材的每个像素块为 4×4；还原为逻辑像素，再随游戏窗口统一缩放。
@export_range(0.1, 2.0, 0.05) var display_scale := 0.25
@onready var pointer: TextureRect = $Pointer
var _mouse_in_window := true
var _owns_mouse := false
var _previous_mouse_mode := Input.MOUSE_MODE_VISIBLE


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 100
	get_window().mouse_entered.connect(_on_mouse_entered)
	get_window().mouse_exited.connect(_on_mouse_exited)
	get_window().focus_exited.connect(_release_mouse)
	pointer.hide()


func _exit_tree() -> void:
	_release_mouse()


func _on_mouse_entered() -> void:
	_mouse_in_window = true


func _on_mouse_exited() -> void:
	_mouse_in_window = false
	_release_mouse()


func _has_gameplay() -> bool:
	# 按组发现关卡，既支持 root 切关，也支持 F6 独立运行和旧地图。
	for player in get_tree().get_nodes_in_group(&"player"):
		if not player.is_queued_for_deletion() and player.get_viewport() == get_viewport():
			return true
	return false


func _canvas_at(screen_position: Vector2) -> Node:
	for canvas in get_tree().get_nodes_in_group(&"canvas_workbench"):
		if canvas.is_queued_for_deletion() or not canvas.active or not canvas.is_visible_in_tree():
			continue
		var surface: Node2D = canvas.get_node_or_null("CanvasSurface")
		if surface == null or surface.get_viewport() != get_viewport() or not surface.is_visible_in_tree():
			continue
		# 使用实际绘图表面的变换，兼容相机缩放、平移、多画布和编辑器大画布。
		var point := surface.get_global_transform_with_canvas().affine_inverse() * screen_position
		if surface._inside(point):
			return canvas
	return null


func _process(_delta: float) -> void:
	var screen_position := get_viewport().get_mouse_position()
	var enabled := _mouse_in_window and get_window().has_focus() and _has_gameplay()
	_refresh_cursor(screen_position, enabled, get_viewport().gui_get_hovered_control() != null)


func _refresh_cursor(screen_position: Vector2, enabled: bool, over_gui: bool) -> void:
	if not enabled or not get_viewport().get_visible_rect().has_point(screen_position):
		_release_mouse()
		return
	# 不争夺未来可能接入的锁定视角、隐藏指针模式。
	if Input.mouse_mode in [Input.MOUSE_MODE_CAPTURED, Input.MOUSE_MODE_CONFINED_HIDDEN]:
		_release_mouse()
		return
	var in_canvas := not over_gui and _canvas_at(screen_position) != null
	var texture: Texture2D = CANVAS_TEXTURE if in_canvas else WORLD_TEXTURE
	var hotspot := CANVAS_HOTSPOT if in_canvas else WORLD_HOTSPOT
	pointer.texture = texture
	pointer.size = texture.get_size() * display_scale
	pointer.position = screen_position - hotspot * display_scale
	pointer.show()
	if not _owns_mouse:
		_previous_mouse_mode = Input.mouse_mode
		_owns_mouse = true
	if Input.mouse_mode != Input.MOUSE_MODE_HIDDEN:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN


func _release_mouse() -> void:
	if is_instance_valid(pointer):
		pointer.hide()
	if _owns_mouse:
		if Input.mouse_mode == Input.MOUSE_MODE_HIDDEN:
			Input.mouse_mode = _previous_mouse_mode
		_owns_mouse = false
