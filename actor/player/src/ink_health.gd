@tool
extends Node
## 墨水生命值 —— 玩家「血量」的**单一真源**。
##
## 数值就是墨水：0 = 空瓶（液面见底），max_ink = 满瓶。
##
## 谁在用它：
##   - `BottledInk`（墨水图层）：每帧取 `ratio()` 当液面比例，自己不再存 fill；
##   - `ui/hud`：接 `changed`，把横条长度设成 `ratio()`；
##   - 其他系统（伤害、喝墨水、拾取）：只调 `add()` / `reduce()`。
##
## 查询读 `ink` / `max_ink` / `ratio()`，改只走 `add()` / `reduce()`。
## 直写 `ink = x` 不会发 `changed`（HUD 不会跟着动），游戏内不要那么写。
##
## 预留：碰撞伤害现在只在 `player_physics.gd:apply_collision_damage()`
## 里累加数值，还没接过来；接的时候把它转成 `reduce()` 即可。

## 任何真的变了的数值变化后发出（含被夹到 0 / max_ink）。消费者自己去读 `ratio()`。
signal changed

const InkPalette := preload("res://Ink/src/ink_palette.gd")

## **每种墨水各自的**满瓶量；每关不一样就改这一个数（场景里设）。
@export var max_ink: float = 20000.0
## 总墨量（所有墨水加起来）。给 HUD / 瓶身液面看；不要直接写，改走 `add()` / `reduce()`。
var ink: float = 0.0
## 伤害闸门。创造模式关掉它 —— 画布的记账走 `reduce()`，不经过这里。
@export var damage_enabled := true

## 各墨水当前量：材质 id -> 数量。
var _ink := {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	for i in InkPalette.ink_count():
		_ink[InkPalette.material_id_of(InkPalette.ink_at(i))] = max_ink
	_sync_total()


#region 接口
## 某种墨水的满瓶量。
func max_of(_material_id: int) -> float:
	return max_ink


## 某种墨水还剩多少。
func ink_of(material_id: int) -> float:
	return _ink.get(material_id, 0.0)


## 某种墨水的液面比例，0（空）..1（满）。
func ratio_of(material_id: int) -> float:
	var cap := max_of(material_id)
	return 1.0 if cap <= 0.0 else clampf(ink_of(material_id) / cap, 0.0, 1.0)


## 所有墨水合计的液面比例，0（空）..1（满）。`max_ink <= 0` 时按满瓶算，避免除零。
func ratio() -> float:
	var cap := max_ink * float(maxi(InkPalette.ink_count(), 1))
	if cap <= 0.0:
		return 1.0
	return clampf(ink / cap, 0.0, 1.0)


## 加墨水（喝墨水、拾取）。超出满瓶的部分丢掉。
func add(material_id: int, amount: float) -> void:
	_write(material_id, ink_of(material_id) + amount)


## 减墨水（受伤、施墨）。减到 0 就停。
func reduce(material_id: int, amount: float) -> void:
	_write(material_id, ink_of(material_id) - amount)


## 伤害统一入口（碰撞伤害接过来时走这里）。先扣色表里的第一种墨水。
func damage(amount: float) -> void:
	if not damage_enabled:
		return
	reduce(InkPalette.material_id_of(InkPalette.ink_at(0)), amount)


## 唯一的写入口：夹取到 0..满瓶，只在真的变了时才广播。
func _write(material_id: int, value: float) -> void:
	var bounded: float = clampf(value, 0.0, maxf(max_ink, 0.0))
	if is_equal_approx(bounded, ink_of(material_id)):
		return
	_ink[material_id] = bounded
	_sync_total()


## 把各墨水合计同步给读总量的人（HUD / 瓶身液面）。
func _sync_total() -> void:
	var total := 0.0
	for amount in _ink.values():
		total += amount
	if is_equal_approx(total, ink):
		return
	ink = total
	changed.emit()
#endregion
