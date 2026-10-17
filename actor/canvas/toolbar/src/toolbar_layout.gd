extends CanvasLayer
## 两侧工具贴合连续画布整体边缘，仅横向越界时调整；高度始终跟随画布。
@export var canvas: Node2D
@export var panel: Control
const EDGE := 12.0
const FOLLOW_SPEED := 14.0
const GROUP_GAP := 96.0
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

func adopt_positions(previous: CanvasLayer) -> void:
	if previous._initialized:
		_mount.position = previous._mount.position
		_left_position = previous._left_position
		_initialized = true

func _fit(size: Vector2, viewport_size: Vector2) -> float:
	return clampf(minf((viewport_size.x - EDGE * 2.0) / maxf(size.x, 1.0),
		(viewport_size.y - 182.0 - EDGE) / maxf(size.y, 1.0)), 0.1, 1.0)

func _group_screen_bounds() -> Rect2:
	var connected: Array = [canvas]
	var candidates: Array = []
	for item in get_tree().get_nodes_in_group(&"canvas_workbench"):
		if item != canvas and item.get_parent() == canvas.get_parent() and item.active \
		and item.is_visible_in_tree() and not item._map_editor_mode and not item._screen_fixed:
			candidates.append(item)
	var index := 0
	while index < connected.size():
		var current = connected[index]
		var bounds: Rect2 = current.global_transform * Rect2(Vector2.ZERO, Vector2(current.canvas_size))
		for item in candidates:
			if not connected.has(item):
				var other: Rect2 = item.global_transform * Rect2(Vector2.ZERO, Vector2(item.canvas_size))
				if bounds.grow(GROUP_GAP).intersects(other):
					connected.append(item)
		index += 1
	var result: Rect2 = canvas.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, Vector2(canvas.canvas_size))
	for item in connected:
		result = result.merge(item.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, Vector2(item.canvas_size)))
	return result

func _horizontal_position(preferred: float, current: float, width: float, viewport_rect: Rect2, weight: float) -> float:
	var minimum := viewport_rect.position.x + EDGE
	var maximum := viewport_rect.end.x - width - EDGE
	if preferred >= minimum and preferred <= maximum:
		return preferred # 视野内直接贴边，不插值，避免相机停下后工具栏还在漂移。
	return clampf(lerpf(current, clampf(preferred, minimum, maximum), weight), minimum, maximum)

func update_layout(delta := 0.0) -> void:
	if _mount == null or not is_instance_valid(panel) or canvas._map_editor_mode or canvas._screen_fixed:
		_initialized = false
		return
	var viewport_rect := canvas.get_viewport_rect()
	var right_size := panel.get_combined_minimum_size()
	var right_fit := _fit(right_size, viewport_rect.size)
	_mount.scale = Vector2.ONE * right_fit
	right_size *= right_fit
	var bounds := _group_screen_bounds()
	var right_target := Vector2(bounds.end.x + canvas.side_panel_gap + canvas.PLAY_TOOLBAR_X_OFFSET, bounds.position.y + 2.0)
	var left_rect: Rect2 = canvas.buttons.get_rect().merge(canvas.toggle_button.get_rect())
	var left_fit := _fit(left_rect.size, viewport_rect.size)
	var left_size := left_rect.size * left_fit
	var left_target := Vector2(bounds.position.x - left_size.x - canvas.side_panel_gap, bounds.position.y + 2.0)
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
	canvas.workbench.global_transform = canvas.get_viewport().get_canvas_transform().affine_inverse() * screen_transform
