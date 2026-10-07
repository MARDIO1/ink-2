@tool
extends Sprite2D
## 美术层：**只画不物理**。挂在刚体的渲染节点下（`Visual` 的子节点），位姿自动跟着刚体走 ——
## 物理那一层由刚体的**直接子形状**负责，两个子系统互不认识，谁也不用改谁。
##
## `image` 的 R 通道 = 材质 id（和 `tools/bake_art.gd` 的产物同格式），颜色从 `palette` 查；
## `palette` 留空就用像素世界的调色板（和物理层同源，见 PixelWorld.palette_for_render）。
##
## ⚠️ 每次重建都**新建** ImageTexture、不调 `update()` —— update() 要求宽高和格式逐格一致，
##    换图时尺寸一变就会报错并静默留旧图。新建就没这条限制，美术图想多大就多大。
@export var image: Image:
	set(v):
		image = v
		rebuild()
@export var palette: Array[Color] = []
## >0 时把"被线稿围住的透明格"填成这个材质（白底之类）。0 = 不填。
@export var fill_material := 0


func _ready() -> void:
	centered = false
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rebuild()


func rebuild() -> void:
	if image == null:
		texture = null
		return
	var pal: Array = palette
	if pal.is_empty():
		pal = _world_palette()
	var w := image.get_width()
	var h := image.get_height()
	var out := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	var inside := _interior(w, h) if fill_material > 0 else PackedByteArray()
	for y in h:
		for x in w:
			var mi := int(round(image.get_pixel(x, y).r * 255.0))
			if mi == 0 and inside.size() > 0 and inside[y * w + x] == 0:
				mi = fill_material  # 线稿围住的空心 = 白底
			if mi > 0 and mi < pal.size():
				out.set_pixel(x, y, pal[mi])
	texture = ImageTexture.create_from_image(out)


## 从四边界泛洪透明格 -> 标记"外面"；没被标到的透明格就是**内部**。
## （和 bottled_ink.gd 算瓶内遮罩同一套判据；PackedArray 是值类型，所以这里全部内联、不抽函数。）
func _interior(w: int, h: int) -> PackedByteArray:
	var outside := PackedByteArray()
	outside.resize(w * h)
	var stack := PackedInt32Array()
	for x in w:
		for y in [0, h - 1]:
			if outside[y * w + x] == 0 and int(round(image.get_pixel(x, y).r * 255.0)) == 0:
				outside[y * w + x] = 1
				stack.append(y * w + x)
	for y in h:
		for x in [0, w - 1]:
			if outside[y * w + x] == 0 and int(round(image.get_pixel(x, y).r * 255.0)) == 0:
				outside[y * w + x] = 1
				stack.append(y * w + x)
	while not stack.is_empty():
		var c: int = stack[stack.size() - 1]
		stack.remove_at(stack.size() - 1)
		var cx: int = c % w
		var cy: int = c / w
		for nb in [Vector2i(cx + 1, cy), Vector2i(cx - 1, cy), Vector2i(cx, cy + 1), Vector2i(cx, cy - 1)]:
			if nb.x < 0 or nb.y < 0 or nb.x >= w or nb.y >= h:
				continue
			var i: int = nb.y * w + nb.x
			if outside[i] == 1 or int(round(image.get_pixel(nb.x, nb.y).r * 255.0)) != 0:
				continue
			outside[i] = 1
			stack.append(i)
	return outside


func _world_palette() -> Array:
	var n: Node = get_parent()
	while n != null:
		if n.has_method("palette_for_render"):
			return n.palette_for_render()
		n = n.get_parent()
	return []
