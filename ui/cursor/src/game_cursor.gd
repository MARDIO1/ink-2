extends CanvasLayer
## 软件指针只接管游戏窗口；不拦截 GUI 或改变绘画、选框的鼠标坐标。

const CANVAS_TEXTURE := preload("res://ui/cursor/asset/canvas_cursor.png")
const LARGE_CANVAS_TEXTURE := preload("res://ui/cursor/asset/canvas_cursor_large.png")
const WORLD_TEXTURE := preload("res://ui/cursor/asset/world_cursor.png")
const CANVAS_HOTSPOT := Vector2(20, 20)
const WORLD_HOTSPOT := Vector2(8, 4)
const Tool := preload("res://actor/canvas/src/canvas_surface.gd").Tool
## 40×40 素材的可见轮廓占 32×32，其余为透明留边。
const RING_DIAMETER := 32.0
const LARGE_RING_DIAMETER := 52.0
const LARGE_CANVAS_HOTSPOT := Vector2(30, 30)

## 原素材的每个像素块为 4×4；还原为逻辑像素，再随游戏窗口统一缩放。
@export_range(0.1, 2.0, 0.05) var display_scale := 0.25
## 逻辑屏幕像素；极细笔触、镜头缩远时也不让圆环缩成不可见的点。
@export_range(8.0, 32.0, 1.0) var minimum_ring_diameter := 10.0
@onready var pointer: TextureRect = $Pointer
var _mouse_in_window := true
var _owns_mouse := false
var _previous_mouse_mode := Input.MOUSE_MODE_VISIBLE


func _ready() -> void:
	var contrast := ShaderMaterial.new()
	contrast.shader = preload("res://ui/cursor/src/invert_cursor.gdshader")
	pointer.material = contrast
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
	# 切屏期间主线程会被场景实例化/物理烘焙长时间占住，软件指针只能跟着卡。
	# 这段时间交还给系统指针：它在操作系统层绘制，游戏掉帧时依然能动。
	var transition := get_node_or_null("/root/SceneTransition")
	if transition != null and transition.get("busy") == true:
		_release_mouse()
		return
	var screen_position := get_viewport().get_mouse_position()
	var enabled := _mouse_in_window and get_window().has_focus() and _has_gameplay()
	_refresh_cursor(screen_position, enabled, get_viewport().gui_get_hovered_control() != null)


func _ring_scale(canvas: Node) -> Vector2:
	var surface: Node2D = canvas.get_node("CanvasSurface")
	var transform := surface.get_global_transform_with_canvas()
	var diameter := float(maxi(1, surface.brush_size))
	var image_diameter := LARGE_RING_DIAMETER if surface.brush_size > 10 else RING_DIAMETER
	return Vector2(maxf(minimum_ring_diameter, diameter * transform.x.length()),
		maxf(minimum_ring_diameter, diameter * transform.y.length())) / image_diameter


func _uses_ring(canvas: Node) -> bool:
	var surface: Node = canvas.get_node("CanvasSurface")
	if surface.tool in [Tool.NAIL, Tool.GEAR, Tool.GEAR_8]:
		return false
	var creative := canvas.get_parent().get_node_or_null("Creative")
	if creative != null and creative.get("active") == true:
		if creative._monster_mode != creative.MONSTER_MODE_NONE \
		or creative._dragging_monster or creative._layout_drag_target != null:
			return false
	# 蓝图幽灵也是部件放置，不能误表现成画笔。
	var blueprints := get_node_or_null("/root/Blueprints")
	return blueprints == null or not blueprints.placing


func _refresh_cursor(screen_position: Vector2, enabled: bool, over_gui: bool) -> void:
	if not enabled or not get_viewport().get_visible_rect().has_point(screen_position):
		_release_mouse()
		return
	# 不争夺未来可能接入的锁定视角、隐藏指针模式。
	if Input.mouse_mode in [Input.MOUSE_MODE_CAPTURED, Input.MOUSE_MODE_CONFINED_HIDDEN]:
		_release_mouse()
		return
	var canvas: Node = null if over_gui else _canvas_at(screen_position)
	var in_canvas := canvas != null and _uses_ring(canvas)
	var texture: Texture2D = CANVAS_TEXTURE if in_canvas else WORLD_TEXTURE
	var hotspot := CANVAS_HOTSPOT if in_canvas else WORLD_HOTSPOT
	if in_canvas and canvas.get_node("CanvasSurface").brush_size > 10:
		texture = LARGE_CANVAS_TEXTURE
		hotspot = LARGE_CANVAS_HOTSPOT
	var texture_scale := _ring_scale(canvas) if in_canvas else Vector2.ONE * display_scale
	var rotation: float = canvas.get_node("CanvasSurface").get_global_transform_with_canvas().get_rotation() if in_canvas else 0.0
	pointer.texture = texture
	pointer.size = texture.get_size() * texture_scale
	pointer.rotation = rotation
	pointer.position = screen_position - (hotspot * texture_scale).rotated(rotation)
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
