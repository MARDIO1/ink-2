"""Render measured Godot spans as aggregate flame graphs and Chrome Trace files.

python test/tools/render_blue_profile.py
No sampled CPU stacks are invented: gray space is self/uninstrumented time.
"""
from pathlib import Path
import hashlib
import html
import json
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "test" / "reports" / "blue_performance"
DATA = {name: json.loads((OUT / f"{name}.json").read_text()) for name in ("before", "after")}
if (OUT / "before_runtime.json").exists():
    # Runtime baseline uses old BlueInk and the new display; drawing baseline
    # was captured separately before either production file was edited.
    baseline = json.loads((OUT / "before_runtime.json").read_text())
    DATA["before"]["results"] += [r for r in baseline["results"] if r.get("spans")]


def tree(spans):
    nodes = {(): {"total": 0, "count": 1}}
    for span in spans:
        path = tuple(span["stack"])
        entry = nodes.setdefault(path, {"total": 0, "count": 0})
        entry["total"] += span["dur"]
        entry["count"] += 1
    nodes[()]["total"] = sum(node["total"] for path, node in nodes.items() if len(path) == 1)
    return nodes


def color(name):
    hue = int(hashlib.sha256(name.encode()).hexdigest()[:4], 16) % 100 / 100
    return matplotlib.colors.to_hex(plt.get_cmap("YlOrRd")(0.25 + hue * 0.55))


def layout(nodes, parent=(), x=0):
    for path in sorted(p for p in nodes if p[:-1] == parent and p):
        yield path, x, nodes[path]["total"]
        yield from layout(nodes, path, x)
        x += nodes[path]["total"]


def svg(result, variant):
    nodes = tree(result["spans"])
    total = max(nodes[()]["total"], 1)
    height = (max(map(len, nodes)) + 1) * 27
    title = f'{variant}: median {result["median_us"]/1000:.3f} ms / P95 {result["p95_us"]/1000:.3f} ms'
    parts = [f'<h3>{title}</h3><svg viewBox="0 0 1100 {height}" data-full="0 0 1100 {height}" xmlns="http://www.w3.org/2000/svg">']
    for path, x, duration in layout(nodes):
        px, width = x / total * 1100, duration / total * 1100
        y = height - len(path) * 27
        node = nodes[path]
        tip = f'{" > ".join(path)} | inclusive total {duration/1000:.3f} ms | mean {duration/node["count"]:.1f} us | {node["count"]} calls'
        parts.append(f'<g class="span" data-x="{px}" data-w="{max(width, 0.1)}"><title>{html.escape(tip)}</title><rect x="{px:.3f}" y="{y}" width="{max(width-.4, .1):.3f}" height="25" fill="{color(path[-1])}"/>')
        if width > 90:
            parts.append(f'<text x="{px+3:.3f}" y="{y+17}" font-size="12">{html.escape(path[-1])}</text>')
        parts.append('</g>')
    parts.append('</svg>')
    return ''.join(parts)


sections, rows = [], []
before = {r["scenario"]: r for r in DATA["before"]["results"]}
after = {r["scenario"]: r for r in DATA["after"]["results"]}
for scenario in [name for name in before if name in after]:
    b, a = before[scenario], after[scenario]
    speedup = b["median_us"] / max(a["median_us"], 1)
    rows.append(f'<tr><td>{scenario}</td><td>{b["median_us"]/1000:.3f}</td><td>{a["median_us"]/1000:.3f}</td><td>{speedup:.1f}x</td></tr>')
    if not b.get("spans") or not a.get("spans"):
        continue
    sections.append(f'<article id="{scenario}"><h2>{scenario}</h2>{svg(b,"before")}{svg(a,"after")}</article>')
    for variant, result in [("before", b), ("after", a)]:
        origin = min(s["ts"] for s in result["spans"])
        events = [{"name": s["name"], "ph": "X", "pid": 1, "tid": 1, "ts": s["ts"]-origin, "dur": s["dur"]} for s in result["spans"]]
        (OUT / f'{variant}_{scenario}.trace.json').write_text(json.dumps({"traceEvents": events}), encoding="utf-8")

document = '''<!doctype html><meta charset="utf-8"><title>Blue ink measured flame graphs</title>
<style>body{font:15px system-ui;margin:32px;background:#faf8f3;color:#26231f;max-width:1200px}svg{width:100%;background:#e8e6e2}text{pointer-events:none}rect{stroke:#fff;stroke-width:.2}.span{cursor:pointer}table{border-collapse:collapse}td,th{padding:8px 15px;border-bottom:1px solid #ccc}button,select{padding:8px}article{display:none}article.active{display:block}</style>
<h1>蓝墨：实测耗时火焰图</h1><p>方法级插桩汇总，非统计 CPU 采样。宽度表示包含子调用的累计耗时；空白是自身或未插桩工作。各图独立归一化，前后比较看毫秒数。悬停看总耗时与调用次数，点击方块缩放。</p>
<table><tr><th>场景</th><th>修复前中位数 ms</th><th>修复后中位数 ms</th><th>加速</th></tr>''' + ''.join(rows) + '''</table><p><select id="scenario"></select> <button onclick="document.querySelectorAll('svg').forEach(s=>s.setAttribute('viewBox',s.dataset.full))">重置缩放</button></p>''' + ''.join(sections) + '''
<script>const articles=[...document.querySelectorAll('article')],menu=document.querySelector('select');for(const a of articles){menu.add(new Option(a.id,a.id))}function show(){articles.forEach(a=>a.classList.toggle('active',a.id===menu.value))}menu.onchange=show;menu.value=articles.find(a=>a.id==='full_pipeline_4steps')?.id||articles[0].id;show();document.querySelectorAll('.span').forEach(g=>g.onclick=()=>{const s=g.ownerSVGElement,h=s.dataset.full.split(' ')[3];s.setAttribute('viewBox',`${g.dataset.x} 0 ${g.dataset.w} ${h}`)});</script>'''
(OUT / "flamegraph.html").write_text(document, encoding="utf-8")

scenario = next(name for name in ["two_long_moving_2048", "full_pipeline_4steps", "living_motion"] if name in before)
fig, axes = plt.subplots(2, 1, figsize=(15, 8), facecolor="#faf8f3")
for ax, variant, result in zip(axes, ("BEFORE", "AFTER"), (before[scenario], after[scenario])):
    nodes = tree(result["spans"])
    total = max(nodes[()]["total"], 1)
    depth = max(map(len, nodes))
    for path, x, duration in layout(nodes):
        width = duration / total * 100
        ax.add_patch(Rectangle((x / total * 100, len(path)-1), width, .92, color=color(path[-1]), ec="white", lw=.4))
        if width > 7:
            ax.text(x / total * 100 + .3, len(path)-.53, path[-1], fontsize=8, clip_on=True)
    ax.set(xlim=(0,100), ylim=(-.05,depth+.1), yticks=[], xlabel="Inclusive share within each panel (%)")
    ax.set_title(f'{variant} | {scenario} | median {result["median_us"]/1000:.3f} ms | P95 {result["p95_us"]/1000:.3f} ms', loc="left")
    ax.set_facecolor("#e8e6e2")
fig.suptitle("Blue ink: measured instrumented flame graphs (not sampled CPU stacks)", fontsize=15)
fig.tight_layout()
fig.savefig(OUT / "flamegraph.png", dpi=140)
fig.savefig(OUT / "flamegraph.svg")
print(OUT / "flamegraph.html")
print(OUT / "flamegraph.png")
