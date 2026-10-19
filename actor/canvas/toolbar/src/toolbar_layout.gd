extends CanvasLayer
## 工具栏固定贴在当前画布左右两侧；仅横向越界时调整，不做上下避让。
@export var canvas: Node2D
@export var panel: Control
const EDGE := 12.0
const FOLLOW_SPEED := 14.0
var _mount: Node2D
var _left_position := Vector2.ZERO
var _initialized := false

func _ready() -> void:
	if canvas == null or panel == null:
		set_process(false)
		return
	layer = 2
	_mount = Node2D.new()
	_mount.name = "Mount"
	add_child(_mount)
	panel.reparent(_mount, false)
	process_priority = 100
	update_layout()

func _process(delta: float) -> void:
	visible = canvas.is_visible_in_tree()
	update_layout(delta)

func sync_mount_parent() -> void:
	if _mount == null:
		return
	var target: Node = self if canvas._screen_fixed else canvas.get_node("ToolbarLayer")
	if _mount.get_parent() != target:
		_mount.reparent(target, false)

func adopt_positions(previous: CanvasLayer) -> void:
	if previous._initialized:
		_mount.position = previous._mount.position
		_left_position = previous._left_position
		_initialized = true

func _fit(size: Vector2, viewport_size: Vector2) -> float:
	return clampf(minf((viewport_size.x - EDGE * 2.0) / maxf(size.x, 1.0),
		(viewport_size.y - 182.0 - EDGE) / maxf(size.y, 1.0)), 0.1, 1.0)

func _canvas_screen_bounds() -> Rect2:
	# 归属由画布的靠近/交接逻辑决定；附近其他画布不扩张当前工具栏的定位范围。
	return canvas.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, Vector2(canvas.canvas_size))

func _horizontal_position(preferred: float, current: float, width: float, viewport_rect: Rect2, weight: float) -> float:
	var minimum := viewport_rect.position.x + EDGE
	var maximum := viewport_rect.end.x - width - EDGE
	if preferred >= minimum and preferred <= maximum:
		return preferred # 视野内直接贴边，不插值，避免相机停下后工具栏还在漂移。
	return clampf(lerpf(current, clampf(preferred, minimum, maximum), weight), minimum, maximum)

func update_layout(delta := 0.0) -> void:
	if _mount == null or not is_instance_valid(panel):
		return
	sync_mount_parent()
	canvas._sync_play_toolbar_transform()
	if canvas._map_editor_mode or canvas._screen_fixed:
		_initialized = false
		return
	var viewport_rect := canvas.get_viewport_rect()
	var right_size := panel.get_combined_minimum_size()
	var right_fit := _fit(right_size, viewport_rect.size)
	_mount.scale = Vector2.ONE * right_fit
	right_size *= right_fit
	var bounds := _canvas_screen_bounds()
	var canvas_transform := canvas.get_global_transform_with_canvas()
	var frame_padding := 14.0 * (absf(canvas_transform.x.x) + absf(canvas_transform.y.x))
	# 画框随相机放大，工具栏间距也要让出画框和纸色底板的边缘。
	var gap := maxf(canvas.side_panel_gap, frame_padding + 18.0)
	var right_target := Vector2(bounds.end.x + gap + canvas.PLAY_TOOLBAR_X_OFFSET, bounds.position.y + 2.0)
	var left_rect: Rect2 = canvas.buttons.get_rect().merge(canvas.toggle_button.get_rect())
	var left_fit := _fit(left_rect.size, viewport_rect.size)
	var left_size := left_rect.size * left_fit
	var left_target := Vector2(bounds.position.x - left_size.x - gap,
		bounds.position.y + 2.0)
	# 左右共用画布顶部锚点，屏幕上下边界不改变工具栏相对画布的高度。
	var immediate: bool = not _initialized or canvas.toolbar_transition_seconds <= 0.0
	var weight := 1.0 if immediate else 1.0 - exp(-FOLLOW_SPEED * delta)
	_mount.position = Vector2(_horizontal_position(right_target.x, _mount.position.x, right_size.x, viewport_rect, weight), right_target.y)
	_left_position = Vector2(_horizontal_position(left_target.x, _left_position.x, left_size.x, viewport_rect, weight), left_target.y)
	_initialized = true
	if Rect2(_left_position, left_size).grow(8).intersects(Rect2(_mount.position, right_size)):
		_left_position.x = maxf(EDGE, _mount.position.x - left_size.x - 18.0)
	panel.position = Vector2.ZERO
	var screen_transform := Transform2D(0.0, Vector2.ONE * left_fit, 0.0,
		_left_position - left_rect.position * left_fit)
	# 共同挂点负责抵消相机变换，控件继续使用屏幕坐标。
	canvas.workbench.transform = screen_transform
