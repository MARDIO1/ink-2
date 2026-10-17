extends RefCounted
## 无限钉子写入 PBody 的跨颜色规则标记。
##
## 钉子外观与锚点仍归 actor/nail 管理；红、白、蓝规则只依赖这里，
## 避免 ink/* 反向依赖 actor/nail。
const UNBREAKABLE_TAG := &"infinite_nail"
const INFINITE_FUEL_TAG := &"infinite_fuel"


static func is_unbreakable(body) -> bool:
	if body == null:
		return false
	var tags = body.get("tags")
	return tags is Dictionary and bool(tags.get(UNBREAKABLE_TAG, false))


static func is_infinite_fuel(body) -> bool:
	if body == null:
		return false
	var tags = body.get("tags")
	return tags is Dictionary and bool(tags.get(INFINITE_FUEL_TAG, false))


## 删除任何不可破坏 body 的计划。调用方应在观察爆炸/腐蚀之前过滤。
static func filter_unbreakable(removals: Dictionary) -> Dictionary:
	var result := {}
	for body in removals:
		if not is_unbreakable(body):
			result[body] = removals[body]
	return result
