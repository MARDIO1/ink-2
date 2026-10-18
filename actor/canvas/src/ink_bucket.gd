extends RefCounted
## 墨水桶的**区域搜索**：从一点出发，沿 4 邻接找连通的空区。
##
## 只做搜索，不落笔、不记账——落笔与扣墨仍由画布负责。
## 这样"能不能灌满"与"灌了之后怎么写"是两件事，也方便单独测边界条件。
##
## 约定（与画布一致，不能改）：
##  - **4 邻接**而非 8 邻接：数字拓扑里"8 连通的边界"正好困住"4 连通的填充"。
##    圆形的 1px 外框是斜着走的（8 连通），4 邻接的填充才不会从斜缝里漏出去。
##  - 一旦漫到画布边缘就判定"敞开"，直接放弃（否则免墨水模式会把整张图灌满）。
##  - 预算不足时提前退出：先数够不够，再决定是否落笔。

## 搜索结果键：
##   ok       bool         是否找到可填充的封闭区域
##   cells    PackedInt32Array  区域内的像素下标（行主序），ok 时有效
##   reason   String       ok=false 时的原因：`"solid"` / `"open"` / `"room"`
##   count    int          ok=false 且 reason=="room" 时，已经数到的像素数
static func find_region(data: PackedByteArray, rod_data: PackedByteArray, size: Vector2i,
		point: Vector2i, room: int) -> Dictionary:
	var w := size.x
	var h := size.y
	if point.x < 0 or point.y < 0 or point.x >= w or point.y >= h:
		return {"ok": false, "reason": "solid"}
	var first := point.y * w + point.x
	if data[first * 4 + 3] > 127 or rod_data[first * 4 + 3] > 127:
		return {"ok": false, "reason": "solid"}   # 点在实心像素上：什么都不做

	var seen := PackedByteArray()
	seen.resize(w * h)
	var stack := PackedInt32Array()
	var targets := PackedInt32Array()
	seen[first] = 1
	stack.append(first)
	while not stack.is_empty():
		var top := stack.size() - 1
		var idx := stack[top]
		stack.resize(top)
		targets.append(idx)
		var x := idx % w
		var y := idx / w
		if x == 0 or x == w - 1 or y == 0 or y == h - 1:
			return {"ok": false, "reason": "open"}   # 连到纸张边缘，说明不是封闭图形
		if targets.size() > room:
			return {"ok": false, "reason": "room", "count": targets.size()}
		# ⚠️ 入栈与标记必须内联：Packed 数组在 GDScript 里是值拷贝，
		#    塞进 helper 里改，改的是副本 —— 会变成永远推同一个像素的死循环。
		if x > 0 and seen[idx - 1] == 0 and data[(idx - 1) * 4 + 3] <= 127 \
		and rod_data[(idx - 1) * 4 + 3] <= 127:
			seen[idx - 1] = 1
			stack.append(idx - 1)
		if x + 1 < w and seen[idx + 1] == 0 and data[(idx + 1) * 4 + 3] <= 127 \
		and rod_data[(idx + 1) * 4 + 3] <= 127:
			seen[idx + 1] = 1
			stack.append(idx + 1)
		if y > 0 and seen[idx - w] == 0 and data[(idx - w) * 4 + 3] <= 127 \
		and rod_data[(idx - w) * 4 + 3] <= 127:
			seen[idx - w] = 1
			stack.append(idx - w)
		if y + 1 < h and seen[idx + w] == 0 and data[(idx + w) * 4 + 3] <= 127 \
		and rod_data[(idx + w) * 4 + 3] <= 127:
			seen[idx + w] = 1
			stack.append(idx + w)
	return {"ok": true, "cells": targets}
