extends Node
## 编辑器重扫可能清空扩展缓存；游戏启动时确保物理内核已注册。

func _enter_tree() -> void:
	if not ClassDB.class_exists("RapierPhys"):
		var status: int = GDExtensionManager.load_extension("res://addons/pixel_destruction/fastphys.gdextension")
		if status != GDExtensionManager.LOAD_STATUS_OK and status != GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
			push_error("无法加载像素物理扩展，状态：%d" % status)
			get_tree().quit(1)
