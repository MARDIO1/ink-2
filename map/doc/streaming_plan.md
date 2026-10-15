# 地图区块加载最小方案

状态：设计，尚未实现。原则：先只处理占用最大的地图地形；不建立通用实体流送框架，
不修改 Godot 引擎，不预先修改 pixel addon。

## V1 范围

- 区块大小先取 2048×1152，横纵都超过当前 960×540 视口的两倍；MapCanvas 固定为同样大小。
- 常态保持主角所在块和上、下、左、右四邻块；接近角落时补对应对角块，硬上限仍是周围 3×3。
- 只把静态地图地形拆进区块；玩家、怪物、可搬物品、跨界物品、关节机关继续留在 map.tscn 常驻。
- 修改过的地形块离开目标集合后保存，再从 PixelWorld 增量移除；回来时优先读取运行存档。
- 动态实体流送、跨区关节存档和无限碎片回收留到数据证明必要以后。

这样先解决扉页中约 120 万地图像素带来的加载和内存，避免首版引入 entity_id、pin 和保存岛。
如果跨界物品本身就是巨型像素刚体，它仍会常驻；这是 V1 明确保留的限制。

## 地图文件结构

```text
map/<map_id>/
├─ map.tscn                       # 唯一 PixelWorld、玩家、相机、规则、全局/跨界实体
└─ chunks/
   ├─ index.json                  # 存在哪些坐标；只存字符串和轻量元数据
   ├─ chunk_-1_0.tscn
   ├─ chunk_0_0.tscn
   └─ chunk_1_0.tscn

user://runs/<run_id>/<map_id>/
└─ chunks/chunk_x_y.bin           # 只为修改过的地形块创建
```

map.tscn 不用 ext_resource/preload 引用全部 chunk，否则加载主场景可能提前加载依赖。
MapStreamer 读取 index.json；也可以按固定文件名推导路径，但稀疏地图仍需要坐标列表。
导出工具必须显式包含 index 中的动态路径。

chunk tscn 只保存地形数据/地形刚体，不保存 Player、SimulationRuntime、Creative 或 MapCanvas。
区块内部使用 0..2047、0..1151 局部坐标；加载时加 `chunk_coord * Vector2i(2048, 1152)`，
重新挂到唯一 PixelWorld 的直接子层。
当前 PixelBody2D.bake 不应用区块父节点平移，因此不能只移动 Chunk 根节点。

## 编辑器

沿用现有 Creative 和唯一 MapCanvas。进入地图编辑时：

1. MapCanvas 固定 2048×1152，并移动到 `active_chunk * Vector2i(2048, 1152)`。
2. 加载活动块和四邻块作为上下文；只有活动块可写，邻块只显示；接近角落再显示对角块。
3. 切换活动块前保存当前块，再移动/清空/载入同一个 MapCanvas。
4. F5 保存活动 chunk；地图壳的玩家出生点、传送门和全局实体仍保存到 map.tscn。
5. V1 笔画在区块边界裁断；自动跨块连续绘画以后再做，避免一次编辑事务同时修改多个文件。

MapCanvas 只属于编辑会话，不进入运行 chunk tscn。游玩时不会为多个区块各分配一张完整 RGBA
编辑图和撤销缓冲。固定大小还应关闭当前地图画布扩容入口，避免编辑坐标和区块索引失配。

编辑实体化仍可能卡：Canvas.generate/CanvasSolid.solidify 是同步物理烘焙。V1 先限制单区块/单地形件
复杂度并记录耗时；只有单件仍超过帧预算时，才在 addon 权威源增加预烘焙或分步准备接口。

## Root 和加载顺序

Root 下只新增一个 MapStreamer 节点和 `root/src/map_streamer.gd`；它引用当前 Level 中的 PixelWorld。
切关时清空队列并更换引用。保存编码先放同一脚本的内部函数，证明稳定且代码过大后才拆文件。

优先队列按玩家到区块 Rect2 的实际距离排序：

1. 主角所在区块。
2. 当前镜头已经覆盖的区块，距离近者优先。
3. 上、下、左、右四邻块中其余区块，距离近者优先；同距离时优先移动方向。
4. 主角接近区块角落时，加入对应对角块；其他对角块不提前加载。

一个资源完成后重新排序，再加载当前最重要的一块。常态目标是当前块加四邻块，角落时临时增加
一个对角块；极端情况下硬上限为当前块加八邻块。玩家跨入新块后重新计算目标集合；退出集合的块
先保存（若 dirty）再卸载。

当前窗口为 960×540，而区块为 2048×1152。出生点正常位于块内时，当前块能够覆盖完整镜头并留出
移动余量；出生点靠边时仍需等待镜头实际覆盖的邻块，再交出控制。四邻块随后按距离渐进加载。

避免边界抖动只加一个简单条件：区块离开目标集合后延迟约 1 秒再保存卸载；期间重新进入就取消。
不先实现更复杂的 keep-alive/pin 系统。

## 保存

未修改块直接从 res:// 初始 chunk 重新加载。发生破坏/绘画后标 dirty；卸载时保存当前地形像素、
材料和必要的静态地形状态。先在主线程复制基础类型快照，后台线程只压缩和写 PackedByteArray；
SceneTree、Node、ImageTexture 和 PixelWorld 仍只在主线程操作。

临时文件写完并关闭后替换正式文件；写失败则不卸载内存中的块。加载时有 user:// 存档就读存档，
否则读 res:// 初始数据。V1 不保存常驻实体，因为它们没有被卸载。

## 引擎和线程

V1 不改 Godot 引擎，也不先改 addon。资源读取使用 ResourceLoader.load_threaded_request；状态未完成前
不能调用 load_threaded_get，否则仍可能阻塞。PackedScene.instantiate、add_child、add_body_node、
remove_body_node 和纹理更新留在主线程，并且每帧只提交一个小任务。

只使用 Godot 内建后台资源加载，加一个受控的文件写入工作线程；不在线程里操作 SceneTree 或渲染对象。
如果 2048×1152 逻辑块内部某个单体 add_body_node 仍造成明显尖峰，先把区块内部地形拆成多个物理件；
拆分后仍超预算，再用基准证明后修改 addon 权威源，提供
预烘焙恢复/分步准备接口。那是第二阶段，不是流式原型的前置条件。

## 最小文件改动

新增：

- `root/src/map_streamer.gd`
- `tools/compile_streaming_map.gd`
- 各地图的 `chunks/index.json` 和生成 chunk 数据

修改：

- `root/root.tscn`：增加 MapStreamer。
- `root/src/root.gd`：切关时把当前 PixelWorld 交给 MapStreamer。
- `debug/creative/src/creative.gd`：活动区块坐标、切换和按块保存。
- `actor/canvas/src/canvas.gd`：地图编辑时固定 2048×1152、禁止扩容。
- 导出工具：收录 index 中的动态 chunk 路径。

首版不修改怪物、可搬物品、关节、portal、fall_death、SimulationRuntime 和 addon。

## 验收

- 首次只加载镜头所需区块，随后补齐四邻域；接近角落时及时补对角块，跨界不出现空白或无碰撞地面。
- 离开后内存回落；返回后地形破坏和绘画保持一致。
- 区块边缘无重复像素、空缝和明显绊脚。
- 边界往返不会频繁读写同一块。
- 保存失败时保留内存数据，强退后只接受最后一个完整文件。
- 窗口运行测整帧 p95/p99/max、工作集、保存耗时和单次 add_body_node 峰值。
