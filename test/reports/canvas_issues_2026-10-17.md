2026-10-17 画布与蓝图修复、自检记录

截图 34～39 项及蓝图库加载问题已处理：

- 34：地图根节点新增“关卡墨水配额 / starting_ink”，按材质 ID 配置各色开局墨量及容量；未填颜色沿用玩家 max_ink（默认 20000）。补墨、HUD 比例、黑墨复活补满均读取对应容量。未擅自替各地图设定平衡数值。
- 35：接入并修正光标背景采样 shader，按背景亮度显示黑色或白色，避免画笔在黑墨中消失。
- 36：蓝图点击判定排除非交互布局 Control，防止布局节点将画布误判成 UI 并取消放置。保留边界、墨量、重叠、编辑器专属机关校验。
- 37、39：矩形只生成四条边，更新新旧轮廓差异；鼠标及绘制条件不变时不重新生成或上传。缺墨时整体撤回，撤销/重做保留最终轮廓。
- 38：HUD 退出、日志按钮禁用键盘焦点，避免点击后空格再次激活按钮。
- 蓝图库：按路径、mtime、文件大小缓存已校验数据；保存和回收主动失效；读取结果与缓存隔离。关闭窗口保留有界预览缓存，卡片与详情复用已上传纹理；预览同色连续像素使用 fill_rect 批量绘制。没有删除或归档现有蓝图。
- 自检发现并修复 Shape → Body 的反向强引用环，避免蓝图放置、拆分及撤销后的物理数据滞留。反向查询改为弱引用，接口保持一致。

配置示例：在地图根节点 starting_ink 中填入 1 → 35000、9 → 4200，分别设定黑墨 35000、黄墨 4200，其余颜色保持默认。材质 ID：黑 1、灰 4、红 8、黄 9、白 10、蓝 11。配置保存在各自地图场景中。

最终验证使用 Godot 4.7.2。14 套功能回归共 367 项通过，另有真实 OpenGL 渲染 3 项通过；最终 15 份日志共 370 项 PASS，0 FAIL、0 ERROR、0 WARNING。git diff --check 通过。

| 测试 | 通过项数 |
| --- | ---: |
| test_canvas_issue_regressions | 20 |
| test_rectangle_ink_shortage | 9 |
| test_blueprint_ui | 23 |
| test_blueprints | 48 |
| test_game_cursor | 44 |
| test_canvas_shortcuts | 17 |
| test_canvas_button_undo | 25 |
| test_canvas_selection | 14 |
| test_player_health | 11 |
| test_hud_exit_menu | 1 |
| test_editor_gears | 36 |
| test_gear_editor_drag | 35 |
| test_yellow_mechanisms | 75 |
| test_hud_level_rebind | 9 |
| test_cursor_contrast_render | 3 |

本机样本耗时（性能随机器和内容变化）：

- 合成 5 张各 30720 像素蓝图：list_all 首次约 284ms，缓存后约 39ms。该数字只表示数据读取。
- 4 张合成蓝图的窗口构建：首次约 153ms，复开约 66ms；测量前数据已加载，采用 headless，不能作为真实 GPU 整帧耗时。
- 4096×2048、7px 线宽矩形：边框生成约 11.3ms。该数字只表示轮廓生成。
- 相同位置的形状预览调用 100 次合计约 0.21ms。
- 黑、白、中灰背景下均实际渲染并检查可见光标像素；图像保存在 .codex-tmp/cursor_black_ink_verified.png。

首次读取仍需解析与校验文件；本次缓存主要降低后续打开成本。未改为后台解析或引入磁盘缩略图格式。所有写文件测试使用独立随机目录并清理，现有蓝图库仅做只读性能核对。

最终日志：D:/Ink/.codex-tmp/final-test_*.log。
蓝图 UI 测试隔离背景音乐；音乐由已有 test_audio_integration 单独覆盖，本次未修改音乐产品逻辑。
