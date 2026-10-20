extends RefCounted
## 重新开始的策略：只允许游玩中重读保存文件，不保存运行时现场。


static func saved_path(router: Node) -> String:
	if router._loading_level or router._transition.busy or router.level_root.get_child_count() != 1:
		return ""
	var level: Node = router.level_root.get_child(0)
	var editor := level.get_node_or_null("Creative")
	if editor != null and editor.get("active") == true:
		return ""
	var path: String = router._current_level_path
	return path if not path.is_empty() else level.scene_file_path


static func restart(router: Node) -> bool:
	var path := saved_path(router)
	if path.is_empty():
		return false
	# IGNORE 重读场景和内嵌资源，不沿用上次进入时缓存的地图文档。
	return await router.request_level_change(path, ResourceLoader.CACHE_MODE_IGNORE)
