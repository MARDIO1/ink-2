extends RefCounted
## 体素的世界尺寸 —— "大块像素"就是靠这个。
##
## 逻辑世界（物理、破坏、笔刷、质量）全部以**体素**为单位，永远不变。
## 这个值只决定"一个体素在屏幕上占多大"，以及渲染贴图放大多少倍。
## 好处是改观感不会牵动物理参数（重力、速度、质量都不受影响）。
##
##   1  -> 一个体素 = 1 世界单位（细腻，接近传统像素画）
##   3  -> 一个体素渲染成 3x3 屏幕像素（粗块，接近 Teardown 的观感）
##
## 运行时可以随时改（Demo 里用 - / = 键），渲染层会立刻跟上。

const MIN_SCALE := 1.0
const MAX_SCALE := 32.0

static var voxel_world_size := 3.0

static func set_scale(v: float) -> void:
	voxel_world_size = clampf(v, MIN_SCALE, MAX_SCALE)

static func get_scale() -> float:
	return voxel_world_size


## 显示分辨率相对基准（960x540）的倍数。
##
## ⚠️ 这个值**不改变体素尺寸**，只影响"一个体素画到多少个真实像素上"。
## 相机 zoom 乘上它，取景就完全不变 —— 提高分辨率只是让旋转碎块的边缘
## 有更多采样点可用（配合 MSAA），而不是把画面放大。
const BASE_HEIGHT := 540.0

## ⚠️⚠️ 取的是**相机所在视口**的大小，不是窗口大小。
##
##    像素风的常规做法是"小视口渲染 -> 放大贴到屏幕上"（相机挂在 SubViewport 里）。
##    这时窗口可能是 1080p，而相机实际渲染的视口只有 540p —— 拿窗口高度算，
##    取景会直接差一倍（"提高分辨率把画面放大了"那种症状）。
##    传 null 时退回主视口（工具脚本 / 没有相机的场合）。
static func render_scale(camera: Camera2D = null) -> float:
	var h := 0.0
	var vp: Viewport = null
	if camera != null:
		vp = camera.get_viewport()
	if vp == null:
		var st := Engine.get_main_loop() as SceneTree
		if st != null:
			vp = st.root
	if vp != null:
		h = float(vp.get_visible_rect().size.y)
	if h <= 0.0:
		h = BASE_HEIGHT
	return h / BASE_HEIGHT
