"""Render measured aggregate timing spans, without inventing sampled native stacks."""
from pathlib import Path
import html
import hashlib
import json

out = Path(__file__).resolve().parents[2] / "test/reports/blue_energy"
data = json.loads((out / "chaos.json").read_text(encoding="utf-8-sig"))
p = data["sample_phases"]


def node(name, value, children=()):
    return {"name": name, "value": max(0, value), "children": children}


decode = node("decode / display", p["decode_us"], [
    node("highlight geometry", p["display_us"]),
    node("readback", p["decode_us"] - p["display_us"]),
])
advance = node("advance", p["advance_us"], [
    node("native call + transport", p["kernel_us"]), decode,
    node("command encoding", p["advance_us"] - p["kernel_us"] - p["decode_us"]),
])
tree = node("BlueInk.resolve_fixed", p["resolve_total_us"], [
    node("local contacts", p["contacts_us"]), node("production", p["emit_us"]), advance,
    node("prune / motor / fuel / adapter", p["resolve_total_us"] - p["contacts_us"] - p["emit_us"] - p["advance_us"]),
])
parts = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 230">',
         '<style>text{font:13px sans-serif;pointer-events:none}rect:hover{stroke:black;stroke-width:2}</style>',
         '<rect width="1200" height="230" fill="#fffaf0"/>',
         '<text x="10" y="20">Blue ink - measured wall-time spans (aggregate, not sampled CPU stacks)</text>']
folded = []
colors = ["#ffbe69", "#ffa35b", "#f57d50", "#e7594a"]


def draw(item, x=10.0, depth=0, path=()):
    name, value = item["name"], item["value"]
    width = value / max(1, tree["value"]) * 1180
    y = 188 - depth * 35
    tip = f'{name}: {value / 1000:.2f} ms cumulative; {value / max(1, tree["value"]) * 100:.2f}% of blue'
    parts.append(f'<g><title>{html.escape(tip)}</title><rect x="{x:.2f}" y="{y}" width="{max(0.1, width - .4):.2f}" height="31" fill="{colors[min(depth, 3)]}"/>')
    if width > 95:
        parts.append(f'<text x="{x + 4:.2f}" y="{y + 20}">{html.escape(name)}</text>')
    parts.append('</g>')
    if not item["children"]:
        folded.append(';'.join(path + (name,)) + f' {value}')
    for child in item["children"]:
        draw(child, x, depth + 1, path + (name,))
        x += child["value"] / max(1, tree["value"]) * 1180


draw(tree)
parts.append('</svg>')
(out / "flame.svg").write_text('\n'.join(parts), encoding="utf-8")
(out / "flame.folded").write_text('\n'.join(folded) + '\n', encoding="utf-8")
print(out / "flame.svg")

cases = [json.loads((out / f"{name}.json").read_text(encoding="utf-8-sig")) for name in ("short", "long", "chaos")]
table = '\n'.join(f'| {r["case"]} | {r["pixels"]} | {r["one_percent_low_fps"]:.1f} | {r["blue_p95_us"] / 1000:.3f} ms | {r["powered_frame_ratio"] * 100:.1f}% | {r["load_ms"] / 1000:.2f} s |' for r in cases)
scaling = json.loads((out / "scaling.json").read_text(encoding="utf-8-sig"))["rows"]
scale_table = '\n'.join(f'| {r["length"]} | {r["cpu_median_us"]} | {r["cpu_p95_us"]} | {r["updates"]} |' for r in scaling)
readme = f'''# 蓝墨能源元胞验收（2026-10-16）

本机 Windows，Ryzen 9 7940HX / RTX 4060 Laptop GPU，Godot 4.7.2 stable，Compatibility OpenGL。
2560×1440 实际渲染，不限帧、关闭 VSync，默认速度 600 网格 px/s、1.0 秒发包、1.05 秒电机缓冲。
每场单独运行：5 秒热身，随后 15 秒窗口帧间隔采样。1% low = 1000 / 最慢 1% 帧耗时均值；不是平均 FPS，也不是单个最慢帧。

| 场景 | 蓝色像素 | 1% low FPS | 蓝墨 resolve P95 | 有电机工作的采样帧 | 构建耗时 |
| --- | ---: | ---: | ---: | ---: | ---: |
{table}

混乱图用本次“强者保留、弱者耗散”版本及 1.0 秒发包周期重跑；短线、长线窗口 JSON 保留此前 0.5 秒周期记录，长度标度数值基准用当前内核重跑。是否达标以每场 JSON 的 `passed` 为准，不把一次通过解释为任意负载的稳定保证。

混乱图：184204 导线像素，九条横线、多条竖线/斜线/闭环，四处供能区，12 个箭头。已删除烧线和自动修复流程。最终剩余导线 {data["remaining_wire_pixels"]} 像素，完整性 {data["wire_intact"]}；验收同时检查完整导线、活跃电流、真实消费与 1% low ≥50。
本轮短线首测曾为 48.9 FPS，最大帧 138.9 ms，该帧蓝墨总耗时约 1.02 ms；当前表为随后复测，不能仅凭蓝墨耗时给整帧长帧归因。旧版烧线/高光阶段的数据保留在已有的 `chaos_run1.json`、`chaos_before_group_reuse.json`、`chaos_highlight_three_pass.json`，不能与本次完整线路测试直接等同。压力测试未打开 Tab 力观察器。

## 长度标度

另做固定宽度 7 px、相同发包频率/速度的 headless 数值基准，预热至线路充满后取 600 次更新。这里是 CPU 微秒，不是窗口 FPS。

| 长度 px | CPU 中位数 µs | CPU P95 µs | 活跃格更新次数 |
| --- | ---: | ---: | ---: |
{scale_table}

长度从 240 到 4096 为 17.07 倍，更新工作量约 17.13 倍；没有遍历所有可能路径导致的指数增长。活动格状态合并、有寿命且波号抑制回头访问，分叉不会生成无限独立对象。初次登记/存储仍随导线面积增长。

## 计时火焰图与修复点

[flame.svg](flame.svg) 来自采样阶段累计的真实计时嵌套，悬停可看数值；`flame.folded` 的单位是微秒。它是计时火焰图，未伪造原生 CPU 采样栈，也没有把它当作整帧的 GPU/物理剖析。

主要修复：移除全局图和最宽路径；数值推进独立放入 ink/blue/native；红色候选按材料块取样；二进制输出按活跃数据增长；静态导线和高光分别缓存绘制；同步双缓冲保留桶容量。迎面相遇只保留较大反向分量，等值确定性选择，损失记账；移除了自动切线、闪光和 32 px 注入豁免。按来向记访问，避免胜者被败者的反向足迹挡住；保留原寿命和同向重复访问限制。

## 自测

- 蓝色数值规则 33/33，含粗线、转弯、斜线、平分、限流、闭环完整保留及寿命、同格/相邻格不等量对冲、等量与反序注入、穿过败者足迹、败者不提前激活电机、跨载体及旋转载体对冲、滑环旁路分流、碎裂保龄、输出扩容；验证能源守恒。
- 蓝色端到端 74/74，新增整支箭头黑色承载与边界裁剪、非锚点受损消散、真实抓握才供电、松手到期和多箭头共用生物推力上限；原有生成/撤销/回收/保存、耗料不引爆红色等继续通过。滑环覆盖单侧不供电、双侧供电、四个旋转姿态和毁轴断电。
- 真实画笔 72 种组合：6 种笔宽、3 种斜率、有无抖动、端部/侧面供电，均无自发短路；闭环及异源迎面相遇均耗散能源而不损坏导线，另由数值测试验证。
- `test_force_view.gd`：Tab/F2 真实模式切换、外层 UI 跨关卡复载重新绑定、相反蓝推力分别显示及收到功率、弹力模型和高光可见性通过。另复现现有灰底问题：灰材质摩擦为 0，黑身灰底仍被整体平均成 0.45，与黑地面接触后停下；这是已定位而未修改的物理插件限制，不能把该复现测试通过写成灰底已无摩擦。
- 保存车辆 `map/asset/blue_car.tscn`：两轮分别顺时针/逆时针，经车架和轮轴电滑环供电；台座两个支点固定车架。当前两根红条为独立动态刚体，正常储能 1e8 J/像素；复载后推进 1200 次固定更新，红像素 448→322，下落约 9.1 px，两轮峰值角速度约 +1.86/-1.83 rad/s，零短路和燃料爆炸。真实输出见 `test_blue_car.txt`。
- 长度标度 9/9；黄色墨水 46/46；黄色机构 75/75，迁移后引用正常。
- 数值单测退出无新原生对象泄漏告警；大型集成套件仍有 ObjectDB/3 resources 退出清理告警，未声称全项目零告警。
- 项目导入仍有旧 UID 和 Ink/ink 大小写告警（见 import.txt）；当前主场景冒烟无脚本错误。原始回归输出保留在各 test_*.txt。

## 边界与复测

压力图使用完整关卡的 SimulationRuntime/Rapier、实际材料和电机，但 2478000 像素的黑色载体设为静态；它验证能源路由/消费/迎面耗散，不代表大量运动刚体的物理压力。燃料储能调高以防测成空载，真实耗料由端到端测试覆盖。

构建本身约 13–15 秒，首次物理/渲染还有约 2 秒冷启动尖峰，均与稳态 FPS 分开记录。历史版本内存独立采样见 `chaos_memory.json`：游戏工作集约 588 MiB，观测峰值约 712 MiB，私有内存约 752 MiB；包含完整场景和大画布，不是蓝墨模块单独占用。本次未重测内存和同进程卸载回收曲线。

当前原生库只交付 Windows x86_64；其他平台需构建对应库。性能结论针对本机和上述确定性地图，不保证任意规模/任意硬件的最低帧。

编辑器打开 `map/test/blue_energy_stress.tscn` 按 F6：1 短线、2 长线、3 混乱、R 重建。

```powershell
$godot = 'T:/GODOT/tool/Godot_v4.7.2-stable_win64_console.exe'
& $godot --path . --scene res://map/test/blue_energy_stress.tscn -- --bench --case=chaos
& $godot --headless --path . --script res://test/tools/profile_energy_scaling.gd
python test/tools/render_energy_profile.py
```

实现职责与参数见 `ink/blue/doc/蓝墨.md`；源代码校验值在 `source_hashes.json`。未改破坏插件内部。
'''
(out / "README.md").write_text(readme, encoding="utf-8")
root = out.parents[2]
sources = [*root.glob("ink/blue/src/*.gd"), root / "ink/blue/src/blue_ink.gd", *root.glob("ink/blue/native/*.*"), root / "test/tools/blue_energy_stress.gd"]
manifest = {str(p.relative_to(root)).replace('\\', '/'): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources if p.suffix in (".gd", ".cpp", ".hpp", ".dll", ".gdextension")}
(out / "source_hashes.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
