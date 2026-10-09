#墨水色表：**唯一真源**。画布、固化、墨水账、右侧选择面板都从这里读。
#加一种墨水只要两步：① 在 Ink/asset/ 放一个 PixelMaterial（id 唯一、没被占用）
#                    ② 在下面 INKS 里加一行。别的地方不用动。
#⚠️ 各墨水的颜色要两两分得开：认墨水靠颜色最近匹配（见 MATCH_TOLERANCE）。

#region 依赖
extends RefCounted

## 颜色通道差小于它就算同一种墨水。
const MATCH_TOLERANCE: float = 0.05

const BLACK := preload("res://Ink/asset/black.tres")
const GREY := preload("res://Ink/asset/grey1.tres")
const RED := preload("res://Ink/asset/red.tres")
## 钉子**不是墨水**：它有自己的贴图，只是借像素材质存一个 id。
const NAIL := preload("res://actor/nail/asset/nail.tres")
const INKS: Array = [
	{"name": "黑墨", "material": BLACK},
	{"name": "灰墨", "material": GREY},
	{"name": "红墨", "material": RED},
]
#endregion


#region 查询
static func ink_count() -> int:
	return INKS.size()


static func ink_at(index: int) -> Resource:
	if index < 0 or index >= INKS.size():
		return null
	return INKS[index]["material"]


static func ink_name(index: int) -> String:
	if index < 0 or index >= INKS.size():
		return ""
	return INKS[index]["name"]


static func color_at(index: int) -> Color:
	return color_of(ink_at(index))


static func color_of(material: Resource) -> Color:
	return material.color if material != null else Color.TRANSPARENT


static func material_id_of(material: Resource) -> int:
	return material.id if material != null else 0


## 画布像素颜色 -> 材质 id；透明或认不出来返回 0。
static func material_id_at_color(color: Color) -> int:
	if color.a <= 0.5:
		return 0
	for entry in INKS:
		if _close(color, color_of(entry["material"])):
			return material_id_of(entry["material"])
	if _close(color, nail_color()):
		return nail_material_id()
	return 0


## 该材质是不是墨水（钉子不是）。
static func is_ink(material_id: int) -> bool:
	for entry in INKS:
		if material_id_of(entry["material"]) == material_id:
			return true
	return false


## 墨水材质 id -> 画布颜色；不是墨水返回透明（钉子不回收回画布）。
static func color_for_material_id(material_id: int) -> Color:
	for entry in INKS:
		if material_id_of(entry["material"]) == material_id:
			return color_of(entry["material"])
	return Color.TRANSPARENT


static func nail_material_id() -> int:
	return material_id_of(NAIL)


static func nail_color() -> Color:
	return color_of(NAIL)


## 世界注册要用的全部材质（墨水 + 钉子）。
static func all_materials() -> Array:
	var out: Array = []
	for entry in INKS:
		out.append(entry["material"])
	out.append(NAIL)
	return out


static func _close(a: Color, b: Color) -> bool:
	return (
		absf(a.r - b.r) < MATCH_TOLERANCE
		and absf(a.g - b.g) < MATCH_TOLERANCE
		and absf(a.b - b.b) < MATCH_TOLERANCE
	)
#endregion
