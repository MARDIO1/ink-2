extends RefCounted
## 运行时解码 GIF89a/GIF87a；返回已经按 disposal 合成的完整 RGBA 帧。

const MAX_SIDE := 2048
const MAX_FRAMES := 180
const MAX_TOTAL_PIXELS := 64000000


static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 13 or not ["GIF87a", "GIF89a"].has(bytes.slice(0, 6).get_string_from_ascii()):
		return {"error": "不是有效的 GIF 图片"}
	var width := _u16(bytes, 6)
	var height := _u16(bytes, 8)
	if width < 1 or height < 1 or width > MAX_SIDE or height > MAX_SIDE:
		return {"error": "GIF 尺寸超出支持范围（最大 2048 × 2048）"}
	var cursor := 13
	var global_palette := PackedByteArray()
	if bytes[10] & 0x80:
		var count := 1 << ((bytes[10] & 7) + 1)
		if cursor + count * 3 > bytes.size():
			return {"error": "GIF 调色板不完整"}
		global_palette = bytes.slice(cursor, cursor + count * 3)
		cursor += count * 3
	var canvas := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	canvas.fill(Color.TRANSPARENT)
	var frames: Array[Image] = []
	var delays := PackedFloat32Array()
	var transparent_index := -1
	var delay := 0.1
	var disposal := 0
	var previous_disposal := 0
	var previous_rect := Rect2i()
	var previous_canvas: Image = null
	while cursor < bytes.size():
		var block := int(bytes[cursor])
		cursor += 1
		if block == 0x3b:
			break
		if block == 0x21:
			if cursor >= bytes.size():
				return {"error": "GIF 扩展块不完整"}
			var extension := int(bytes[cursor])
			cursor += 1
			if extension == 0xf9:
				if cursor + 6 > bytes.size() or bytes[cursor] != 4:
					return {"error": "GIF 动画控制块不完整"}
				var flags := int(bytes[cursor + 1])
				disposal = (flags >> 2) & 7
				delay = maxf(0.02, float(_u16(bytes, cursor + 2)) * 0.01)
				transparent_index = int(bytes[cursor + 4]) if flags & 1 else -1
				cursor += 6
				continue
			var skip_cursor := [cursor]
			_subblocks(bytes, skip_cursor)
			cursor = skip_cursor[0]
			continue
		if block != 0x2c or cursor + 9 > bytes.size():
			return {"error": "GIF 图像块损坏"}
		if previous_disposal == 2:
			canvas.fill_rect(previous_rect, Color.TRANSPARENT)
		elif previous_disposal == 3 and previous_canvas != null:
			canvas = previous_canvas
		var left := _u16(bytes, cursor)
		var top := _u16(bytes, cursor + 2)
		var frame_width := _u16(bytes, cursor + 4)
		var frame_height := _u16(bytes, cursor + 6)
		var flags := int(bytes[cursor + 8])
		cursor += 9
		if frame_width < 1 or frame_height < 1 or left + frame_width > width or top + frame_height > height:
			return {"error": "GIF 帧超出画布"}
		var palette := global_palette
		if flags & 0x80:
			var count := 1 << ((flags & 7) + 1)
			if cursor + count * 3 > bytes.size():
				return {"error": "GIF 帧调色板不完整"}
			palette = bytes.slice(cursor, cursor + count * 3)
			cursor += count * 3
		if palette.is_empty() or cursor >= bytes.size():
			return {"error": "GIF 缺少帧数据"}
		var minimum_code_size := int(bytes[cursor])
		cursor += 1
		var position := [cursor]
		var compressed := _subblocks(bytes, position)
		cursor = position[0]
		var indices := _lzw(compressed, minimum_code_size, frame_width * frame_height)
		if indices.size() != frame_width * frame_height:
			return {"error": "GIF 帧解压失败"}
		var before: Image = canvas.duplicate() if disposal == 3 else null
		var row_order: Array[int] = []
		if flags & 0x40:
			for pass_data in [[0, 8], [4, 8], [2, 4], [1, 2]]:
				for y in range(pass_data[0], frame_height, pass_data[1]):
					row_order.append(y)
		else:
			for y in frame_height:
				row_order.append(y)
		for row in frame_height:
			for x in frame_width:
				var index := int(indices[row * frame_width + x])
				if index == transparent_index:
					continue
				var palette_offset := index * 3
				if palette_offset + 2 >= palette.size():
					return {"error": "GIF 调色板索引错误"}
				canvas.set_pixel(left + x, top + row_order[row], Color8(
					palette[palette_offset], palette[palette_offset + 1], palette[palette_offset + 2], 255))
		frames.append(canvas.duplicate())
		delays.append(delay)
		if frames.size() > MAX_FRAMES or frames.size() * width * height > MAX_TOTAL_PIXELS:
			return {"error": "GIF 帧数或总像素过多"}
		previous_disposal = disposal
		previous_rect = Rect2i(left, top, frame_width, frame_height)
		previous_canvas = before
		transparent_index = -1
		delay = 0.1
		disposal = 0
	if frames.is_empty():
		return {"error": "GIF 没有可显示的帧"}
	return {"frames": frames, "delays": delays}


static func _u16(bytes: PackedByteArray, offset: int) -> int:
	return int(bytes[offset]) | (int(bytes[offset + 1]) << 8)


static func _subblocks(bytes: PackedByteArray, position: Array) -> PackedByteArray:
	var data := PackedByteArray()
	var cursor: int = position[0]
	while cursor < bytes.size():
		var size := int(bytes[cursor])
		cursor += 1
		if size == 0:
			break
		if cursor + size > bytes.size():
			position[0] = bytes.size()
			return PackedByteArray()
		data.append_array(bytes.slice(cursor, cursor + size))
		cursor += size
	position[0] = cursor
	return data


static func _lzw(data: PackedByteArray, minimum: int, expected: int) -> PackedByteArray:
	if minimum < 2 or minimum > 8:
		return PackedByteArray()
	var clear_code := 1 << minimum
	var end_code := clear_code + 1
	var next_code := end_code + 1
	var code_size := minimum + 1
	var prefixes := PackedInt32Array()
	var suffixes := PackedByteArray()
	previous_code_reset(prefixes, suffixes)
	var bit_offset := 0
	var previous := -1
	var result := PackedByteArray()
	while bit_offset + code_size <= data.size() * 8 and result.size() < expected:
		var code := 0
		for bit in code_size:
			if data[(bit_offset + bit) >> 3] & (1 << ((bit_offset + bit) & 7)):
				code |= 1 << bit
		bit_offset += code_size
		if code == clear_code:
			next_code = end_code + 1
			code_size = minimum + 1
			previous = -1
			continue
		if code == end_code or code > next_code:
			break
		var chain: Array[int] = []
		var cursor := code if code < next_code else previous
		if cursor < 0:
			break
		while cursor >= clear_code and cursor < next_code:
			chain.append(suffixes[cursor])
			cursor = prefixes[cursor]
			if chain.size() > 4096:
				return PackedByteArray()
		if cursor >= clear_code:
			return PackedByteArray()
		chain.append(cursor)
		var first := chain[-1]
		for index in range(chain.size() - 1, -1, -1):
			result.append(chain[index])
		if code == next_code:
			result.append(first)
		if previous >= 0 and next_code < 4096:
			prefixes[next_code] = previous
			suffixes[next_code] = first
			next_code += 1
			if next_code == 1 << code_size and code_size < 12:
				code_size += 1
		previous = code
	return result


static func previous_code_reset(prefixes: PackedInt32Array, suffixes: PackedByteArray) -> void:
	prefixes.resize(4096)
	suffixes.resize(4096)
