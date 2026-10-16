# 长导线性能复查（2026-10-15）

本轮复现了上一轮遗漏的绘制和“导线接触导线并移动”场景。测试是可控构造场景，不是用户截图原场景的 FPS 复测。

## 根因和修改

- 草稿每次拖动都将整条导线重新转成一张外接矩形纹理；停住鼠标、绘制其他颜色时也会重复做。长斜线的透明纹理面积随跨度平方增长。现改为 64×64 稀疏贴图，落笔/擦除只更新脏块；保存用的像素数组仍同步更新。
- 移动接触使电路重算时，原实现将整条导线边界转为世界坐标并插入空间哈希。现缓存导线对，按重叠区域查询；电气区域对只需确认一个实际像素接触。复杂多区域情形保留逐边界检查，避免区域数量平方增长。
- 电滑环改查轴承附近小矩形，并去掉重复电气端口。接触距离仍逐像素判断，未降低接触更新频率；粗细限功率、红色消耗、断线立即停机规则保留。

## 参考实现

- [Mindustry PowerGraph 官方源码](https://github.com/Anuken/Mindustry/blob/master/core/src/mindustry/world/blocks/power/PowerGraph.java)：`update()` 更新电源/用电器/电池，`addGraph()` 合并电网，`remove()`/`reflow()` 在结构变化时重组。借鉴保存电网和按电气关系工作，而非让一条长接触面产生大量重复连接。
- [tModLoader 官方 Wiring 补丁](https://github.com/tModLoader/tModLoader/blob/1.4.4/patches/tModLoader/Terraria/Wiring.cs.patch)：`HitSwitch`/`TripWire` 触发信号，队列与已处理位置控制传播。Terraria 是信号机制，不能直接代替本项目连续功率和可破坏刚体规则；这里没有声称检查了闭源 Terraria 的完整源码。

## 实测

Godot 4.7.2，Windows，RTX 4060 Laptop，窗口运行。主线长 2048px、笔刷 7px；第二条长线 2000×3px，另有 12×3px 小探针。每项重复操作 20 次；下表是方法墙钟中位数，不是整机帧率。

| 操作 | 修改前 ms | 修改后 ms |
|---|---:|---:|
| 2048px 斜线，鼠标停住继续落笔 | 12.098 | 0.042 |
| 同画布已有长斜线，绘制其他颜色 | 10.075 | 0.076 |
| 小导线在长线末端移动接触，每固定步 | 11.427 | 0.520 |
| 两条长线平行移动接触，每固定步 | 24.552 | 1.162 |
| 无接触变化的稳定供电 | 0.112 | 0.139 |
| 64 次分段画完 2048px 斜线，累计 | 287.290 | 31.135 |

稳定供电没有收益，本轮针对的是重画和接触变化。移动测试强制每步改变相对位姿，避免只测缓存命中。

`before.json` 在修改生产代码前采集。`before_runtime.json` 将基线提交 `b66576e968e681ec4a05283273574637983ecfe3` 的 BlueInk 源码在内存中插桩，显示层使用修改后的版本；仅用于运行时供电/接触比较，不作为绘制基线。其固定源码保存为 `before_runtime_source.txt`。`after.json` 是最终代码，包含方法插桩数据；插桩也有少量开销。

[交互火焰图](flamegraph.html)、[图片](flamegraph.png) 和 `*.trace.json` 均来自实测方法计时，**不是统计 CPU 采样**。两张火焰图独立归一化，比较性能请看毫秒数；绘制基线没有插桩栈，因此只列计时表。

## 自测和剩余问题

- 蓝墨窗口测试 62/62；包括鼠标实际绘制、撤销、快照、固化、燃料不引爆、断线重连、滑环、分配，以及新增稀疏贴图/负坐标/局部擦除检查。
- 长线接触在 0、0.3、1.2 弧度下，与全部边界像素穷举得到的电气区域连接一致；供电检查通过，共 4/4。
- 原蓝墨功能测试退出时仍有 ObjectDB/resource 未释放报告。本轮性能工具正常退出，没有该报告；没有据此宣称游戏运行内存问题全部排除。
- 编辑器导入返回 0，没有新增脚本解析错误；仍报告原生库热重载副本占用/复制、既有 UID、路径大小写及退出资源警告，不能当作全项目干净验收。
- **一次性停顿未解决**：2048px 固化本轮约 171ms；首次电路构建约 29ms；落笔结束计算截面约 14–20ms。没有隐藏这些开销或将它们算进持续供电优化收益。
- 很多复杂导线同时交叠、频繁碎裂、实际关卡整帧 FPS 尚未覆盖。本报告证明上述构造场景的改进，不代表所有规模和截图原场景均已消除卡顿。

## 复现

在项目根目录 PowerShell 执行（工具和报告保留供回归；临时快照/截图清理）：

```powershell
$engine = 'T:\GODOT\tool\Godot_v4.7.2-stable_win64_console.exe'
& $engine --path . --script res://test/tools/profile_blue_long.gd --quit-after 1500 -- after --trace
& $engine --path . --script res://test/tools/profile_blue_long.gd --quit-after 1500 -- before_runtime --baseline-runtime
python test/tools/render_blue_profile.py reports/blue_long_wires
& $engine --path . --script res://test/test_blue_ink.gd --quit-after 1500 -- --preview-blue
```

原始绘制基线 `before.json` 需在上述基线提交版本运行同一工具采集；在最终版本上重跑 `before` 参数只改变输出文件名，不能还原旧绘制实现。
