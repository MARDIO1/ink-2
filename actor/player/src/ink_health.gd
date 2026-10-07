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

## 满瓶墨水量。
@export var max_ink: float = 100.0
## 当前墨水量，0..max_ink。查询直接读；改走 `add()` / `reduce()`。
@export var ink: float = 100.0
## 伤害闸门。创造模式关掉它 —— 画布的记账走 `reduce()`，不经过这里。
@export var damage_enabled := true


#region 接口
## 当前液面比例，0（空）..1（满）。`max_ink <= 0` 时按满瓶算，避免除零。
func ratio() -> float:
	if max_ink <= 0.0:
		return 1.0
	return clampf(ink / max_ink, 0.0, 1.0)


## 加墨水（喝墨水、拾取）。超出 max_ink 的部分丢掉。
func add(amount: float) -> void:
	_write(ink + amount)


## 减墨水（受伤、施墨）。减到 0 就停。
func reduce(amount: float) -> void:
	_write(ink - amount)


## 伤害统一入口（碰撞伤害接过来时走这里）。闸门关掉时什么伤害都进不来。
func damage(amount: float) -> void:
	if not damage_enabled:
		return
	reduce(amount)


## 唯一的写入口：夹取到 0..max_ink，只在真的变了时才广播。
func _write(value: float) -> void:
	var bounded: float = clampf(value, 0.0, maxf(max_ink, 0.0))
	if is_equal_approx(bounded, ink):
		return
	ink = bounded
	changed.emit()
#endregion
