# 本地性能优化合回记录

来源：旧提交 e17658b。采用局部合并，保留当前 main 与本地近期修复。

1. PhysicsStep.sync_after_commit 在已知非空变化集时调用 PixelWorld.sync_changed_world_bodies。只更新变化刚体贴图；节点对齐、失效贴图与关节清理仍执行。未知变化集继续全量同步。
2. Creative.prepare_loaded_document 在普通游玩恢复草稿、随即固化期间临时启用 CanvasSurface.defer_load_metadata；InkDocument 跳过这次立即失效的贴图/元数据重建。编辑加载仍完整重建，正常和早退路径均重置开关。

本轮没有调整地图、墨水参数、物理求解参数或分块大小。

验证：真实像素破坏的增量同步 7 项、草稿文档/F2/重复加载 34 项、编辑器重载生命周期 18 项，全部通过；日志无脚本错误。生命周期测试退出有原有 ObjectDB 泄漏提示。本轮未测量帧率提升幅度。

修改前副本：.level_backups/performance-two-merge-20261020-005712/
本轮未提交 Git，也未清理 stash 或旧备份。
