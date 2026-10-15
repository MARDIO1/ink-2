# 蓝图系统

框选完成后，蓝色选框旁提供“删除 Backspace”和“保存为蓝图 Save”。Ctrl＋左键仍只移动选框，普通左拖移动内容，选区内右键仍删除。

HUD 日志左侧的“蓝图”打开蓝图手册。支持名称/描述/标签搜索、收藏、重命名、修改说明和二次确认删除。打开手册或保存窗口暂停世界，关闭恢复进入前的暂停状态。

“使用蓝图”进入预览：左键放置、Shift＋左键连续放置、右键/Esc 取消。游玩必须靠近有效画布且放在其范围内；编辑器使用 MapCanvas，不检查玩家距离。各色墨水独立预检，失败不扣费、不落下一半；一次放置对应一次撤销。

普通固化墨水以草稿像素复制，继续沿用现有固化流程；黄墨杆/弹簧、蓝线/动力箭头保留独立层与参数。齿轮轮体和完整支座以独立实体复制，重建轴承、排除配对碰撞，不继承速度或旧对象引用。含齿轮的蓝图仅编辑器使用。功能部件或连接端只框到一部分时拒绝保存，不暗中纳入圆外/框外内容。

## 文件与安全边界

- `blueprint_codec.gd`：只读采集、缩略图、耗墨与占位计算、放置事务。
- `blueprint_store.gd`：受限 JSON 格式 v1；单边 1024 px，像素与部件预算限制，文件上限 24 MiB。
- `ui/blueprint/blueprint_system.gd`：Blueprints 自动加载；跨关卡手册、选区操作、幽灵预览与输入隔离。
- 存档位于 `user://blueprints/<id>.inkbp`，独立于地图、编辑快照与备份。不读取任意脚本/PackedScene/对象 Variant。
- 修改文件先写临时文件、保留旧版备份再重命名提交；删除仅改名为 `.trash`，可从用户数据目录找回。
- 切关卡取消预览，不持有已经释放的画布。F2 重载后重新发现当前关卡。
- 首版原尺寸放置，不提供旋转、缩放、镜像或联网分享。

## 验证

```powershell
& 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path D:\Ink --script res://test/test_blueprints.gd
& 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path D:\Ink --script res://test/test_blueprint_ui.gd
```

测试关闭地图自动保存，蓝图文件写入随机独立的测试目录并只清理该目录。界面测试可在有渲染设备时加 `-- --preview`，将选区和手册截图写入 Godot 用户数据目录。
