extends RefCounted
## 黑墨瓦片：把 `black_image` 切成若干贴图块，只上传改到的部分。
##
## 状态属于画布表面（一个 surface 一份）：块字典、脏矩形、内容框缓存都在这里。
## 像素源与挂载点由调用方传入——本模块只算范围、传纹理，不持有画布。
##
## 契约：改 `black_image` 之前必须先标脏（`mark` / `mark_rect`），
## 否则那部分只活在 CPU 上，画面不动。

## 块键（画布坐标 / TILE_SIZE）-> {"image", "texture", "sprite", "content", "stale"}。
var _tiles := {}
## 尚未上传的脏范围（闭区间两端）。
var _dirty_lo := Vector2i(1 << 30, 1 << 30)
var _dirty_hi := Vector2i(-(1 << 30), -(1 << 30))


## 上传脏范围覆盖到的瓦片；没碰到的块一次都不传。
func flush(surface) -> void:
	if _dirty_hi.x < _dirty_lo.x:
		return
	var rect := Rect2i(_dirty_lo, _dirty_hi - _dirty_lo + Vector2i.ONE)
	_dirty_lo = Vector2i(1 << 30, 1 << 30)
	_dirty_hi = Vector2i(-(1 << 30), -(1 << 30))
	upload_rect(surface, rect)


func mark(pixel: Vector2i) -> void:
	_dirty_lo.x = mini(_dirty_lo.x, pixel.x)
	_dirty_lo.y = mini(_dirty_lo.y, pixel.y)
	_dirty_hi.x = maxi(_dirty_hi.x, pixel.x)
	_dirty_hi.y = maxi(_dirty_hi.y, pixel.y)


func mark_rect(rect: Rect2i) -> void:
	if not rect.has_area():
		return
	mark(rect.position)
	mark(rect.end - Vector2i.ONE)


## 整张 CPU 图被换掉（读盘、撤销还原、扩展画布）之后重建瓦片：
## 旧瓦片全丢，只按真的有不透明像素的范围重建；空图因此一张贴图都不建。
func rebuild(surface) -> void:
	free_all(surface)
	var used: Rect2i = surface.black_image.get_used_rect()
	if used.has_area():
		mark_rect(used)
	flush(surface)


func free_all(surface) -> void:
	for key in _tiles:
		var sprite: Sprite2D = _tiles[key]["sprite"]
		surface.black_tiles.remove_child(sprite)
		sprite.queue_free()
	_tiles.clear()
	_dirty_lo = Vector2i(1 << 30, 1 << 30)
	_dirty_hi = Vector2i(-(1 << 30), -(1 << 30))


## rect 覆盖到的瓦片键。整图级操作（擦除、重数账本、重建钉子）都从这里出发，
## 空块再交给 `content()` 判掉 —— 这就是"分治"的粒度。
func keys(surface, rect: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var tile_size: int = surface.TILE_SIZE
	var last: Vector2i = (surface.canvas_size - Vector2i.ONE) / tile_size
	var first: Vector2i = (rect.position / tile_size).max(Vector2i.ZERO)
	var end: Vector2i = ((rect.end - Vector2i.ONE) / tile_size).min(last)
	for ty in range(first.y, end.y + 1):
		for tx in range(first.x, end.x + 1):
			out.append(Vector2i(tx, ty))
	return out


func upload_rect(surface, rect: Rect2i) -> void:
	for key in keys(surface, rect):
		_upload_tile(surface, key, rect)


## 这一块里真的有内容的范围（画布坐标）；整块空返回空矩形。
## 懒算 + 缓存：任何上传都把它置脏，下次问再重算 —— 一次原生 get_used_rect，
## 不用 GDScript 扫。整图操作因此只碰"真的有墨的那一小块"。
func content(surface, key: Vector2i) -> Rect2i:
	var tile = _tiles.get(key)
	if tile == null:
		return Rect2i()
	if not tile["stale"]:
		return tile["content"]
	var tile_size: int = surface.TILE_SIZE
	var origin := key * tile_size
	var size: Vector2i = (surface.canvas_size - origin).min(Vector2i(tile_size, tile_size))
	var box := Rect2i()
	if size.x > 0 and size.y > 0:
		var content_rect: Rect2i = surface.black_image.get_region(Rect2i(origin, size)).get_used_rect()
		if content_rect.has_area():
			box = Rect2i(origin + content_rect.position, content_rect.size)
	tile["content"] = box
	tile["stale"] = false
	return box


## 画布上所有真的有内容的块范围。整图级重数/重建按它遍历。
func content_boxes(surface) -> Array[Rect2i]:
	var boxes: Array[Rect2i] = []
	for key in keys(surface, Rect2i(Vector2i.ZERO, surface.canvas_size)):
		var box := content(surface, key)
		if box.has_area():
			boxes.append(box)
	return boxes


func _upload_tile(surface, key: Vector2i, rect: Rect2i) -> void:
	var tile_size: int = surface.TILE_SIZE
	var origin := key * tile_size
	var tile_rect := Rect2i(origin, (surface.canvas_size - origin).min(Vector2i(tile_size, tile_size)))
	var hit := rect.intersection(tile_rect)
	if not hit.has_area():
		return
	var tile = _tiles.get(key)
	if tile == null:
		var image := Image.create_empty(tile_rect.size.x, tile_rect.size.y, false, Image.FORMAT_RGBA8)
		image.fill(Color.TRANSPARENT)
		var texture := ImageTexture.create_from_image(image)
		var sprite := Sprite2D.new()
		sprite.centered = false
		sprite.position = Vector2(origin)
		sprite.texture = texture
		surface.black_tiles.add_child(sprite)
		tile = {"image": image, "texture": texture, "sprite": sprite,
			"content": Rect2i(), "stale": true}
		_tiles[key] = tile
	# blit_rect 是原样拷贝（不混合），正好把瓦片对齐到画布坐标。
	var tile_image: Image = tile["image"]
	var tile_texture: ImageTexture = tile["texture"]
	tile_image.blit_rect(surface.black_image, hit, hit.position - origin)
	tile_texture.update(tile_image)
	tile["stale"] = true          # 内容变了：这块的内容框要重算
