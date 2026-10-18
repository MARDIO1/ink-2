extends RefCounted
## 只缓存蓝图编译输入，不持有游玩刚体。按内容寻址，修改一个连通块不影响其他块。
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Chunk := preload("res://addons/pixel_destruction/core/pixel_chunk.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")
const LIMIT := 32 * 1024 * 1024
static var _entries: Dictionary = {}
static var _bytes := 0
static var hits := 0

static func clear() -> void:
	_entries.clear()
	_bytes = 0
	hits = 0

static func key_of(shape) -> String:
	var keys: Array = shape.chunks.keys()
	keys.sort()
	var values: Array = []
	for key in keys:
		var chunk = shape.chunks[key]
		values.append([key, chunk.occ, chunk.mat, chunk.aux])
	return digest_of(var_to_bytes(values))

static func digest_of(bytes: PackedByteArray) -> String:
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(bytes)
	return digest.finish().hex_encode()

static func yellow_shape(image: Image):
	var bytes := image.get_data()
	var key := "yellow:" + str(image.get_size()) + digest_of(bytes)
	if _entries.has(key):
		hits += 1
		return clone_shape(_entries[key].value)
	var shape = Shape.new()
	var rect := image.get_used_rect()
	var width := image.get_width()
	var last_key := -1
	var chunk = null
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if bytes[(y * width + x) * 4 + 3] == 0:
				continue
			var chunk_key: int = Shape.make_key(x >> 3, y >> 3)
			if chunk_key != last_key:
				last_key = chunk_key
				chunk = shape.chunks.get(chunk_key)
				if chunk == null:
					chunk = Chunk.new()
					shape.chunks[chunk_key] = chunk
			var bit: int = (x & 7) + ((y & 7) << 3)
			chunk.occ |= 1 << bit
			chunk.mat[bit] = Palette.YELLOW.id
	store(key, clone_shape(shape), shape.chunks.size() * 256)
	return shape

static func clone_shape(source):
	var copy = Shape.new()
	for key in source.chunks:
		# Chunk.clone 同时复制材质和辅助数组，避免试玩破坏污染缓存。
		copy.chunks[key] = source.chunks[key].clone()
	return copy

static func store(key: String, value: Variant, size: int) -> void:
	if size > LIMIT:
		return
	# 有界 FIFO；缓存跨 F2 场景实例保留，但不会无限累积历史地图。
	while not _entries.is_empty() and _bytes + size > LIMIT:
		var oldest: String = _entries.keys()[0]
		_bytes -= int(_entries[oldest].bytes)
		_entries.erase(oldest)
	_entries[key] = {"value": value, "bytes": size}
	_bytes += size

static func lookup(key: String) -> Variant:
	if not _entries.has(key):
		return null
	hits += 1
	return _entries[key].value

static func material_image(shape, rect: Rect2i) -> Image:
	var key := "paint:" + key_of(shape)
	if _entries.has(key):
		hits += 1
		return Image.create_from_data(rect.size.x, rect.size.y, false, Image.FORMAT_R8, _entries[key].value)
	var bytes := PackedByteArray()
	bytes.resize(rect.size.x * rect.size.y)
	for y in rect.size.y:
		for x in rect.size.x:
			bytes[y * rect.size.x + x] = shape.get_pixel(rect.position.x + x, rect.position.y + y)
	store(key, bytes, bytes.size())
	return Image.create_from_data(rect.size.x, rect.size.y, false, Image.FORMAT_R8, bytes)
