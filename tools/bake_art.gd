extends RefCounted
## 把像素画源图烘成运行时读的「材质图」.tres。
##
## 源图 16px 一格，一格 = 一个游戏像素，不做额外缩放。输出是 FORMAT_R8 的
## Image，**R 通道 = 材质 id**，见 addons/pixel_destruction/nodes/pixel_shape_2d.gd
## 的 source=PAINT。
##
## 每个 4 邻接连通块必须单独出一个 .tres：PWorld.add_body() 会把不连通的形状
## 拆成独立刚体，多块塞进一张图角色会散架。画布侧同一原因见
## actor/canvas/src/canvas_solid.gd。
##
## CLI: godot --headless --path . --script res://tools/bake_cli.gd
## GUI: 编辑器里打开 res://tools/bake_editor.tscn

#region 配置
## 源图是 16px 一格的像素画：一格 = 一个游戏像素，不做额外缩放。
const CELL := 16
const DIR := "res://actor/player/asset/"
## [源图, 输出前缀, 材质 id, 顺时针转90]
const SOURCES := [
	["player_body.png", "player_body", 2, false],
	["player_hand_unfold.png", "player_hand_unfold", 3, true],
]
#endregion


#region 取样
## 每格取左上角 1 点。返回 {} 表示失败（已 push_error）。
## { image, origin, w, h, solid, count }
func analyse(file_name: String, cell: int, turn: bool) -> Dictionary:
	var path := DIR + file_name
	var sheet: Image = Image.load_from_file(ProjectSettings.globalize_path(path))
	if sheet == null or sheet.is_empty():
		push_error("烘焙：读不到 " + path)
		return {}
	sheet.convert(Image.FORMAT_RGBA8)
	if turn:
		sheet.rotate_90(CLOCKWISE)
	var box: Rect2i = sheet.get_used_rect()
	if box.size.x < cell or box.size.y < cell:
		push_error("烘焙：" + path + " 没有不透明像素")
		return {}
	var w: int = box.size.x / cell
	var h: int = box.size.y / cell
	var solid := PackedByteArray()
	solid.resize(w * h)
	var count := 0
	for cy: int in h:
		for cx: int in w:
			if sheet.get_pixel(box.position.x + cx * cell, box.position.y + cy * cell).a > 0.0:
				solid[cy * w + cx] = 1
				count += 1
	return {"image": sheet, "origin": box.position, "w": w, "h": h, "solid": solid, "count": count}
#endregion


#region 连通块
## 4 邻接连通块，按格数从大到小。
func components(solid: PackedByteArray, w: int, h: int) -> Array:
	var seen := PackedByteArray()
	seen.resize(w * h)
	var out: Array = []
	for start: int in w * h:
		if solid[start] == 0 or seen[start] == 1:
			continue
		var cells := PackedInt32Array()
		var stack := PackedInt32Array([start])
		seen[start] = 1
		while not stack.is_empty():
			var c := stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			cells.append(c)
			var cx := c % w
			var cy := c / w
			if cx + 1 < w:
				push_cell(seen, stack, solid, c + 1)
			if cx > 0:
				push_cell(seen, stack, solid, c - 1)
			if cy + 1 < h:
				push_cell(seen, stack, solid, c + w)
			if cy > 0:
				push_cell(seen, stack, solid, c - w)
		out.append(cells)
	out.sort_custom(func(a, b): return a.size() > b.size())
	return out


func push_cell(seen: PackedByteArray, stack: PackedInt32Array, solid: PackedByteArray, c: int) -> void:
	if solid[c] == 1 and seen[c] == 0:
		seen[c] = 1
		stack.append(c)


## 每块在网格里的 bbox，顺序与 parts 一致。
func boxes(parts: Array, w: int) -> Array:
	var out: Array = []
	for cells: PackedInt32Array in parts:
		var x0 := 1 << 30
		var y0 := 1 << 30
		var x1 := -1
		var y1 := -1
		for c: int in cells:
			var cx := c % w
			var cy := c / w
			x0 = mini(x0, cx)
			y0 = mini(y0, cy)
			x1 = maxi(x1, cx)
			y1 = maxi(y1, cy)
		out.append(Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1))
	return out
#endregion


#region 写盘
## 每块一张 .tres，返回每块信息 {name, cell, size, pixels, save}。
## scale 把 1 格放大成 scale×scale 格：无损，但质量 ×scale²，
## 且 tscn 里的 position 必须同步 ×scale。
func write(prefix: String, material: int, w: int, parts: Array, bounds: Array, scale: int) -> Array:
	var value := float(material) / 255.0
	var info: Array = []
	for i: int in parts.size():
		var cells: PackedInt32Array = parts[i]
		var bound: Rect2i = bounds[i]
		var out := Image.create_empty(bound.size.x * scale, bound.size.y * scale, false, Image.FORMAT_R8)
		for c: int in cells:
			var bx := (c % w - bound.position.x) * scale
			var by := (c / w - bound.position.y) * scale
			for dy: int in scale:
				for dx: int in scale:
					out.set_pixel(bx + dx, by + dy, Color(value, 0.0, 0.0, 1.0))
		var name := "%s_%d.tres" % [prefix, i]
		var err := ResourceSaver.save(out, DIR + name)
		info.append({
			"name": name,
			"cell": bound.position * scale,
			"size": out.get_size(),
			"pixels": cells.size() * scale * scale,
			"save": err,
		})
	return info


## 删掉上一次烘焙留下的、这次没再生成的 <prefix>_*.tres。
func prune(prefix: String, keep: Dictionary) -> void:
	var dir := DirAccess.open(DIR)
	if dir == null:
		return
	for f in dir.get_files():
		if f.begins_with(prefix + "_") and f.ends_with(".tres") and not keep.has(f):
			dir.remove(f)
			print("  清掉旧文件 ", f)
#endregion


#region 运行
func run_all() -> void:
	for src: Array in SOURCES:
		bake(str(src[0]), str(src[1]), int(src[2]), bool(src[3]), CELL, 1)


func bake(file_name: String, prefix: String, material: int, turn: bool, cell: int, scale: int) -> void:
	var result: Dictionary = analyse(file_name, cell, turn)
	if result.is_empty():
		return
	var parts: Array = components(result["solid"], result["w"], result["h"])
	var bounds: Array = boxes(parts, result["w"])
	print("%s -> %s_*  %dx%d  实心 %d  连通块 %d" % [
		file_name, prefix, result["w"], result["h"], result["count"], parts.size()])
	var keep: Dictionary = {}
	for item: Dictionary in write(prefix, material, result["w"], parts, bounds, scale):
		keep[item["name"]] = true
		print("  %s  position = Vector2(%d, %d)  %dx%d  %d 格  save=%d" % [
			item["name"], item["cell"].x, item["cell"].y,
			item["size"].x, item["size"].y, item["pixels"], item["save"]])
	prune(prefix, keep)
#endregion