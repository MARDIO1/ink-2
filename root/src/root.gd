extends Node
## 全局根：只干两件事 —— 挂**关卡**、盖 **UI**。
##
## `Level` / `UI` 是两个空容器：
##   · 切关卡 = 换 `Level` 的子场景（旧的整棵释放），UI 不动；
##   · UI 是独立子场景，盖在世界之上（自己的 CanvasLayer 决定层级）。
## 关卡里放什么见 `doc/文件组织.md`：世界（PixelWorld）+ 道具 + 玩家 + 相机 + 碰撞伤害 + 创造模式。

@export var level_scene: PackedScene = preload("res://map/main.tscn")
@export var ui_scene: PackedScene = preload("res://ui/game_ui.tscn")

@onready var level_root: Node = $Level
@onready var ui_root: Node = $UI


func _ready() -> void:
	if level_root.get_child_count() == 0 and level_scene != null:
		load_level(level_scene)
	if ui_root.get_child_count() == 0 and ui_scene != null:
		ui_root.add_child(ui_scene.instantiate())


## 换关卡：旧的整棵释放，新的挂在 `Level` 下。返回新关卡根节点。
func load_level(scene: PackedScene) -> Node:
	for child in level_root.get_children():
		level_root.remove_child(child)
		child.queue_free()
	var level := scene.instantiate()
	level_root.add_child(level)
	return level
