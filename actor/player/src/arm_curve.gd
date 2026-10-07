extends Line2D
## 手臂：**只画不物理**的直连**虚线**（肩 = 身体质心 → 腕 = 手质心）。
##
## 老规矩：美术挂在**渲染节点**下 —— 本节点是 `Hand/Visual` 的子节点，位姿跟着手走，
## 所以 `points` 用**本节点的局部坐标**（`to_local(世界点)`），不用 top_level。
## 物理那条臂是 Hinge + Slider 里的隐形支座（`Arm` 节点，4x4、layer/mask 0），本身不画东西。
##
## 虚线是**贴图平铺**做的（Line2D 没有原生虚线）：`_ready` 生成 `dash_len` 白 +
## `gap_len` 透明的小图当 `texture`，`texture_mode = TILE`。
## ⚠️ TILE 模式下 **线的粗细 = 贴图高度**，`width` 被忽略 —— 所以这张小图必须按
##    `width` 生成高度，否则就是一条 1px 的线（肉眼等于看不见）。
## 性能：每帧两次 `com_world()` + 一次两点赋值，无查询、无分配。
##
## ⚠️ `points` 用**世界坐标**：`top_level` 在 `_ready` 里打开（父节点 `Arm` 的节点变换是静态的，
##    不打开就会跟着一个不动的原点走）。粗细 / 颜色 / 端点圆头在场景里设。

@export var body_path := NodePath("../../../..")  ## 身体（Player，持有 PBody 的节点）
@export var hand_path := NodePath("../..")        ## 手
@export var dash_len := 6.0                     ## 实线段长度（px）
@export var gap_len := 5.0                      ## 空隙长度（px）


func _ready() -> void:
	var on := maxi(1, roundi(dash_len))
	var off := maxi(1, roundi(gap_len))
	# TILE 模式：线宽 = 这张小图的高度（不是 Line2D.width）
	var thick := maxi(1, roundi(width))
	var img := Image.create_empty(on + off, thick, false, Image.FORMAT_RGBA8)
	for x in on:
		for y in thick:
			img.set_pixel(x, y, Color(1, 1, 1, 1))
	texture = ImageTexture.create_from_image(img)
	texture_mode = Line2D.LINE_TEXTURE_TILE
	# ⚠️ TILE 模式必须开重复：CanvasItem.texture_repeat 默认是 DISABLED，
	#    没开的话整条线会被 clamp 成**一个 tile 大小的方块**（看起来就是"线不见了"）。
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED


func _physics_process(_delta: float) -> void:
	var body_node := get_node_or_null(body_path)
	var hand_node := get_node_or_null(hand_path)
	if body_node == null or hand_node == null:
		return
	var body = body_node.body
	var hand = hand_node.body
	if body == null or hand == null:
		return
	var p0: Vector2 = body.com_world()
	var p3: Vector2 = hand.com_world()
	points = PackedVector2Array([to_local(p0), to_local(p3)])
