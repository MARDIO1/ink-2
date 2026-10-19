# 外部地图与蓝图内容

## 目标与边界

- 玩家可以在导出版中使用地图编辑器导出、读取 `.tscn`。
- 玩家可以读取和保存 `blueprints/*.inkbp`。
- 外部内容根固定为 exe 所在目录。
- 地图依赖（`map/src`、`actor`、`ui`、`ink` 等）继续留在 PCK。
- 不做内容签名或沙箱；外部 `.tscn` 按可信模组内容处理。

## 导出设置

`export_presets.cfg` 排除地图场景和蓝图 JSON，但保留所有依赖：

```ini
export_filter="all_resources"
exclude_filter="map/asset/imported/*.tscn, map/second/*.tscn, blueprints/*.inkbp, game/*"
```

不要使用 `map/*`：它会把 `map/src` 脚本和 `map/asset/blank_level.tscn` 一起排除。
`game/*` 也必须排除，否则上一次导出的外部地图会被当成项目资源再次打进 PCK。
`export_presets.cfg` 当前被 `.gitignore` 忽略；构建脚本会检查这四个过滤项，缺失时直接报错，
不会静默打出包含地图的大 PCK。

## 运行时路径

`map/src/content_paths.gd` 在编辑器中返回 `res://`，在导出版中把已存在的
`res://map/...` 优先解析成 exe 旁边的绝对路径；不存在时回退 PCK。

- `root.gd` 在唯一的切关入口解析路径。
- 选关扫描 PCK 和 exe 旁边的 `map`，但列表仍保存逻辑 `res://map/...` 路径。
- 传送门继续保存逻辑路径，切关时由 root 解析。
- 新建空白地图写入 exe 旁边的 `map/asset/imported`。
- `BlueprintStore` 在导出版使用 `exe目录/blueprints`，失败回退 `user://blueprints`。

## 构建

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build_windows_external.ps1
```

默认只复制缺失的 `.tscn`/`.inkbp`，保留玩家已有文件。需要覆盖时加
`-OverwriteContent`。构建脚本还会复制 `rapier_bridge.dll`；它不在
`.gdextension` 的 libraries 列表里，但 `fastphys.dll` 会在运行时加载它。
缺少它会表现为地图能进入、角色不移动。

## 验证

已通过：

- 源码模式：扉页选关、真实按键移动、蓝图 55/55。
- 正式 `game/` 包：选关点击扉页、11/11 地图受控移动。
- 外部地图保存出 `.tscn` 后可重新加载。
- 外部蓝图读取、保存、删除。
- 新建空白地图写入外部目录。
- 结构不完整的地图明确失败，不替换当前关卡。
- 正式包 F2 两轮真实按键进入/退出编辑器：18/18。
- 正式包墨水回归：材质 3/3、红墨 33/33、黄墨 50/50、蓝墨能量 39/39、白墨 17/17。
- 正式包蓝图数据/放置 55/55，蓝图 UI 29/29。

正式 `game/` 包的 PCK 约 34.95 MB（旧的误包含发布目录版本约 44.77 MB）。

已知基线债务（与本次外置路径无关）：

- `test_map_portal` 源码模式 46 项中 6 项失败，外置模式失败集合与源码一致。
- `test_scene_transition` 仍有 1 项编辑器快照时序失败。

## 测试命令

```powershell
$build = "T:\GODOT\ink-2\.codex-tmp\external_build_130358"
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test_level_playability.ps1 `
  -Godot "$build\Godot_v4.7.2-stable_win64_console.exe" `
  -Packaged -Pack "$build\ink_fffight_v0.10.pck" `
  -ExternalContent
```

`--external-content` 只用于在编辑器版本引擎下模拟导出版外部根；正式 exe 会根据
`OS.has_feature("editor")` 自动使用外部内容。
