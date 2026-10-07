## 2026-10-05：碰撞破坏游戏规则与引擎接口核对

- 新增 map/src/collision_damage.gd：世界统一计算法向冲量破坏，不给 PBody 挂脚本；相对材料强度、有限对数支撑、方向性整像素删除计划。采用方案 B，未满像素的预算舍弃，不读写 aux。
- player_physics.gd 新增 collision_damage 与 apply_collision_damage(amount)，暂不接生命/死亡。
- 按已授权范围将最新 target/release/rapier_bridge.dll 部署到 native；两份 SHA256 均为 D3AA38A69C532BFCDC5314722A140DCFAA9BE82875A7E64F4984C44A231BB050。
- test/test_collision_damage.gd：19 项通过、0 失败，包含真实 Rapier 落箱、静压不破坏、冲量分配、材料/厚度、遇空停止和玩家伤害。日志 test/collision_damage.log；退出仍有 1 个原生实例泄漏警告。
- 现有 test/test_hand_physics.gd：49 项通过、0 失败。日志 test/hand_after_dll.log；其退出仍报告 554 实例泄漏与 5 资源占用，未作为功能通过忽略。
- addon 源码未修改。当前缺固定步完成通知与精确批量像素 fracture/节点渲染包装，已写 test/engine_collision_request.md。
- 尚未挂入主场景，尚不能在游戏中实际碰撞破坏；等引擎完成 request 后连接每步计算与统一提交。未宣称碎裂守恒或视觉破坏闭环已通过。

## 2026-10-05：改用现有接口，完成主场景接入

- 更正上一条结论：现有 PWorld.fracture() 与 Destruction.Damage.rect() 足够实现方向切槽，不需要等待新接口；删除此前创建的 test/engine_collision_request.md。addon 源码未修改。
- map/src/collision_damage.gd 负责固定步进、双方伤害计算、像素删除并集及矩形合并提交、碎片速度场和材质恢复、节点索引与地面渲染刷新。主场景只增加一个 CollisionDamage 子节点，不给每个 PBody 挂脚本。
- Ground、Box 与固化墨水使用普通可破坏材料；玩家身体和手不删像素，玩家仅累计 collision_damage；生命/死亡与剪切处理暂不接入。
- 固化检查发现 add_body_node() 不会把节点加入场景树；canvas_solid.gd 补上 add_child() 和世界位置，修复场景外遗留节点。
- 破坏自测最终 34 项通过、0 失败，覆盖真实 Rapier 碰撞、精确删除、碎裂、密度、速度场、动能不增加、实际主场景损伤、固化注册和节点归属。日志 test/collision_damage.log。退出仍有 2 个 ObjectDB 残留警告；不宣称引擎生命周期问题已全部解决。
- 手部回归 49 项通过、0 失败；日志 test/hand_after_dll.log。该测试退出仍有 554 个实例和 5 个资源残留。完整默认主场景另外运行 180 帧，无运行期脚本错误；退出仍有资源残留，日志 test/main_collision.log。
- 已运行带画面的主场景检查并查看截图：碰撞后地面/物块像素变化可见，玩家和三角形手仍可见。临时截图查看后删除。没有进行人工操作的完整玩法验收。
- 保留用户原有 project.godot 与 test/test_hand_physics.gd 修改；未提交 Git。

## 2026-10-05：碰撞破坏复杂度和性能修正

- 重现批量破坏问题：800×40 地面上删除 128 个锯齿像素，旧实现 33 次 fracture，单次 128.843 ms。每段还额外 rebuild，且丢失局部脏范围，造成重复全量渲染。
- commit 改为先对选中像素并集调用 clear_pixel，再复用 Destruction.local_connectivity / split、PBody.rebuild 与 PWorld.add_body。每个受损物体每固定步统一分片一次，每个保留体只重建一次。复杂度去掉切槽段数与全体扫描的乘法项；旧 _rectangles 与逐段 fracture 循环删除。addon 源码未修改。
- 保连通时传实际脏范围；发生分片时才保守全量刷新。节点表只在有破坏时更新，用字典判存活；渲染统一到帧末。线性冲量插值的权重和直接求和，删除临时权重数组。
- 射线先检查表面材质和预算，支撑饱和且路径成本达到未减伤预算后停止。未使用任意深度截断；大预算继续向后扫描。1024 层射线的等价性和大预算继续扫描纳入测试。
- test/profile_collision_damage.gd 提供固定输入、关闭破坏、实时挥手对照；同一锯齿用例最终 5.791 ms、1 次提交，约 22 倍改善。固定输入 600 步 OpenGL 主场景 mean 0.944 ms、p95 1.809 ms、max 7.768 ms；关闭破坏 mean 0.539 ms。是 CPU 固定步计时，不等于完整 GPU 帧耗时。
- 实时持续挥手仍有性能问题：开启破坏 600 步 mean 14.192 ms、p95 16.229 ms、max 40.906 ms，后半段实测 46～56 FPS；关闭破坏 mean 4.138 ms、约 163～165 FPS。破坏累计 calculate 23.89 ms / commit 34.03 ms，持续低帧的主要成本已经不在结算脚本。
- 定位第二原因：碎片 27/81 像素掉出地面后仍下落，速度 650；PWorld._compute_substeps() 以全世界最快物体为准，手部 ccd_max_motion=0.5 将全世界提升到 22 子步。源码中的 ccd_max_substeps=16 没有在该函数里使用，实际限制是 ccd_substep_budget=600。未擅自删除场外碎片、限制速度或降低抓握物理精度；不宣称全程不卡已解决。
- 破坏回归 37 项通过、0 失败，退出仍有 2 ObjectDB 残留。详见 test/collision_damage.log、profile_before_stress.log、profile_final_visual.log、profile_live_sweep.log、profile_live_sweep_disabled.log。

## 2026-10-05：实时实例检查、下砸数值与子步时序

- 只读识别用户正在运行的实例：Godot 编辑器 PID 29152，游戏 PID 223528，游戏启动于 03:54:56，remote-debug 指向 127.0.0.1:6007。已通过 PrintWindow 查看真实游戏窗口；运行日志没有帧耗时/子步指标，未声称已读取该实例内部 PWorld 状态。未关闭或重启用户实例。
- 发现已有手本体 layer/mask 都为 0，因此以 Weld 抓住 32×32 物块下砸进行校准；手是否也要有直接碰撞已向用户异步询问，未擅自修改碰撞配置。
- 发现碰撞点与位姿时序失配：world.step() 汇集多个子步的接触，而旧结算用整步最后位姿采样材料，可能漏掉真正撞击。游戏 _step() 复用已有 _compute_substeps / _substep_rapier，每子步立即计算损伤，再在固定步末对删除并集一次提交；addon 未修改。
- 数值改为 damage_scale=0.012、min_approach=300 px/s。校准旧 0.1：普通落下峰值 160 像素/5 层，完整下砸 288 像素/9 层；新系数普通落下不破坏，完整下砸实际删除 32 像素/1 层，物体数保持 5，没有产生碎片。测试是实际 PD、Weld、Rapier 与真实提交，不是合成接触。
- 破坏回归最终 38/38，校准验收 4/4。退出仍有 2/3 ObjectDB 残留。校准脚本 test/calibrate_collision_damage.gd，日志 calibrate_damage.log。
- 新默认值下实时空手连续挥动 600 步 FPS 162～165，CPU mean 4.246 ms、p95 4.785 ms、max 8.895 ms，无破坏和碎片。真实抓块反复下砸仍会达到 29 子步，后段 FPS 57，mean 7.720 ms、p95 16.429 ms、max 22.511 ms。不能宣称卡顿根治。
- 进一步定位马达冲量与 CCD 时序：功率按手和物块组合质量计算，但执行冲量先打在轻手，CCD 在关节求解前读取瞬时速度。试验了守恒的组合冲量分配；动态焊接相对角误差升至 0.210074 度，未通过 0.1 度验收，故完整撤回手部试验，没有降低测试门槛。恢复原施力后 49/49，通过角误差 0.019773 度；日志 hand_original_compare.log。原 hand.gd 未留下本次修改。
- 准备 test/engine_performance_request.md，明确全局 CCD、原生关节精度、轻量接触事件和子步快照/回调的具体源文件与验收，不再请求已有的批量破坏能力。
- 实时截图查看后删除，只保留测试脚本与日志；用户原有 project.godot、test/test_hand_physics.gd 修改未覆盖，未提交 Git。

## 2026-10-05 引擎 v0.3.5 更新、安装与性能复核

- 引擎仓库 fast-forward：f4f17c2 → 7714886（v0.3.5）；保留原有 DLL 本地构建状态，没有提交或发布引擎。
- 正常关闭 ink-2 编辑器后重新编译两个 DLL。构建脚本默认 D 盘缓存不存在，改用 test/rb_target；Python 设 PYTHONUTF8=1。MinGW 入口额外用 -static 编译，避免 libwinpthread-1.dll 缺失。安装后的两个 DLL SHA256 与引擎构建产物一致；已导入，未出现脚本解析或 DLL 加载错误。
- 游戏关闭完整 contact_events，改用 contact_info，在当前子步位姿下读取点和真实冲量，保持原 approach 判断及伤害公式。接入 fracture_pixels 与 sync_world_bodies，删除自制分片/节点对齐代码；collision_damage.gd 从 342 行减至 312 行。未修改 hand 控制或 addon 源码。
- 新批量接口未完整继承材质摩擦/恢复、mask/gravity 等；暂通过公开 refresh_mass 和属性赋值保持旧游戏规则。地形断块恢复为动态；避免额外 burst 能量。新增材质及碰撞属性回归。
- 同版本、同 600 步动作实帧对照：事件开启 mean 7.801ms / p95 16.452ms / max 47.768ms，后段 56～64FPS；查询路径 mean 1.207ms / p95 1.927ms / max 35.800ms，后段 160～165FPS。两组末态像素、速度、物体数相同，CCD 峰值均 29。主要持续开销来自接触宽度/应力重复扫描；仍有破坏瞬间尖峰，不声称所有规模已无卡顿。日志 update_events_live.log / update_slam_live.log。
- 游戏破坏 39/39，真实下砸校准 4/4（普通落下不破坏，完整下砸 32 像素、深 1 层），抓握 49/49。引擎新增信号/掩码破坏/同步/detach 闸门结果符合预期（7 次信号，12/10/4 断言）。部分上游测试和旧手部测试退出仍报告资源残留；碰撞和校准测试已无脚本错误或退出残留。
- 白色裂缝仅讨论。用户选择沿撞击方向贯穿局部厚度后才更新该处碰撞；未实施。需要独立视觉掩码，不能先删除权威实体像素；收益是延后形状重建，基础碰撞/CCD 成本不变。
- 临时 Rust 缓存位于 test/rb_target，已加 .gdignore。自动执行策略拒绝清理该目录，未继续删除；可作为下次编译缓存。其余源资源未删除。

## 2026-10-05：接触借力移动、HUD 与抓地振动复核

- 按确认规则重写 player_input.gd：AD 只在身体下方真实接触处施力，不用射线/像素扫描；松键无主动刹车，悬空 AD/跳跃无效。双方同一个实际接触点受等大反向冲量，允许自然转动，手脚功率独立。移动目标从210降到100，最大力150万，脚部功率42亿，跳跃冲量90万（另受功率预算约束）。没有增加角色移动/攀爬专用状态层。
- 接触借力测试使用原生实际贴合的 Player/Box：成对力、跳跃反作用、线/角动量、主动做功与能量预算、无输入刹车、真实分离和 HUD 共18/18通过；不是仅合成接触测试。脚部规则只复用碰撞结算器已取得的轻量接触。
- 普通 Ink 抗破坏强度100→200，手/身体的0强度保护不变；普通落下和原先一层损伤的完整下砸均不再删像素。校准4/4，破坏39/39，原抓握49/49通过。旧手部测试退出仍有资源残留警告。
- HUD 用 Main/HUD CanvasLayer + Stats Label，固定屏幕右上角，显示FPS、Process耗时、CCD子步、手/脚实际与最大功率、作用力；字体/锚点设在场景。实机2560×1600截图已确认HUD可读。抓握和目标计算没有改变；只把输入、手、世界的执行顺序改用正确的 process_physics_priority，手视觉在求解后更新，避免先读上一物理步。
- 实证引擎 sync_world_bodies 会生成已有三角形手的矩形贴图。游戏最终prune暂排除Arm/Hand的内部渲染，保留原三角形；未修改addon。Request写入 test/engine_performance_request.md，包括引擎源路径、函数、复现和验收。碰撞一帧闪烁尚未录帧确认具体根因，不能宣称全部解决。
- 新斜向抓地实帧600步：向右借力94.152px，FPS163～166、固定步mean1.514ms/p95 2.647ms/max3.774ms，CCD峰值53。Weld误差仅0.000015px，但去趋势振动26.934px，Hinge误差0.248822px、Slider角差-1.594412度，振动验收失败。脚无输入且已无主动刹车，故刹车不是唯一原因；旧49项不能覆盖此工况。
- 多因素诊断仅在test：内部Arm质量4→84仍振动25.699px；静态连杆轴向力投影反而振动50.442px、臂长165.136px并造成额外地形破坏。均未改入游戏，不降低0.25px振动门槛，也未加锁速度/瞬移补丁。日志 ground_original_arm.log、ground_heavy_arm.log、ground_axial.log，纳入Request共同排查控制反馈与引擎关节限位/质量比。
- 实帧使用脚本驱动抓握目标；Canvas原有左键绘画也使用抓握左键，真实鼠标在Canvas内的双重输入路径没有在该性能数字中覆盖，未擅自改变Canvas规则。
- 临时截图 test/hud_check.png 的清理被执行策略拒绝，保留在test；未尝试其他删除手段。未提交Git。

## 2026-10-05：实际输入回归与力矢量观察

- 用户报告无法移动、落地后第二次跳失效；旧18项成对冲量测试调用 apply_input，未覆盖完整自动步进中的地面摩擦和身体翻转，因此不能据此宣称实机移动通过。
- 自动场景复现：150万推力低于默认摩擦0.5、质量6144、重力600对应的约184万静摩擦上限，120帧只移动1.907px；施力分支每帧都执行。最大力改300万，保留100目标速度、脚/手独立功率、自然接触力矩、空中无借力和松键无主动刹车。
- 第二次跳失败不是休眠：身体旋转180度后，局部+Y下半身判定把世界下方接触排除。改用世界点相对身体质心的Y判断下侧，没有增加状态补丁。
- test/test_live_input.gd 保留所有自动物理/输入回调，使用 InputEventKey（physical_keycode与keycode均模拟正常按键事件）驱动D和空格。OpenGL实帧两秒移动165.201px，翻身落地后两次跳均进入施力分支、起跳速度约-97.9；6/6通过，无脚本/清理错误。仍未使用操作系统硬件输入，因此不声称已操作用户原有实例。成对冲量与功率测试18/18复核通过。
- 左右虚拟鼠标、悬空竖杆抓地分别独立场景：横向位移仅约±0.035px。身体确实得到±7.9M主动反力，约束余项给出近乎相反的力；此时无脚部摩擦。Weld固定手角度、Slider固定杆/手角度，导致杆的世界方向被锁定，这是游戏自由度冲突，不能归咎于力偶配平或直接提交为引擎bug。已询问用户放开哪处转动，未改抓握规则。
- 新增 map/src/force_debug.gd，作为 Main/HUD/ForceDebug 单节点力观察器，F3开关。P/D按实际力/功率限幅比例分别记录；脚部AD/跳跃成对冲量、重力、每子步接触法向与摩擦分别显示。约束余项由固定步线动量差减去已知冲量求得，不冒充逐关节精确反力。引擎矢量查询Request补入已有文档。
- 调试采样复用现有接触数据；用字典按刚体与分量合并，复杂度O(接触点+刚体)，关闭时不采样/绘制。没有修改addon、增加通用Body包装或攀爬状态。
- 实际查看OpenGL截图，修正HUD/世界转换中的全屏重复缩放，箭头现在位于身体/接触位置；图例分两行避免遮挡右上HUD。截图复用 test/hud_check.png，临时工具仍在test。未提交Git。
- 力观察器排除双方均静态/休眠的流形冲量缓存，休眠体不计算动量余项，避免把上一活跃子步的接触冲量重复显示为新力。数值改为左侧逐行彩色表，世界中只画箭头，避免多个小分量标签重叠。

## 2026-10-05：移动加倍与Q旋转模式细化

- 用户明确要求AD、跳跃加倍及参数export；PlayerInput最大移动力300万→600万、目标速度100→200、跳跃冲量90万→180万，均保留@export。脚部最大功率42亿→168亿：双倍起步冲量需要四倍动能预算，避免只改冲量却仍被旧功率预算裁回。手部上限未改。
- 自动步进按键回归：两秒移动294.282px，末段横向速度196.254；首次起跳速度-205.608，翻身落地后再次起跳-220.417。输入6项通过，成对冲量/动量/能量/独立功率18项通过。
- 旧诊断要求120帧中至少100帧施力，加力后自然转动/间歇离地仅91帧，因此改为确认确实进入过施力分支；真实位移检查仍保留，空中无借力由18项回归验证。没有为了持续施力增添空中移动。
- Q模式按用户要求先细化，不实现：确认末端转动位置、沿用PD成对力或额外角度控制、按次切换/按住及关闭时锁当前相对角。推荐保留手与物体角度绑定，开放杆/手末端转动，沿用现有PD成对力；不先加独立旋转马达，若需角度PD也须纳入手部总功率。等待用户确定。
- 解释上次hand增加的代码：3个debug矢量字段和限幅后的P/D分解及最终力记录，只用于ForceDebug观察，没有改变关节或施力规律。本轮没有继续给hand加代码；之后每次新增先解释用途与改动范围。

## 2026-10-05：接通Q抓点转动与Tab调试、1% low

- 用户确认Q打开允许手相对物体转动，鼠标左侧使身体向右借力。hand新增export rotate_grip默认false、change_mode按次切换及set_rotation_mode：关闭Weld，打开指尖Hinge；已有抓点按当前锚点重建，保留位姿速度，关闭锁当前相对角。松手后保留所选模式，下次抓握继续使用。
- 转动采用现有PD成对力驱动，未另开Rapier角度马达；力与功率上限沿用手部规则，没有双重驱动。用户已在新增前获告知用途：模式状态、输入、关节切换函数。新增惯量分支也先说明：Hinge固定抓点仍可绕指尖转动，不能沿用静态Weld零惯量；动态Hinge不按焊接组合体合并质量。静态Hinge计入I_hand+m_hand*r_tip²的转动动能。
- Q真实按键事件加自动物理测试：左鼠标一秒使身体向右112.75px，右鼠标向左127.01px，分别8/8通过；峰值臂长95.32/108.56px，最大手功率420M未超，抓点误差约0.00002px。关闭模式没有位置或速度重置。
- Q抓地抬升测试8/8：身体上升67.499px，臂长峰值147.500<160，功率峰值420M，抓点误差0.000015px。此为一秒功能与上限回归，不宣称已经完成全地图爬坡、长期抖动或Q模式全系统能量验收。
- HUD读取现有debug(Tab)映射，统一切换文字和箭头；隐藏后停止力矢量采样绘制，移除ForceDebug旧F3处理。新增1% low：墙钟帧间隔，最近约10秒，最慢1%帧时间的平均值取倒数；100帧前显示--，0.5秒刷新，队列游标避免每帧搬移。UI另显示Q开关状态。
- test_game_control增Tab隐藏/恢复与1% low定义验证（99帧10ms+1帧100ms应为10FPS），含原动量/功率等检查共21/21通过。新输入测试中修复了同帧复用可变InputEvent的测试错误，使用新实例并跨帧释放/按下，没有游戏输入补丁。
- OpenGL实帧输入6/6通过，截图实际确认右上1% low和Q状态完整可读；截图示例FPS165、1% low94（包含启动与测试过程），不作为纯游戏稳态性能结论。临时截图仍复用test/hud_check.png。
- 解释数值单位：玩家质量24*32*8=6144，重力600px/s²，重量3686400内部力单位；百万数值不等于牛顿，也不直接增加运算复杂度。风险主要是比例、惯量、过大运动触发CCD子步和float32精度，而非当前量级的浮点溢出。本轮没有修改引擎或按量级重缩放材料。

## 2026-10-05：真实画布性能复现脚手架与清理

- 按用户要求先搭脚手架，未用生成多边形冒充卡顿样本。Canvas增加F5保存、F9加载，默认res://test/canvas_capture.tres，capture_path可export修改；保存CPU Image为.tres，保留尺寸颜色透明度，加载仍为未固化墨水。canvas_surface增加save_ink/load_ink，Canvas负责按键路由；未给hand增代码。
- test_canvas改为现有main场景，使用真实InputEvent F5/F9验证：改变画布尺寸后加载恢复320x180，像素字节完全一致，随后可固化。只将小笔划保存到user://canvas_roundtrip.tres，不占用用户真实capture路径。清理测试生命周期，退出无脚本/资源泄漏错误。
- 重写现有test/profile_collision_damage.gd为文件复现：180步固定抬举，读回开关/形状矩形数，记录手、世界步、原生推送求解读回、接触和结算时间，单步超过2秒终止。不存在真实capture时退出提示，不执行替代性能实验。小笔划只跑一次脚手架连通性smoke，未据此宣称真实性能正常。
- 核对当前实际运行路径：CollisionDamage接管_substep_rapier；contact_events显式false，profile/rp_debug/shading为false，soft_ccd=0，sleep=true，ccd=true，rp_ccd_substeps=1，hand设ccd_max_motion=0.5。并非全部开关打开。
- 源码复杂度候选：native逐索引contact_get_points每次从头遍历接触对，全部查询累计O(P²)且逐子步重复；引擎和游戏重复查询接触数量；lanes按点排序/接触宽度展开，trace按深度*形状数访问；复杂体矩形数量与全局CCD子步共同放大原生求解和接触查询成本。
- 另确认抓取CCD成本预算仅针对world.grabs，游戏用Joint而grabs为空，因此预算未覆盖当前hand抓握。具体贡献仍需真实形状消融，未修改addon或关闭CCD作为修复。调查路径/顺序追加到现有test/engine_performance_request.md。
- 清理已被替代且无脚本引用的3组临时脚本及UID：capture_hand_visual、capture_ground_pushup、reproduce_tilted_stack；清理5张旧PNG及import：editor_canvas、box_pushup、ground_pushup、hand_visual、hud_check。删除通过原生Remove-Item在已校验test绝对路径内完成；此次有用户明确清理授权，执行允许。保留物理/抖动/破坏/输入核心回归。旧profile的Axial/HeavyArm分支随重写移除。
- 已向用户提出F5/F9路径与真实样本请求。当前test/canvas_capture.tres不存在，真实性能消融等待用户画出并F5保存；不把样本缺失当作测试通过。未提交Git。

## 2026-10-05 F5真实不规则物体性能消融

- 用户保存canvas_capture.tres后，实测3770像素/275碰撞矩形。仅扩展test/profile_collision_damage.gd：自然提交、同步、渲染tile、CCD源头计时；加入--slam、--cut、--no-sync。未改游戏控制、材料或addon。
- 抬举平均7.029ms/P95 11.960ms/峰值39.900ms，原生推送-求解-读回约82%；轻手求解前1556.281px/s而被抓物体0，触发52全局子步。仅诊断关闭CCD后平均0.355ms，不作为防穿修复。
- 损伤尖峰的最大单项是800×40底板13/13贴图整图重绘约20ms；关闭全部sync后同一下砸峰值39.312降为19.051ms。原--no-render没有覆盖sync_world_bodies内部强制渲染，已纠正消融漏项。
- 真实形状受控切37像素，新增3碎片。带窗口live：fracture_pixels 7.961ms、额外refresh_mass 0.856ms、sync 3.454ms，后继物理帧2.612ms。独立拷贝split3.733ms、质量0.780ms、矩形分解4.322ms，仅作算法诊断不可相加替代接口总计。
- 本样本自然下砸只产生局部损伤，没有新碎片；真正断裂为明确标注的受控接口测试。没有复现秒级卡死，不把CPU段耗时当整帧GPU/FPS。日志无脚本错误，有已有Camera2D插值回调警告。
- 详细优化Request写入现有test/engine_performance_request.md：局部脏范围，Joint组CCD调度，去重复rebuild，原生细分计时。没有提交git或改引擎。

## 2026-10-05 引擎接口与性能开关复核

- 读取引擎AGENTS、v0.3.5发布说明、性能手册及实际调用。安装脚本与本地引擎的差异是资源路径重写和去class_name，没有发现该处功能未更新。本轮未fetch/构建/覆盖，源仓库两DLL已有修改未触碰。
- 事件/profile/rp_debug/shading关闭，休眠开启，GPU常量关闭且掩码破坏接口直走CPU。ccd_max_substeps、ccd_auto、ccd_clamp_motion、ccd_max_rotation、fill_contact_impulses_enabled、profile_enabled目前仅声明未读取；文档不能代替源码确认。
- 仅既有测试新增--inactive-off与--engine-motion。顺序180步同批次：baseline均值10.091ms；残留bool关10.322ms；2px CCD步长3.639ms/子步52降13；事件开24.473ms。恢复2px约快2.8倍但改变轨迹，未验证薄壁与稳定性，不改hand生产配置。
- 接口已接通contact_info和fracture_pixels；前者内部两次op35，后者仍CPU分片。节点固定步信号不会由游戏手动子步路径自动发出。auto_render不覆盖sync_world_bodies内部强制渲染。详细表与Request追加现有test/engine_performance_request.md。

## 2026-10-05 统一游戏CCD步长

- 按用户要求删除actor/player/src/hand.gd::_ready中的ccd_max_motion=0.5及对应注释，由引擎默认2.0统一控制。本次未改手质量、最大力、功率或损伤冷却；历史消融脚本的显式步长对照保留。
- 真实画布profile运行读回motion=2.0，180步平均2.419ms/P95 4.003ms/峰值34.621ms，最大13子步。损伤整图同步尖峰仍存在。
- 手部测试48通过/1失败：dynamic/weld relative angle最大0.122076度超过原阈值。未放宽阈值，也未新增控制补丁。测试退出还报告549 ObjectDB和3资源残留，性能脚本退出没有该残留；不能宣称全验收通过。
- 向用户区分同一步像素并集去重、跨固定步的新损伤提交，以及fracture_pixels后refresh_mass造成的重复rebuild；冷却尚未实现。

## 2026-10-06 更新安装stable v0.3.6

- fetch origin后，stable快进7714886→0785037(v0.3.6)。origin/main另有b8e0ecb，保持stable发布路线，没有安装未发布main。
- 原插件及源仓库两个已有修改DLL备份到T:/GODOT/bag/ink2_backup_20261006_036，项目外备份避免重复加载。build_addon.py --verify通过(32脚本/90内部引用)，安装生成文件，保留游戏原.uid及原生配置。该版本无原生源码改动，两个已安装DLL与源仓库本地DLL哈希相同，未重编译DLL；运行中的编辑器332572未终止。
- 游戏新进程：Canvas保存/加载/尺寸/固化PASS；真实3770像素/275矩形cut删37像素、新增3碎片。CPU均值3.701ms/P95 7.786ms，最大56.173ms主要为底板同步33.176ms；当批主机负载变化，不据此断言新版退化。子步最大13，motion=2.0。
- HandPhysics仍48pass/1fail，Weld相对角误差0.122076°超0.1°，与升级前一致；其测试退出仍549 ObjectDB/3资源残留。未放宽测试、未增加控制补丁。
- 说明CCD为高速连续检测，不是额外手；全局子步与原生CCD并存，但前者还服务约束精度。限制子步可能穿透或增加约束误差，不能保证靠旧未读取clamp开关兜底。
- 屏幕外冻结规则通过异步问题待用户确认。当前只有删除型cull_outside，没有独立可恢复禁用body接口；不能用隐藏、awake=false或直接删bodies冒充冻结。本轮未实现冻结。

## 2026-10-06 启动报错修复及窗口性能复测

- 真实godot.log与正常主场景复现Cannot get class RapierPhys，继发Nil.get_reference_count/cmd错误。根因是上次安装错误复制生成物根.gdignore，插件重新扫描时被忽略，extension_list为空。删除该文件并运行headless --editor --import --quit，重新确认扩展注册路径。承认安装遗漏，不归因引擎物理。
- main.tscn仅移除PixelWorld外部脚本失效UID，保留固定路径。正常主场景无头和带窗口各180帧运行，最终startup036_final.log错误与invalidUID数0，仅已有Camera2D插值warning。未终止用户332572编辑器及其旧运行进程。
- 窗口性能同批：slam平均4.327ms/P95 6.689ms/峰值56.283ms，底板同步35.345ms；no-sync同一损伤帧20.866ms；无伤害最大8.123ms。cut-live平均3.757ms，删37像素生成3碎片，fracture13.298ms/refresh1.390ms/sync5.923ms，物理子步峰值13。
- 主机时序与旧批不同，不声称更新使某项快/慢多少倍；持续帧与损伤峰值区分。下一步主要优化局部脏范围与去重复rebuild，尚未改引擎算法。
- 已记录现有engine_performance_request.md。后续安装排除.gdignore，必须扫描后验证正常主场景启动，避免旧缓存让测试假通过。

## 2026-10-06 编辑器实际F5闭环修复

- 用户旧编辑器332572从10/5 18:17持续运行。其主场景被改为旧UID d5tip6c722xe，对应map/main.tscn，仍引用materials和旧player/canvas脚本路径；扩展列表又缺失。此前正常新进程测试不能替代这个旧编辑器状态。
- 用户明确回复“已保存，可以重启编辑器”后关闭332572。备份project.godot及两份编辑器配置到T:/GODOT/bag/ink2_backup_20261006_editor。
- 搜索确认当前模块化场景不引用5个旧重复场景：map/main.tscn、map/main2.tscn、actor/player/player.tscn、actor/player/hand.tscn、actor/canvas/canvas.tscn。将它们按原相对路径移到上述项目外obsolete备份，可恢复；asset中的现行场景保留。
- project.godot主场景明确使用res://map/asset/main.tscn；清理编辑器recent_files与选中路径的失效条目，重新import。import退出有既有3资源残留，运行时没有该错误。
- 新可见编辑器391880(控制台父373200)已打开。通过窗口输入实际F5，生成子进程392196，命令明确--editor-pid 391880 --scene res://map/asset/main.tscn。新运行godot.log和editor_live_fixed.log均0个ERROR/SCRIPT ERROR/invalid UID；只已有Camera2D插值warning。扩展列表仍含fastphys.gdextension。
- 保留新编辑器及F5游戏供用户操作。临时窗口截图已删除，没有留额外美术资产。未声称整个手部物理验收通过，已有Weld0.122°失败仍保留。

## 2026-10-06 CPU优化实测（本地实现，未发布）

- 基线：已安装v0.3.6；引擎源码在main、HEAD 0785037上进行本地修改，没有提交或推进stable。之前两份本地DLL备份在T:/GODOT/bag/ink2_opt_before_20261006。
- `actor/player/src/hand.gd::_apply_internal_wrench` 改为覆盖PBody.control_force/control_torque，成对力进入Rapier子步积分，退出归零。以前先把整帧冲量塞给84质量的轻手，尚未求解Joint的瞬态速度让全世界CCD子步升到15；修改后同画布峰值4子步。保留CCD、碰撞、力和功率上限。
- `src/physics/pbody.gd` 新增独立执行器输出及additional_solver_iterations；`src/physics/pworld.gd::_substep_rapier` 通过op40设置局部约束岛求解精度。`gdext/fastphys.cpp` 与 `gdext/rapier_bridge/src/lib.rs` 实现该指令。手用32追加迭代，不增加全世界窄相检测次数。PD阻尼32->48；未加位置/速度锁。
- `src/physics/pworld.gd::fracture_pixels` 只处理修改的shape，已有局部连通性判据能证明连通时跳过全量split；无分片的损伤传实际dirty范围。重建统一计算材质摩擦、恢复系数，碎片继承layer/mask/gravity_scale；可选dynamic_fragments保持游戏地形脱落规则。`map/src/collision_damage.gd::commit` 因此删除重复refresh_mass及属性修补。
- `gdext/rapier_bridge/src/lib.rs::rb_contact_get_points` 原来查询第i对每次从头扫，取全部接触对是O(N²)。现在每步懒建一次ColliderHandle索引，body删除/碰撞体重建时失效；不缓存跨步冲量或裸指针。

### 三轮前后对照

真实`test/canvas_capture.tres`，3770像素、275矩形；两组各180帧、各三次新进程。断裂阶段删37像素生成3碎片，真实fracture+refresh+sync计入帧统计，副本算法诊断不计。旧版本仅用--legacy-refresh复现原先额外refresh。两组保留渲染和调试观察。

| 场景 | 原均值ms | 新均值ms | 原P95 ms | 新P95 ms |
| --- | ---: | ---: | ---: | ---: |
| 抬举后下砸 | 2.684 | 1.076 | 3.972 | 1.173 |
| 不规则物体断裂，窗口运行 | 2.391 | 1.353 | 4.370 | 1.967 |

两场景合计CPU均值提升2.09倍。下砸均值2.49倍；断裂均值1.77倍、P95 2.22倍。断裂场景最大帧35.450->15.084ms。新版一次首次启动第0帧出现202.174ms，已计入均值；该帧native计时1.130ms、无损伤或同步，未定位它属于初始化哪个阶段，不能声称所有卡顿已消失。其余两轮下砸均值0.708/0.700ms，峰值8.444/8.239ms。日志前缀opt_before_repeat_*、opt_final_slam_*、opt_final_cut_*；没有把CPU耗时倍数说成显示FPS翻倍。

### 验收

手部50项通过：Weld最大相对角误差0.026048度、动态承重晚期峰峰位移0.037750px；原0.1度和0.25px门槛保留。测试执行器代数配平改读持续力字段，长期实积分动量/能量/功率测试继续保留。脚部21项、碰撞损伤39项、真实AD/跳跃输入6项、Q爬升和Q横向借力各8项通过；Q爬升61.624px、最大臂长141.624px、功率不超预算。

引擎破坏17、动力学16、Joint56、接触点7、懒查询23、接触条目6、瓦片增量16、一致性4、连续几何检测14项断言通过；build_addon.py --verify校验32脚本90引用通过。部分旧引擎测试/编辑器import退出仍报RefCounted资源残留，和实际游戏启动错误区分；本次手部测试清理循环引用后无退出错误。

已更新两份DLL并核对源端与安装端SHA256一致；未复制生成物根.gdignore。可见编辑器403436真实F5生成377276，场景res://map/asset/main.tscn；编辑器与游戏日志无ERROR/SCRIPT ERROR/失效UID，仍有既有Camera2D插值warning。实际看到三角手、地面与力调试，临时截图已删除。保留编辑器和运行游戏。

## 2026-10-06 v0.3.8更新与摄像机冻结

- fetch确认origin/main与origin/stable均为91dc1ec、v0.3.8；本地main从0785037快进。旧修改保存在git stash `ink2 pre-v038 local optimizations preserved`及T:/GODOT/bag/ink2_pre_v038_20261006（含旧安装runtime）。没有提交或发布。
- 保留上轮持续成对控制力、局部32次追加求解、接触索引、碎片属性继承；采用新版adopt分片、按shape脏范围与冻结API。旧本地op40与官方joint_set_softness冲突，迁移局部迭代指令为op42，官方op40/41完整保留。源码统一重新生成安装，两份DLL源/目标SHA256一致。
- 官方build_native.py仍只静态链接gcc/stdc++，objdump确认依赖libwinpthread-1.dll，安装环境没有此文件。改为-static重新编译，消除加载126风险；未复制生成物根.gdignore，保留现有唯一.uid和根fastphys.gdextension。
- map/src/collision_damage.gd::_step使用实际Camera2D viewport.size/zoom，宽高乘freeze_view_scale（默认4、Inspector可调），以get_screen_center_position为中心调用world.cull_freeze(rect,[player.body])。判定整个AABB完全在外才冻结；相交继续计算。回到范围自动解冻；玩家及任意关节连通动态组件例外保持活动，释放后恢复普通剔除。
- 同步跳过冻结体，ForceDebug不采样/画冻结体的虚假重力；无新生产脚本。冻结仅暂停，保留形状、材料与线角速度，不删除存档中的物体。API仍保留碰撞体并按静态推送，不能称世界扫描/数据往返为零成本。
- 手50项、游戏控制28项（新增7个游戏冻结断言）、损伤39项、Q攀爬8项通过。冻结断言覆盖停住、速度保留、AABB部分重叠、玩家关节组件豁免、释放冻结、摄像机返回恢复、缩放改变边界。原重复手渲染的旧“重现bug”断言已改为验证新版引擎自动排除自有视觉，不放宽物理门槛。
- 引擎冻结19、破坏17、关节求解12、关节感知CCD12项通过。关节感知CCD默认仍关闭，没有借更新放松当前防穿规则。build_addon --verify通过32脚本90引用。
- 同一真实3770像素/275矩形画布消融（各180帧，单轮）：完整抓取下砸mean0.795ms/P951.197/max12.978；去损伤+力调试mean0.555ms；再去手部驱动mean0.360ms。动作因去手/去损伤而变化，仅诊断额外路径，不把它说成Demo帧率或纯单变量速度收益。窗口切断37像素产生3碎片，API6.216ms、sync3.153ms，包含真实切断的帧mean1.478ms/P952.231/max14.764，子步峰值4。
- Demo查源码：src/demo/game.gd::_process每60个渲染帧清理场外刚体并调用enforce_body_budget；默认目标400个动态体，预算仅淘汰休眠且未被抓的最小碎片（不是硬限制所有活动体）。_apply_impact_damage同一刚体对冷却0.5秒，每渲染帧最多处理1对破坏碰撞，该对可对多个contact_entries及双方多次调用fracture。圆形fracture规则与游戏每子步双方逐lane厚度/材质扫描不同；游戏也额外有PD手、连杆约束和力观察器。碎块个数不能替代矩形数、接触对、CCD子步与分片重建成本；没有认定Demo所有碎片不互相碰撞。
- 重启后的可见编辑器412800实际F5启动412956，--scene res://map/asset/main.tscn。editor_v038.log与当前godot.log无ERROR/SCRIPT ERROR/失效UID，仍有既有Camera2D插值warning。保留编辑器及游戏；无残留截图。

## 2026-10-06 引擎修改审计与上游 Request 文档

- 核对当前官方基线91dc1ec与本地完整diff，明确当前是v0.3.8加本地未提交补丁；引擎源码、公开字段、fracture_pixels签名、原生opcode42和两DLL均改过，不能再使用早期“没有修改addon”的描述。
- 新增test/engine_local_changes_v038.md，逐项说明修改路径/函数、持续控制力生命周期、局部约束岛迭代、接触索引复杂度、碎片属性/静态地面分离、构建链接与混装风险、备份和已有日志证据。
- test/engine_performance_request.md顶部加入当前有效R1至R7请求，保留历史记录并明确时效；Request尚未对外发送。提出compound矩形与多边形后端两个阶段，未实施。
- 核验当前源码和游戏安装两份DLL的SHA256分别一致；读回先前hand/control/damage/climb与断裂日志，未重跑物理测试，未修改生产代码或打断当前编辑器。
- 源码确认每矩形一个独立Rapier Collider；旧ink-fffight为BitMap轮廓+CollisionPolygon2D，epsilon2至8并只取最大轮廓，不能直接照搬保证1px结构。性能收益仍需相同轨迹A/B验证。
- 审查另发现同一PBody移除后重加时追加迭代同步缓存未重置的风险，写入修改说明和Request，未冒充已验证或本次已修复。

## 2026-10-06 13:44 场景归位与执行器参数说明

- 按模块边界把actor/player的player.tscn、hand.tscn，actor/canvas的canvas.tscn，map的main.tscn、main2.tscn从asset移到各自模块根目录。保留场景UID；更新场景互相引用、project.godot主场景与已有测试脚本。asset继续存放.tres等资源，没有移动插件资产。
- 给游戏全部export字段补齐##说明：用途、单位、力/功率区别、PD追踪/阻尼、臂长和求解余量、脚部支撑与跳跃预算、冻结倍率、HUD采样窗口、调试矢量倍率、画布尺寸/笔刷/颜色等。损坏重要参数改为export，保持原数值和原计算规则。
- 手部max_force从8000000提高到16000000，max_power从420000000提高到840000000，按两倍作为初始调整；PD系数、脚部参数不改。参数入口为Player/Arm/Hand/HandControl的主动马达分组。
- 新路径下test_hand_physics 50项通过，test_canvas保存/加载像素相等、尺寸/边界与固化通过。主场景无头运行180帧，没有解析或路径错误，但退出有549 ObjectDB泄漏warning与3资源未释放ERROR，不能称完整日志干净。
- 同时打开第二个headless editor import遇到~fastphys.dll复制/加载占用错误，后续扫描仍注册了扩展；没有关闭用户现有编辑器。保留scene_layout_import.log作为失败记录，不把这次import标为全通过。普通运行测试均成功加载Rapier DLL。
- 裂缝保持瞬间生成方向，讨论主干偏折/有限分叉/玻璃放射的区别及共享损坏预算；尚未选择最终形态，因此未修改裂缝算法。保留当前即时破坏/厚度规则，未添加贴图裂缝延迟重建方案。
- 固化接触规则用户接受重叠或共享边、允许连接地面；讨论Weld可避免重采样却仍保留两个PBody、重叠质量和约束开销。现有Weld默认关闭连接双方接触，未实现固化粘合、未改引擎。

## 2026-10-06 grey1 墨水资源

- 新增Ink/asset/grey1.tres：material id=4，color=(0.12,0.12,0.12,1)，接近黑色的深灰；密度、摩擦、恢复及抗压/抗剪与black当前属性相同，标记颜色不引入更强或更弱的焊接材料。
- map/main.tscn与map/main2.tscn注册该资源，直接复用引擎像素材质和渲染，不增加GDScript、标记节点或独立绘制通道，未修改引擎。
- 现有画布保存/加载与固化测试通过，日志test/grey1_canvas.log；仍有既有Camera2D插值warning，无脚本/资源加载错误。
- 当前CanvasSolid仍没有创建固化Weld及挂载像素管理；本次只完成用户明确提出的grey1资源与注册，尚未出现实际焊点灰色标记，不能称视觉挂载功能已经完成。

## 2026-10-06 GDScript/原生通信归因实测

- 用户要求核查引擎所说通信瓶颈。读取当前引擎规则、性能文档与源码，确认旧503体手写后端数据不能套到当前Rapier游戏；此前native_push_solve_read_ms计时包含GD命令准备、状态解码和包围盒，名称误导，测试输出标签已更正。
- 新增test/build_transport_probe.py生成test/transport_probe隔离副本：独立RapierTransportProbe类、测试专用opcode43、纳秒原生回调/管线/接触/状态/碰撞体计时。复用与生产SHA256一致的Rust DLL；生成物.gdignore防止编辑器扫描。未修改引擎真源或安装脚本/DLL，未结束用户编辑器。
- 扩展已有profile_collision_damage.gd的--transport与仅归因--probe-no-aabb。原版/计时版slam与cut各3次顺序独立进程、每次180固定帧；每组最终位置、速度、体数相同。另做3次跳过AABB不等价消融与1次计时入口复核。
- slam原版均值1.876ms、计时版1.867ms；每帧GD AABB/COM刷新0.742ms(39.8%)、Rapier管线0.419ms(22.5%)、命令准备0.0966ms、解码0.0223ms、包头0.0141ms、边界额外成本估算0.0046ms(0.25%)。180帧AABB矩形访问92349次。
- cut原版均值2.580ms、计时版2.654ms；GD AABB/COM刷新0.854ms(32.2%)、Rapier管线0.526ms(19.8%)、GD命令/解码/包头合计0.193ms、边界估算0.0088ms(0.33%)。割断删除37像素产生3新碎片；实际fracture API三次均值15.143ms、同步7.180ms；副本split/mass/greedy是另一次诊断，不能相加到API耗时。
- 跳过AABB均值降到1.065ms(约43%)，但轨迹和子步数改变：bounding_radius使用世界AABB，过期会改变CCD；禁止将消融当成生产修复。计时是CPU测量段，不是用户实机FPS，也不覆盖冷启动固化BAKE成本。
- 前三次探针CCD计时挂在world.step入口而游戏直接调用_compute_substeps，0值是计时入口错误；改为包围整个_compute_substeps，第4次确认2.206ms/180帧，无主项地位。错误测量保留日志并在Request明确说明。
- 当前样本不支持“DLL调用/字节传输本身是主要瓶颈”；宽泛GD同步与准备确实较重，最优先检查PBody.update_aabb及_rect_world_aabb的每矩形解释器与三角函数重复成本。建议原生精确AABB批量回读或等价缓存，未实施。
- test/engine_performance_request.md新增R8完整方法/数据/限制/引擎请求；test/transport_summary.json聚合原始日志。日志无ERROR/SCRIPT ERROR/未知opcode，既有Camera2D插值warning保留。生产两DLL哈希仍CE542B.../88A86C...，extension_list只含生产插件。


## 2026-10-06 新画布底部托举 Low 帧闭环复测

- 用户新256×256样本SHA256=2E1C7B5C35F5D0AE61286BA3FD5530044F62D812331EAD3A8835C20CD08E60DB，12485像素/12连通部分。测试保留全部部分，抓最底部1904像素承托体；另保留--largest最大体底缘对照。修正角色出生在底板外的旧测试摆位、指尖对齐，已实际查看游戏画面。
- --rendered使用真实物理回调/追帧与渲染间隔，600帧含第一采样帧，不能用CPU倒数冒充FPS。实际全屏2560×1600，60帧上限，关闭VSync；固化约150ms另列。截图会造成读回尖峰，截图轮不用于性能统计。
- 最底部原版持续托举59.65FPS，1% low28.06、max76.65ms；计时副本59.83/34.20/57.35ms。最底部下砸57.26/21.96/57.66ms；Q开启60.01/41.66/40.99ms；远目标59.67/30.00/72.78ms。底部体质心最高抬6.68px，远目标6.51px，随后被接触卡住，没有举起整堆，不能宣称完整托举验收或该抓点已复现持续卡爆。
- 最大体底缘下砸复测46.47FPS、1% low7.45、max149.79ms。最差第463帧CPU137.516ms，6次物理回调累计42子步：GD AABB50.567ms、接触取回/构造31.024ms、ForceDebug采样27.082ms、Rapier13.862ms，伤害提交0ms。调试绘制另约1.713ms/渲染帧。GD接触整理确实重，纯DLL边界/带宽不是最大项。
- 同轨迹600固定步开/关ForceDebug：CPU均值5.924→5.139ms(-13.2%)，600帧物体位置完全一致，子步1020/矩形访问858591/调用31965/碎片1相同。仅test消融，不改控制规则。
- 真实局部割断删除6像素生成1碎片，fracture4.635ms、加同步9.148ms，该帧实际渲染18.718ms；不代表大量碎片极限。详细函数、范围、命令及数据写入test/engine_performance_request.md的R9，汇总bottom_support_summary.json。
- 增加测试副本只读opcode44及ForceDebug分项计时，未修改hand/其他生产脚本、引擎源码或安装DLL。生产DLL仍CE542B.../88A86C...。未终止用户编辑器、未提交git。清理本轮截图与中途错误抓点/摆位数据，保留最终有效日志与帧数据。

## 2026-10-06 F1 手动低帧录制

- 按用户要求取消虚拟鼠标测试方式，录制直接接入map/src/hud.gd；project.godot新增record_low_frames映射F1，默认关闭，按F1开始/停止，每轮独立test/low_frames_时间戳.jsonl，HUD显示录制状态和低帧条数。
- 只按实际墙钟渲染间隔筛选FPS<24的帧。记录瞬时FPS/帧时、全部刚体位姿/速度/质量/矩形与形状数/冻结休眠/力矩，关节拓扑/限位，抓握对象/Q/鼠标相对目标/手部力与功率，以及最后子步计时。不会额外查询接触或遍历复制像素地图；记录开销另列previous_log_ms和game_ms，不能将后者冒充实际FPS。
- 一次短自检检查F1开/关、快帧不写入、实际15FPS时低帧产生可解析JSON及完整刚体/关节字段；4条低帧记录通过，最终无ERROR/脚本错误/资源泄漏。未使用虚拟鼠标。自检脚本与自检录制已清理，仅保留test/low_log_check.log。
- 没有修改hand、碰撞规则、物理参数或引擎安装。游戏重新运行即可手动录制。

## 2026-10-06 F1 低帧分项计时

- F1录制期间才开启累计计时；每个实际渲染帧分别记录物理总耗时、固定步/CCD子步总数、Rapier通信与推进、接触构造、损伤计算、破坏提交、节点同步、渲染同步，以及ForceDebug采样/收尾/绘制。
- 破坏记录同时包含提交次数、删除像素和新增碎片。停止录制立即关闭计时并清空计数；正常游戏不调用微秒时钟。
- 15FPS短自检产生6条低帧，日志包含physics_profile与force_profile；一帧示例为4次物理回调、4个固定步、12个CCD子步，累计物理3.432ms。自检通过，临时脚本与自检JSON已删除。
- 未修改物理规则、碰撞精度、hand参数、引擎源码或DLL。用户需要重启当前运行实例后重新录制一次。

## 2026-10-06 F1 实机分项结果

- 最新实机日志low_frames_2026-10-06T15-51-44_9301245.jsonl含32个低帧。最差228.623ms/4.37FPS；主要连续段641~658帧共18个低帧、2.590秒。
- 该连续段全程未抓握、无破坏提交、无节点同步，刚体18个、矩形852个。累计120个固定步被切成596个全局CCD子步；Godot因物理落后在一个渲染间隔内追赶到8个固定步，形成追帧雪崩。
- 连续段累计：_substep_rapier包装段1221.165ms（含GD命令/解码/AABB与Rapier，不能全部称原生内核），接触取回/构造483.163ms，ForceDebug接触采样499.802ms、绘制163.670ms。实际损伤余项很小，破坏commit/sync均为0。
- 另一段1074~1087帧才发生真实破坏：删除19像素、新增1碎片，commit14.979ms、节点同步5.873ms；它会造成尖峰，但不是本次最严重持续卡顿的根因。
- 结论：已排除“胶水断裂重建是主因”；未排除GD/内核胶水层，因为接触字典构造明确占大项，_substep_rapier仍需用隔离探针拆分。第一轮优化无需再次录制即可开始；修改后再录一次只作最终验收。

## 2026-10-06 16:14 Canvas大地图烘焙与重叠固化
- 新增 map/baked_map.tscn 与 map/src/baked_map.gd：同一 PNG 提供编辑器 Sprite2D 预览和静态 PixelBody2D 烘焙，可直接拖动。
- Canvas 保存键继续写 .tres，并额外写 map/asset/baked_map.png；固化时删除与全部现有 PBody 重叠的墨水像素，不创建 Weld。
- test/test_canvas.gd 通过：地图 152 px，重叠固化 rejected=152 且不新增刚体；非重叠 152 px 正常生成。Godot 编辑器扫描退出码 0，但旧布局仍引用两个已删除 asset 场景并报告既有资源退出警告。

## 2026-10-06 16:40 Canvas连续绘制与固化性能修复
- canvas_surface.gd 改为按住画笔时每帧按世界鼠标坐标补线，Camera/AD移动而屏幕鼠标不动时仍连续绘制；移除 MouseMotion 高频采样。
- canvas_solid.gd 修正 PixelWorld 节点层级为 world.world.bodies；重叠删除改为只扫描各刚体与Canvas相交区域，960x540全实心、删除34128像素的隔离测试为90.7ms。
- test_canvas通过，退出码0；临时性能脚本、UID和误生成的map/asset/baked_map.png均已删除。

## 2026-10-06 16:50 游戏层关闭CCD对照
- map/src/collision_damage.gd 新增 ccd_enabled，默认 false；同步关闭自适应CCD与Rapier世界CCD（rp_ccd_substeps=0），允许穿模用于性能对照。
- test_game_control物理控制检查全部通过；既有HUD 4项失败未处理。已启动可见实例 PID 42704 供实机抓取对比。

## 2026-10-06 17:07 CCD关闭后爆卡诊断与自动退出
- 最新低帧日志1957条有效记录无NaN/Inf；最差6.28FPS时62刚体、1214矩形、1907接触对、8次固定步、最高速度7928px/s，判断为穿透/高速密集接触叠加追帧正反馈。
- hand.gd补齐等效逆质量、质量和惯量除法守卫；hud.gd连续2帧超过500ms时保存一条hang JSONL并退出码2。
- Hand物理50/50、Canvas通过；看门狗注入2x600ms实测生成单行现场并退出2，临时脚本和测试日志已删除。

## 2026-10-06 玻璃裂纹
- map/src/collision_damage.gd 将同一碰撞面的多个接触点按冲量合成一次撞击，使用总冲量/接触宽度作为力度，避免 N 个接触点产生 N 份伤害。
- 力度生成 1~4 条主裂纹；方向展开、初始扰动和分段转角采用可复现伪随机，总破坏预算在分支间分配，不额外增加伤害或内核提交。
- 新增 5 个带 Inspector 说明的裂纹参数。真实 DLL 回归 41/41 通过，主场景 120 固定步 17.41 ms；普通落地、对称损坏、静压、动量和能量检查通过。

## 2026-10-06 20:51 - 实装可破坏钉子

- 中键在画布放置单像素 grey1 钉子；左键仍绘制，右键仍擦除。
- 含钉子的固化连通块成为静态体；破坏时把存活钉子传给引擎，未连接碎块转为动态，钉子像素被破坏后解除静态。
- 同步本次引擎构建的 addon 脚本；原生 DLL 哈希原本已一致。
- 验证：test_canvas（保存/加载、固化、分裂、钉子断裂）PASS；test_collision_damage 41/41 PASS；Godot 编辑器扫描通过。
- 修复安装时误带 .gdignore 导致编辑器 F5/F6 无法注册 RapierPhys；重建 extension_list，并更新 PixelWorld/PBody 场景 UID。主场景按编辑器启动链运行 180 帧无脚本错误。


## 2026-10-06 21:07 - 编辑器启动与退出闭环修复
- 旧编辑器再次清空 extension_list，新增 Ink/src/runtime.gd 自启动确认 GDExtension 注册，消除 F5/F6 对扫描缓存的依赖。
- 相机明确使用物理回调；CollisionDamage 在场景退出时清理 Shape/Body 引用环和原生世界。
- 故意移走扩展缓存后的带窗口启动通过；最终带窗口主场景180帧正常退出，无 ERROR/WARNING。钉子闭环回归 PASS。

## 2026-10-06 21:50 - Player与Hand像素烘焙
- 将用户命名的 player_body、player_hand_unfold、player_hand_grab 原图按16像素网格还原并等比缩放，烘焙为 actor/player/asset 下的 Image .tres；黑底作为空像素。
- Player的6个分离部件和展开手的3个分离部件作为同一PBody的多个Shape接入，编辑器与运行时共用PixelSprite视觉；抓握手资源保留给后续动画切换。
- 按新像素数补偿材料密度，实测Player 121像素/6144质量、Hand 56像素/84质量；指尖抓点对齐展开手最右端像素。
- 验证：HandPhysics 50/50通过；Jitter 8组完成且隐式控制静态段位移与高频RMS均为0；主场景无脚本错误，临时烘焙与验证脚本均已删除。

## 2026-10-07 01:04 - 主角烘焙重建（旧烘焙为什么坏）+ 仓库清理

- 旧烘焙坏在源头判读：`actor/player/asset/player_body.png` 实测背景是**透明** `(0,0,0,0)` 2639360 像素，黑描边反而是不透明 `(0,0,0,255)` 916480 像素。上一轮按「黑底作为空像素」处理，把整条线稿当背景丢掉，只剩灰色像素。实测 HEAD 的 6 张 body 图合计只有 89 个数据字节、3 张 hand 图 76 个字节，所以场景里主角只剩几个点，即「大小太小了」。
- 新烘焙脚本：`actor/player/src/bake_player_art.gd`（`extends SceneTree`，参数在文件顶部 `#region 配置`）。按 4 邻接连通块分别输出 `<prefix>_<i>.tres`，并打印每块 bbox 左上角 `position`，同时 prune 掉本次没生成的同名前缀 `.tres`。跑法：`godot --headless --path . --script res://actor/player/src/bake_player_art.gd`。
- 烘焙结果：player_body 网格 98x138、实心 4378 格、6 块（position 0,0 / 23,66 / 58,66 / 40,76 / 60,59 / 24,59）；player_hand_unfold 转 90°CW 后 54x46、实心 625 格、3 块（0,0 / 31,25 / 31,18）。黑线稿与灰像素全部保留。
- 「垃圾太多」的真因：一张图里放多个不连通孤岛时，`addons/pixel_destruction/physics/pworld.gd` 的 `add_body()` -> `ensure_connected()` 会按连通性把孤岛拆成**独立刚体**。旧烘焙把轮廓和眉眼嘴塞进同一张图，主角被拆成 6 个刚体、手 3 个，`world.bodies` = 12。改成「一块一个 Shape 节点」后 `world.bodies` = 5（Player 1 个多 Shape 刚体、Hand 1 个、Ground、Box、Arm），与 HEAD 原本的分块结构一致。
- 「不是黑色的」真因：`addons/pixel_destruction/nodes/pixel_sprite_2d.gd` 的 `rebuild()` 指纹 `_sig` 不含调色板，而 `pixel_world.renderer` 的 `add_child` 是 deferred，精灵先烘焙拿到 `render/pixel_renderer.gd` 的默认调色板（1 石 / 2 木棕 / 3 铁蓝灰），之后 palette 更新也不会重刷。已在 `player.tscn`、`hand.tscn` 的 `Visual` 节点上写显式 palette 修掉。
- 密度按总质量守恒修正：`actor/player/asset/player_body.tres` density = 1.40338（= 6144 / 4378）、`actor/player/asset/hand.tres` density = 0.1344（= 84 / 625）、`map/main.tscn:23` 的 `densities_fallback` 同步。实测 Player 质量 6143.998、Hand 84.0。
- 随之同步：`actor/player/src/hand.gd` 的 `FINGERTIP` 按新展开手重算 (14.643, 1.643) -> (24.201, 3.122)；`map/main.tscn` Player position (-128, 196) -> (-128, 90)；`test/test_collision_damage.gd` 的像素断言改为按块求和（body 4378、hand 625）。
- 清理：删掉 `test/` 下 10 个临时探针脚本与其 `.uid`（probe_dump_bake / probe_paint_chain / probe_paint_read / probe_render_owner / probe_scene / probe_shot / probe_shot2 / probe_shot3 / probe_split / verify_player_bake）、`.godot/imported` 里 32 个指向已删图片的孤儿缓存、空的 `map/asset/`、`user://dump`、`user://canvas_roundtrip.*`、仓库外 `T:\GODOT` 的 18 张临时截图。
- 实测验收：`test_collision_damage.gd` 41 项 0 失败；`test_canvas.gd` PASS；带窗口渲染整帧只剩 4 种颜色（奶油底 237,232,199 / 墙灰 220,217,204 / 纯黑 0,0,0 / 墨灰 30,30,30），棕与蓝灰完全消失，主角为纯黑线稿。
- 未通过/待确认：`test_hand_physics.gd` 46 passed / 4 failed，4 条全在 pushup 场景（body supported under gravity rise=-1.843；pushup late jitter peak_to_peak=1.436659；box pushup body climbs rise=24.985；box pushup late jitter peak_to_peak=6.288764），两次连跑数值完全一致，不是随机抖动；上一轮日记记的是 50/50，说明新碰撞几何（原先只有几个像素、现在覆盖 98x138 整个剪影）改变了 pushup 的接触，需要单独排查。`test_hand_jitter.gd` 8 组完成，implicit / damping 组静态位移与高频 RMS 仍是 1e-4 量级，explicit 组 0.24。
- 未做的三件事（需要用户点头）：`addons/pixel_destruction/native/~fastphys.dll` 是 Godot 热重载留下的旧副本，`fastphys.gdextension` 只引用 `fastphys.dll`，未删是因为它在被 gitignore 的引擎目录里；`actor/player/asset/player_hand_grab.png` 目前没有任何消费方（抓握切换还没做）；`pixel_world.gd` 里 `_body_nodes` 与 renderer 的对齐错位未改（精灵和 renderer 现在都画黑色，1px 重叠肉眼不可见）。

## 2026-10-07 01:43 打开CCD并交回世界层统一管理

- `map/src/collision_damage.gd`：删掉游戏层 CCD 转发开关（`@export var ccd_enabled` 及其注释、`_start()` 里对 `world.ccd_enabled` / `world.rp_ccd_substeps` 的两行覆盖）。CCD 交回引擎默认：`src/physics/pworld.gd:86` `ccd_enabled=true`、`src/physics/pworld.gd:712` `rp_ccd_substeps=1`。
- `map/main.tscn` Main(PixelWorld) 的 `ccd_ignore_mass` 由 `1.0` 改为 `16.0`。取值依据是引擎自身：`src/demo/game.gd:109`、`docs/manual/performance.md:183`、`docs/manual/cookbook.md:465` 都写 16.0；引擎全仓库没有 30。
- 实测（真实 `map/main.tscn`，headless 探针）：`ccd_enabled=true`、`rp_ccd_substeps=1`、`ccd_ignore_mass=16.0`、`ccd_max_motion=2.0`、`ccd_clamp_motion=true`、`ccd_substep_budget=600`、`rp_soft_ccd_prediction=0.0`、`bodies=5`，退出码 0；探针脚本与 `.uid` 已删。
- 未做：薄壁穿模与帧时间实测；`ccd_ignore_mass=16` 会允许质量 <= 16 的碎片穿墙（与"1px 结构不可穿"冲突，待定夺）；`PixelWorld` 仍未把 `ccd_enabled` 暴露到场景，要彻底"世界层统一管"需改引擎仓库。
- 注：改前的 `ccd_ignore_mass=1.0` 在 CCD 关闭期间是死值（`_compute_substeps` 直接返回 1，不构造豁免集合）。

## 2026-10-07 01:53 - 烘焙工具化（tools/ + doc/）

- 目录重组：根目录新增 `tools/`（离线工具，不进运行时）与 `doc/`（AI 给 AI 看的 md）；根 `readme.md` 第 11 行以下改成纯目录，原来的「文件组织 / 手的规则 / 验收」拆到 `doc/文件组织.md`、`doc/手的规则.md`、`doc/验收.md`，新增 `doc/烘焙.md`。用户自己的第 1-11 行一字未动。
- 烘焙脚本从 `actor/player/src/bake_player_art.gd` 迁到 `tools/`，拆成三层：`tools/bake_art.gd`（RefCounted 核心：取样 / 连通块 / 写盘 / prune）、`tools/bake_cli.gd`（SceneTree CLI 入口）、`tools/bake_editor.gd` + `tools/bake_editor.tscn`（`@tool` GUI：预览网格和每块 bbox，改格宽 / 旋转 / 放大后写盘）。旧的 .gd 与 .uid 已删。
- 核心新增：`analyse()` 多返回 `origin` 给预览对齐网格；`boxes()` 把 bbox 统一到一处（写盘与预览共用）；`write()` 加 `scale`（1 格 → N×N，无损，质量 ×N²，tscn 的 position 要同步 ×N）。
- 关键约束写进 `doc/烘焙.md`：一格只取左上角 1 点，源图必须是逻辑位图的整数倍最近邻放大；每块必须单独一个 .tres（`PWorld.add_body()` 会拆不连通形状）；判空只能看 alpha，不能看颜色（黑描边是不透明黑）。
- 实测：`--script res://tools/bake_cli.gd` 输出与旧脚本逐项一致（player_body 98x138 / 实心 4378 / 6 块 position 0,0 23,66 58,66 40,76 60,59 24,59；hand 转 90°CW 后 54x46 / 625 / 3 块 0,0 31,25 31,18，save 全 0）；连跑两次 10 个 .tres 的 SHA256 全部相同，0 处变化。
- 语法证据：`--check-only` 对 `tools/bake_art.gd`、`tools/bake_editor.gd`、`tools/bake_cli.gd` 均 EXIT=0。先用一个故意写坏的脚本验证 `--check-only` 真会 EXIT=1 并报 Parse Error，所以这三个 0 是有意义的。
- 未做：`bake_art.gd` 的 `components()`（4 邻接连通）与 `addons/pixel_destruction/core/destruction.gd` 的 `Destruction.split()`、`actor/canvas/src/canvas_solid.gd:42` 是同一件事的第三份实现。这次原样搬运，保证 .tres 逐字节不变、回归可归因；要不要改用引擎的 split() 待定。
- 环境备注（本轮踩到）：Codex 的 `apply_patch.bat` 直接调用会报 `Invalid patch: The last line of the patch must be '*** End Patch'`，必须直调 `codex.exe --codex-run-as-apply-patch`，且补丁用 `-join `n` 拼 LF（CRLF 会被判非法）。
## 2026-10-07 02:05 CCD 现状核对与两处纠正（未改代码）

- 纠正①：`ccd_clamp_motion` 在 v0.3.9 是**死声明**（`src/physics/pworld.gd:201`，全引擎只有 2 条注释 + 1 处声明，native 侧只有 `rb_body_set_ccd`/`rb_world_set_ccd_substeps`）。所以引擎注释里"绝不可能穿模的硬保证"不成立，真实上限只有 `ccd_substep_budget=600`（`pworld.gd:1637`），顶到 600 就没有任何钳。同类死声明还有 `ccd_max_substeps`(:88)、`ccd_auto`(:222)、`ccd_max_rotation`(:223)、`max_speculative_margin`(:241)、`_ccd_saturated`(:249)。用户确认是引擎忘记删，忽略。
- 纠正②：`ccd_joint_aware` 对 ink-2 的手-臂链**无效**——`weld_group`/`_group_motion` 只跟随 `PJoint.WELD`（`pworld.gd:2455`、`:1571`），而 ink-2 手-臂用的是 Hinge+Slider（`actor/player/src/hand.gd:97-98`）。只有抓握走 `add_weld` 时（`hand.gd:258`，`rotate_grip` 关闭）才成组，因此它只可能帮到抓取场景。不再把它当通解。
- 按用户要求"只用现有旋钮、不加东西、不动引擎"，CCD 保持现有引擎默认 + 场景 `ccd_ignore_mass=16.0`，未做任何修改。
- 真实 `map/main.tscn` headless 实测（探针已删）：`ccd_enabled=true`、`rp_ccd_substeps=1`、`ccd_ignore_mass=16.0`、`ccd_max_motion=2.0`、`ccd_substep_budget=600`、`ccd_joint_aware=false`、`rp_soft_ccd_prediction=0.0`、`bodies=5`；连跑 30 个固定步 `max_substeps=3`，退出码 0。
- 未做：帧时间与薄壁穿模实测；`debris_max_mass`/`debris_min_speed` 因 CollisionDamage 绕过 `PWorld.step()`（`pworld.gd:1664-1683` 里只有 `:1678` 的 `cull_fast_debris()` 没被 ink-2 继承）在 ink-2 里仍是死旋钮。

## 2026-10-07 01:57 - doc 改为按模块并列（修正上一轮）

- 纠正上一轮的错误理解：`doc` 不是根目录统一放，而是像 `src` / `asset` 一样按模块放在各自文件夹里。用户 readme 第 3 行原本就写着「src和assest还有doc」，是我上一轮读漏了。
- 移动：`doc/烘焙.md` -> `tools/doc/烘焙.md`；`doc/验收.md` -> `test/doc/验收.md`；`doc/手的规则.md` 拆成 `actor/player/doc/手.md`（PD / 抓握 / joint / 成对力）和 `actor/canvas/doc/画布.md`（可见性 / 固化）。
- 根 `doc/文件组织.md` 重写为约定：每个模块自带 `doc`，与 `src` / `asset` 并列；`tools`、`test` 是扁平工具目录，脚本摊平不另开 `src`；没有内容的模块不建空目录。
- 删除根 `doc/` 下 `手的规则.md`、`验收.md`（内容已迁到模块里）。现在根 `doc/` 只剩 `文件组织.md` 这一条仓库级约定，因为根目录本身也是一个模块。
- `readme.md` 目录改指新路径（第 14-18 行）；用户自己写的第 1-11 行一字未动。
- 核验：readme 里 5 条 md 链接全部 `os.path.isfile` 为真，无死链。
- 未建空目录：`Ink`、`map` 目前没有 doc 内容，不建 `doc/`。`actor/spring_water` 是空目录，不是本轮产生的，未动。

## 2026-10-07 02:12 ink-2 物理旋钮对齐引擎最佳实践

- 依据是引擎**自己文档化的整组推荐值**：`docs/manual/cookbook.md:461-466` 的 `px.configure({...})` 块，与它同源的是 `src/demo/game.gd:107-111`（demo 运行时那组）和 `docs/manual/performance.md:180-183,202`。引擎仓库未动：`T:\GODOT\bag\Godot_2DVoxel_Addons` 仍在 `85b79f7`（v0.3.9），`git status` 干净。
- 只改 `T:\GODOT\ink-2\map\main.tscn` 的 Main(PixelWorld) 三行：新增 `max_angular_velocity = 50.0`（原来吃脚本默认 1000.0）、新增 `min_fragment_pixels = 9`（原来是默认 4）；`ccd_ignore_mass = 16.0` 上一轮已是推荐值，不动。行序按 `addons/pixel_destruction/nodes/pixel_world.gd` 的声明顺序（58 -> 61 -> 65），文件保持纯 LF、无 BOM。
- 50 的理由：`pworld.gd:29-41` 写着 Rapier 2D **没有**角速度上限，而角速度是质量放大通道（Δω = J·r/I，I ∝ m），一个自转小碎片就能把全世界顶进几百个子步；引擎把 50 rad/s（8 转/秒）作为"别转到离谱"的推荐值。
- 9 的理由：推荐块写的是 9（不是 performance.md 里"闸门①"的默认 4）。已实证在 ink-2 生效：`map/src/collision_damage.gd:446-467` 的 `commit()` 调 `physics.fracture_pixels()`，后者在 `pworld.gd:3066-3067` 用 `min_fragment_pixels` 调 `Destruction.split`。直接探针：同一形状（16px 主体 + 4px 孤岛 + 9px 孤岛）在 `min_fragment_pixels=4` 得到 `[16, 4, 9]`，在 9 得到 `[16, 9]`，4px 孤岛被丢。**这是本轮唯一会改变玩法表现的一项**：断开后小于 9 像素的碎块（2x2、1xN、2x4）不再生成刚体。
- 没写 `debris_max_mass=16.0` / `debris_min_speed=2000.0`（推荐块里有）：它们在 ink-2 是**死旋钮** —— `cull_fast_debris()` 只在 `pworld.gd:1678` 的 `step()` 里被调用，而 ink-2 的 `CollisionDamage._step()`（`collision_damage.gd:133-166`）自己重写了推进循环（只调 `_compute_substeps` + `_substep_rapier`），`_start()` 里又 `_main.set_physics_process(false)`（`:69`）关掉了 `PixelWorld._physics_process`（`pixel_world.gd:510,521`）。写进场景只会是一条"看着设了其实没用"的配置，按"不要额外加东西"没写。
- 生效值实测（真实 `map/main.tscn`，探针跑完即删）：`max_angular_velocity=50.0`、`min_fragment_pixels=9`、`ccd_ignore_mass=16.0`、`ccd_enabled=true`、`ccd_max_motion=2.0`、`ccd_substep_budget=600`、`rp_ccd_substeps=1`、`debris_max_mass=0.0`、`debris_min_speed=0.0`、`bodies=5`，退出码 0。
- 风险实测（真实场景 600 个物理帧：按住 D 走 + 跳 + 抓住 Box + 手绕半径 70 摆一圈 + 中途按 Q 切旋转抓握）：`max_abs_angular_velocity = 13.64 rad/s`，**没有任何一帧有刚体越过 50**（0 次），`max_ccd_substeps = 8`。即 50 在这段真实玩法里有 2.7 倍余量，是纯安全网，不会钳到正常动作。
- 回归对照（A/B：改动版 vs 临时还原成改动前，各跑一遍）：`test_collision_damage.gd` 41/41；`test_live_input.gd` 6/6，加 `--grip --rotate`、`--grip --climb --rotate` 各 8/8；`test_canvas.gd` PASS；`test_hand_physics.gd` 47 passed / 3 failed，`test_game_control.gd` 28 checks / 8 failures —— 失败项与失败数值改动前后**逐字一致**，是玩家自己未提交的场景改动（Player 位置、密度表、HUD 布局）带来的既有失败，不是本轮引入。
- 未做：开窗口手动玩一遍（用户的编辑器进程在跑，改场景要重开场景/重启才生效，没有去动用户进程）；薄壁穿模实测；`test_hand_physics` 的 3 项 pushup 与 `test_game_control` 的 8 项失败仍未修（与本轮无关）。

## 2026-10-07 02:10 烘焙 GUI 重做 + 「虚空质量」结论（回复力矩 / 墨水图层待定）

- 用户评审上一版 GUI 是「垃圾、不是人能看的」。这次**真开窗口截图自检**（不是只看 `--check-only`），定位到 5 个真实缺陷并全修。
- 缺陷①（最致命）**根 Control 的 `custom_minimum_size=(1000,720)` 超过了项目的逻辑视口 960×540**（`project.godot` 的 `window/size/viewport_width=960` / `height=540` + `stretch/mode="canvas_items"`）。Godot 于是把它**居中**，实测探针打出 `BakeEditor pos=(-20.0, -90.0) size=(1000.0, 720.0)` 而 `visible_rect S=(960.0, 540.0)` —— 整个 VBox 上移，**顶部工具栏整条跑到屏幕外**、底部报告被切。修：tscn 去掉根 Control 的 min size（保留 full-rect 锚点）；`_ready` 里非编辑器时 `content_scale_size=(0,0)`（关拉伸）+ `mode=MODE_WINDOWED` + `size=1280×860`；预览 / 报告各自给 min size。
- 缺陷②**bbox 矩形坐标单位混算**：`Vector2(bound.position + origin) * zoom` 把「格」和「像素」直接相加。正确写法 `used.position + Vector2(bound.position) * (cell * zoom)`。这就是原截图里两个小色块跑到左上角的根因。
- 缺陷③**`zoom` 是 int 且被 `maxi(1, …)` 夹住**，大图永远放不下（手裁切后算出来 `int(0.84)=0` → 被夹成 1 → 底部被截）。改成 float 并允许 <1，加滚轮缩放（以光标为锚点）、左/中键拖拽平移、「适应窗口」按钮。
- 缺陷④块**没有编号**、配色用 `Color.from_hsv(i/n, 0.9, 1.0)`（i=0 是纯红，黑线稿上难辨）。改成 10 色高对比调色板 + 每块画编号 + 报告行用**同色 ■** 一一对应；报告塞进 `ScrollContainer`（250 高）不再抢预览空间。
- 缺陷⑤**浅底浅字**：项目清屏色是浅色，而 Godot 默认主题是暗色（浅色字），复选框「顺时针90°」几乎看不见（截图放大后确认文字在、只是看不见）。修：铺一层自己的深色 `ColorRect` 打底 + 用常量 `FG` 对 Label / CheckBox / RichTextLabel 显式 override 文字色。
- 验证手段：临时探针 `tools/_shot.gd`（`extends SceneTree`，第 30 / 70 帧各 `root.get_texture().get_image().save_png()` 一次，中间切到手的源图）跑**真窗口**渲染，body 与「顺时针90°」的手各一张，逐张看图确认：工具栏全可见、6 块 / 3 块编号与配色和报告一一对应、报告 10 行完整可见。探针用完即删（含 `.uid`）。
- 修 `tools/doc/烘焙.md` 的**错误示例行**：原文写 `player_body_0.tres position = Vector2(0, 0) 52x81 2199 格`，真值是 `98x138 3951 格`（52x81 / 2199 是被删掉的旧 `bake_player_art.gd` 的采样口径）。补上「手」那张的真实输出，并写明 position 是**格**坐标不是像素。
- **CLI 幂等实测**：同一个 shell 里 先算 11 个 `.tres` 的 SHA256 → 跑 `bake_cli.gd` → 再算一遍，**changed=0**，退出码 0，`prune` 没删任何文件。文档里的数字与 CLI 实际打印逐字一致。
- **「虚空质量」结论（全部有代码依据）**：不要直接写 `PBody.mass`。理由：①`physics/pbody.gd:474-475` 每次 `rebuild()` 都无条件写 `mass = m_total` / `inertia = inertia_c`，而破坏 / 切块每次都要 rebuild；②只改 mass 不改 inertia 会让质量与惯量不自洽；③Rapier 侧的质量来自**碰撞体密度**——`physics/pworld.gd:1058-1062` 每帧只在 `_rp_density != density` 时推 op34 `rb_body_set_density`（`addons/pixel_destruction/native/rapier_bridge/src/lib.rs:795-806`，里面含 `recompute_mass_properties_from_colliders`），所以写 `PBody.mass` 根本到不了 Rapier，两边会**静默分叉**（lib.rs:787-790 记着实测症状：密度 7.8 时一步过冲 8.4 倍、在 ±280 之间抽搐）。**正确旋钮是 Shape 的 `density_scale`**（`core/pixel_shape.gd:209-211`）：`core/mass_props.gd:94 / :145` 里 `d *= dscale`，于是 mass 与 inertia **同比**放大而 **COM 不变**（`com = Σd·p / Σd`，dscale 约掉），并经 `pbody.gd:478 density = m_total / n_px` 自动流到 Rapier，切块时还由 `core/shape_ops.gd:41` 继承。→ 墨水的额外质量 = 烘培时给 Player 的**全部** Shape 乘同一个 `density_scale`（pbody 是多 Shape 合并，必须一致）。
- 环境坑（本轮踩到，记一下）：`rg` 遵守 `.gitignore`，而本仓库 `.gitignore` 里有 `/addons/` —— 所以 `rg density_scale` 会**一条都不返回**，必须 `rg --no-ignore`。差点据此得出「这个旋钮不存在」的错误结论。
- 未做 / 未定：①`density_scale` 目前**没有 `@export`**（`nodes/pixel_shape_2d.gd` 只导出了 rect_size / radius / texture / alpha_threshold / material_id），Inspector 里调不到，只能靠代码或烘培给；②回复力矩的**腾空是否允许**、驱动上限是否压到 `F_crit` 量级；③墨水质量按「满瓶」还是「当前液面」—— 按液面等于每帧改质量属性，正是 lib.rs 警告的那类发散。

## 2026-10-07 02:17 真实窗口运行 + 编辑器同步（承接 02:12）

- 真实窗口跑（不是无头）：加载真实主场景 `res://map/main.tscn`，真显卡（RTX 4060）、真实输入（A/D、空格、鼠标左键、Q、Tab 全走 `Input.parse_input_event`），720 个物理帧，游戏自己截图存 `user://best_practice_run.png`。HUD 自报 `FPS 61 | 1% low 42 | CPU 14.7 ms | 子步 6`。
- 注意：`project.godot` 的 `run/main_scene` 是 `res://tools/bake_editor.tscn`（烘焙工具），所以"直接跑工程"不是游戏本体，必须显式指定 `res://map/main.tscn`。
- 运行实例自报的生效值：`max_angular_velocity=50.0`、`min_fragment_pixels=9`、`ccd_ignore_mass=16.0`、`ccd_enabled=true`、`rp_ccd_substeps=1`。
- 真实运行 A/B（同一探针，改动版 / 还原版各跑一次窗口）：改动版 `observed_max_abs_omega=4.25`、`max_substeps=6`、`bodies=5`；还原版 `observed_max_abs_omega=6.07`、`max_substeps=6`、`bodies=5`。刚体数与子步数一致，最大角速度离 50 还有 8 倍以上余量 —— 50 在这段真实玩法里是纯安全网。
- 编辑器同步：用户编辑器 PID 63084 开着的正是 `main.tscn`。本机没有原生 UI 自动化（`cua.getState()` 返回 `apps: []`），无法替用户点菜单；改为"重写文件刷 mtime + 把窗口焦点交给编辑器"触发它自己的重扫，并核验 `.godot/editor/filesystem_update4` 在写完后 1 秒（02:16:12 > 02:16:11）被重写且 delta 里含 `res://map/main.tscn`。
- 未验证：编辑器**内存里**那个 main.tscn 标签页是否已从磁盘重载（读不到编辑器内存）。风险：若没重载而用户按 Ctrl+S，会把 50.0 / 9 覆盖回 1000.0 / 4 —— `git diff map/main.tscn` 一眼可查，需要时一条命令即可补回。手动兜底：Godot 里 Scene -> Reload Saved Scene，或 FileSystem 面板右键 `main.tscn` -> Reload。
- 探针（`test/_probe_realrun.gd` 与 `.uid`）已删，仓库无残留。
## 2026-10-07 02:49 回复力矩定标 + 墨水图层收尾（承接 02:17）

- **回复力矩的根因**（这轮真正搞清楚的）：`_upright_angular_impulse` 施的是纯角冲量（`inertia·dω`），而重力对触点的倾倒力矩是 `m·g·h·sin(err)`。实测玩家 mass 6144 / inertia 1.5141e7 / COM(-82.5,156.6) / aabb 98x138，**h≈74 格 → 峰值 2.7e8**，是 `m·g·b`(1.81e8) 的 1.5 倍。之前 k=1.3e8~3e8 卡在 0.7~1.0 rad 不是控制器 bug，是力矩不够；旧注释把阈值写成 `m·g·b` 是错的，已改。
- **定标结果**：`k=1.0e9 / d=3.0e8 / m=6.0e8`（= `m·g·b` 的 5.5× / 1.7× / 3.3×）。kick=3 rad/s 一步回正（peak 0.07 rad）；kick=12 rad/s（整圈翻滚）也收得住，尾巴 tail_w 0.0008、tail_jerk 0.0011。限幅是必须的：不限流时瞬时力矩到 -1800 MN。三个值已写进 `player_input.gd` 的导出默认值。
- **回归**：加力矩后 `test_live_input.gd -- --grip --right --rotate` 的「opposite sideways movement restored」失败（侧移 >20 → 8.3）—— 抓住世界时手臂在用同一个姿态自由度，脚部平衡在对拧。加了「手抓住世界（`hand.grabbed_body != null`）时不施力矩」的门，四种组合全部 0 failures。
- **调参期的坑**：必须把 `CollisionDamage.min_approach = 1e12` 关掉破坏，否则摔倒把地面砸出坑，下一组落进洞里 `support_frames = 0`，会把「找不到支撑」误判成控制器失效。
- **新测试** `test/test_upright.gd`（17 检查）：正常撞击 / 极限翻滚 / 关掉必倒 / 腾空与手抓握时力矩恒为 0 / 不超上限。腾空那段用「起跳速度」而不是瞬移 —— 瞬移会被引擎当成速度，人直接飞出去并以 650 px/s 穿过地面（顺带发现地面挡不住 650 px/s，先记着不追）。
- **墨水图层**：`BottledInk` 完成（复用 `Visual` 的烘焙剪影 + shader 遮罩与液面，虚空质量走 `density_scale` + `refresh_mass` 并按液面量化），`test/test_ink.gd` 19 检查 0 失败。
- **清理**：删掉 `test/_tune_upright.gd`、`test/_diag_upright.gd`、`test/_diag_grip.gd`、`test/_diag_air.gd`、`test/_probe_ghost.gd`、`test/_probe_ui.gd` 和 3 个 `test/hang_*.jsonl`。顺手把 `debug_hud.gd` 的卡顿现场落盘从 `res://test/` 改成 `user://` —— 那是仓库里长垃圾的源头，导出版 `res://` 本来就写不进去。
- **文档**：新增 `actor/player/doc/墨水.md`、`actor/player/doc/脚.md`；`test/doc/验收.md` 补 `test_ink.gd` / `test_upright.gd` / `test_live_input.gd`。
- **未做 / 搁置**（都是本轮用户点的）：程序化动画（有没有 mask、相邻连通块不碰撞、连通块用物理连接 + 动画做物理控制）—— 先暂缓；液面抖动 —— 只留 shader 不写；质心微调 —— 搁置；连通块代码不合并且分开处理。

## 2026-10-07 02:49 主菜单 + HUD + ESC 三层 UI 移植（参考 T:\GODOT\bag\BackGround）

- 新增 `ui/` 三个模块（每个都是 asset/src/doc）：`ui/menu`（主场景菜单）、`ui/hud`（成品 HUD）、`ui/esc`（ESC 覆盖层）。`project.godot:14` 主场景改 `res://ui/menu/menu.tscn`；`map/main.tscn` 新增 `Hud`/`Esc` 实例、原 `HUD` 改名 `debugHUD`；`map/src/hud.gd` 改名 `map/src/debug_hud.gd`（Tab 分支删掉）；`map/src/collision_damage.gd:38` 跟随改 `../debugHUD/ForceDebug`。
- 等比缩放：参考是 4096×2560 逻辑视口，本工程 960×540，s=960/4096≈0.2344。字号 104→24、图标 96→22（HUD 退出 170→40）、边框 13→3、圆角 5→1、投影 7/13→2/3、边距 54/20→13/5；**锚点比例原样保留**。窗口 2560×1440 下 `canvas_items` 放大 2.67 倍，实测观感与参考 `preview.png` 属于同一套。
- 素材按批准裁切（未裁是两张 4096×2560、各约 210KB）：`ui/menu/asset/title.png` = title_logo.png 裁 (960,528,2368,1456) → 2368×1456 / 18.5KB；`ui/hud/asset/ink_jar.png` = health_ui.png 裁 (900,960,580,660) → 580×660 / 3.1KB；`health_frame.png` 裁 (1490,1000,1710,260) → 1710×260 / 2.4KB；`paper.png` 直接拷 notebook_background.png。三张裁剪图实测四角 alpha=0（透明底）。参考里没被场景引用的视差六层 / paper 着色器 / auto_scroll / 小屋门图 / sun·pencil·ink_bottle·resource_jar·pickup 图标一律没搬。
- **横条位置是算出来的不是抄的**：`HealthFrame` 用 `stretch_mode=5` 等比装填，锚点框 585.6×70.2 与源图 1710×260 比例不同 → 实际绘制框只有 461.8 宽、左右各内缩 61.9px。第一版照抄参考的 0.185..0.741，截图里黑填充从 frame 左侧冒出来；改成 0.2245..0.7055 对齐绘制框后，实测 `StatusBar.get_global_rect()`=(215.52,32.94,461.76,39.96)，与 0.16×960+61.9 逐位相同。
- Tab 按用户要求改成两套切换：`ui/hud/src/hud.gd` 读 `debug` 动作，`debugHUD.visible` 取反、成品 `visible` 取反、force_debug 采样同步；`debug_hud.gd` 的 Tab 分支已删，避免两个脚本同时响应同一个动作。
- ESC：`ui/esc/src/esc.gd` 读 `escape` 动作切换覆盖层，打开即 `get_tree().paused=true`（覆盖层 `process_mode=3`，暂停后仍收输入），继续 / 回主菜单 / 退出都先解除暂停。按钮底不透明：它是盖在游戏画面上的，参考那套 0.9 透明会把场景透出来。
- 回归（真实 `map/main.tscn`，headless）：`test_collision_damage` 41/0；`test_live_input` 6/0；`test_canvas` PASS；`test_hand_physics` 47 passed / 3 failed（与 02:12 记录逐字相同，既有 pushup 抖动/早退）。`test_game_control` 改前 28 checks/8 failures → 改后 29 checks/4 failures，剩下 4 条是 baseline 就失败的物理项（`actual partial foot contact acquired`、`walking pushes body and support oppositely`、`jump pushes support down`、`real separation clears support`，来自玩家未提交的 Player 位置改动）；原先失败的 HUD 文本 / 1% low / Tab×2 四条按新语义改完全过。
- 被改的测试：`test_game_control.gd`（节点名 + Tab 断言重写）、`test_live_input.gd`、`profile_collision_damage.gd` 的 `HUD/ForceDebug` → `debugHUD/ForceDebug`。
- 真窗口截图（`--windowed`，2560×1440，临时探针用完即删）：`user://ui_menu.png`、`ui_hud.png`、`ui_debug.png`、`ui_esc.png` 逐张看过 —— 菜单=横格纸+墨迹标题+开始/退出；HUD=墨水瓶+横条+框+右上退出；Tab 后成品 HUD 消失、调试文字出现；ESC 后世界变暗、三个按钮在上层且不透底。
- 功能实测（临时探针，用完即删）：菜单「开始」→ `current_scene=res://map/main.tscn`；HUD 退出按钮 → `current_scene=res://ui/menu/menu.tscn`；ESC → `paused=true, esc=true`；ESC→继续 → `paused=false, esc=false`；ESC→回主菜单 → `current_scene=menu, paused=false`；ESC→退出 → 进程退出码 0；Tab → `hud=false, debug=true`。
- 未做：设置面板（参考里那个按钮也只 print，按最小实现没搬）；血条/蓝条数据源（用户明确先不管，横条值仍由 `@Export bar_ratio` 给）；编辑器里手点一遍（用户 Godot 编辑器 PID 63084 一直开着，没动它进程）。
- 并发提醒：本轮中途 `test/_probe_ui.gd` 被并行会话当垃圾清掉（它同一时间新增了 `test_ink.gd`、`test_upright.gd`、`actor/player/src/bottled_ink.gd(.gdshader)` 等）；`map/main.tscn` 与 `map/src/collision_damage.gd` 两边都在改，重跑或提交前确认 `debugHud`→`debugHUD` 的改名和 `collision_damage.gd:38` 的 `../debugHUD/ForceDebug` 没被覆盖。

## 2026-10-07 02:55 — collision_damage 渲染归属：修掉移动/破碎瞬间的鬼影

- 症状：`res://map/main.tscn` 里玩家（自带视觉）被引擎内部渲染器**重复画了一份**，且那份贴图永不刷新 —— 玩家一走它停在旧位置，破碎那一下最明显（截图里同时出现两个墨水瓶）。
- 根因（真机取证）：`map/src/collision_damage.gd` 每帧末尾那段渲染块自带一套归属判据（`not body.is_static and not body.frozen and not _protected.has(body) and (node == null or not has_own_sprite(node))`），`prune` 只清死体和 `_protected`，**从不为跳过的刚体调 `renderer.forget()`**。而引擎 `PixelWorld.rebuild()` / `_apply_voxel_size()` 在场景加载时给**所有**刚体（不过滤）建了 holder，玩家那份就此永久停在原地。引擎在 `nodes/pixel_world.gd:471-475` / `:734-736` 正是警告这个。
- 修复（2 个文件）：
  - `map/src/collision_damage.gd:102-115` 渲染块改用引擎唯一判据 `PixelWorld.uses_internal_render(node)`（与 `rebuild` / `bake_node` / `sync_world_bodies` 同源），不归内部渲染器的刚体一律 `renderer.forget(body.id)`；`prune` 回到引擎的 `_main._live_ids()`；`_body_nodes[i]` 加长度保护。
  - `actor/player/hand.tscn:19` 的 Arm 补 `internal_render = false` —— 游戏侧不再用 `_protected` 当渲染过滤，Arm（4×4、无自带视觉）否则会被画成一个方块。引擎在 `nodes.md:397-404` 明确认可这个用法（"仅物理：不可见的臂/手"）。只加了这 1 行；该场景里手部 Shape 位置 / Visual palette 是用户自己的改动，没动。
- 验证（真机，非合成）：
  - 真窗口跑 `res://map/main.tscn`：`holders=[1:Ground, 2:Box]`，玩家 `id=3 player_has_holder=false`、`uses_internal_render(player)=false`（修复前 holders 是 `[1,2,3]`）；玩家平移后仍无 holder、`stale=[]`。
  - 走游戏自己的 `damage.commit()` 真破碎：`bodies 5→6`，`holders=[1:Ground, 2:Box, 6:碎片]`，`stale=[]` —— 碎片拿到自己的 holder，旧位置无残留。截图 `user://verify_1_moved.png`、`verify_2_fracture.png`：各只有一个玩家，切割后箱子分成两块。
  - 回归：`test_collision_damage.gd` `[CollisionDamage] 41 checks, 0 failures`；`test_canvas.gd` PASS；`test_live_input.gd` 6/0、`-- --grip --rotate` 8/0、`-- --grip --climb --rotate` 8/0；`test_game_control.gd` `29 checks, 4 failures`（全为脚部接触/支撑相关：partial foot contact / walking pushes support / jump pushes support down / separation clears support，与渲染无关；其中 `engine sync excludes hand with its own visual`、`game removes internal hand and arm renderers` 两条通过）；`test_hand_physics.gd` `47 passed, 3 failed`（与之前基线一致）。
  - 临时探针 `test/_probe_ghost.gd`、`test/_verify_ghost.gd`（含 .uid）用完已删。
- 未做/未查明：真窗口里把演示 `Box` 抬高 180px 以 2600 px/s 砸地面**没有触发破碎**（`world.bodies` 始终 5）；帧级采样看到 `contact_pair_count()=1`、`approach≈0`、`impulse≈103`（静止量级），撞击子步在帧内、采样抓不到峰值，也可能是冲量预算低于材质强度 200。这是既有问题，本轮没改，需要时另开。
- 编辑器同步：`map/src/collision_damage.gd`、`actor/player/hand.tscn`、`map/main.tscn` 的 mtime 已刷成当前时间并把 Godot 编辑器（PID 63084，当前开着 `baked_map.tscn`）置前；若编辑器没自动重载，手动 Scene → Reload Saved Scene。

## 2026-10-07 03:05 — F1/F5/F9 热键归属（用户提问）+ 文档补齐

- 用户问「f1 f5 f9 的按钮控制在哪个脚本」，答案（动作定义在 `project.godot`，处理在各自脚本）：
  - **F1** = 动作 `record_low_frames`（`project.godot:83-86`，physical_keycode 4194332）→ `T:\GODOT\ink-2\map\src\debug_hud.gd:113-115` 的 `_unhandled_input` 调 `_toggle_log()`（`:28-48`）。开始/停止低帧录制；只写帧耗时 > 1000000/24 µs 的帧（`:55-56`），每轮一个 `res://test/low_frames_<时间戳>_<usec>.jsonl`（`:37`）；录制期间同步开 `damage.set_profile_enabled(true)` / `forces.set_profile_enabled(true)`（`:43-44`），调试 HUD 标签第二行追加「F1 录制中 | 已记录 N 个低帧」（`:156-157`）。
  - **F5** = 动作 `canvas_save`（`project.godot:73-76`，4194336）→ `T:\GODOT\ink-2\actor\canvas\src\canvas.gd:36-38`：`surface.save_ink(capture_path)` + `surface.save_png(baked_map_path)`。
  - **F9** = 动作 `canvas_load`（`project.godot:78-81`，4194340）→ 同文件 `:39-40` 的 `surface.load_ink(capture_path)`。
  - 顺带：`E` 固化走裸键码不是动作（`canvas.gd:34-35`）；`Tab` 在 `ui/hud/src/hud.gd:22-30` 读 `debug` 动作切换成品/调试 HUD。`capture_path` 默认 `res://test/canvas_capture.tres`（`canvas.gd:27`，当前磁盘上不存在，第一次 F5 才生成），`baked_map_path` 默认 `res://map/asset/baked_map.png`（`canvas.gd:29`）。
- 文档补齐（本轮只改文档，不碰逻辑）：`ui/hud/doc/HUD.md` 加「热键」段（F1/Tab + 自动存现场）；`actor/canvas/doc/画布.md` 加「热键」段（E/F5/F9 + 两个导出路径）。
- 引擎仓库只读，本轮再核一次（不是凭记忆）：`git -C T:\GODOT\bag\Godot_2DVoxel_Addons` → 分支 `stable`、HEAD `85b79f7` = tag `v0.3.9`、`git status --porcelain` 与 `git diff HEAD --stat` 都为空 → 本会话没有改过引擎。
- 未做：本轮没有跑游戏、没有新增性能探针（用户自己用 F1 录制）。性能证据仍只有先前那次真场景 A/B（渲染块 2.36 → 4.93 µs/帧，约 +0.0026 ms；`_step` 0.955 ms/帧，整帧 process 均值 12.78 ms、p99 18.60 ms），本轮未复测，按「先前取证」看待。
- 旁注：工作区有未跟踪文件 `test/_shot.gd`、`test/_shot.gd.uid`，不是本会话产出，未经允许没删。

## 2026-10-07 03:08 — 查用户 F1 录制（第一份低帧日志）

- 文件：`T:\GODOT\ink-2\test\low_frames_2026-10-07T03-05-31_11417500.jsonl`，12 条低帧。由 `tick_us` 反推游戏进程启动于 03:05:19.6（对应 `user://logs/godot.log` 里那次 windowed 运行），F1 03:05:31 开、03:05:35 停，覆盖引擎时间 11.717→15.490 s（3.772 s，帧 1589→1863 = 274 帧，均 73 fps）。⚠️ 同一份 godot.log 里还并行混着探针 `_probe_grab.gd` 的输出（两个进程写同一个文件），那段不是单一进程的干净输出。
- 形状：尖峰成簇（1589 / 1617-1619 / 1719-1722 / 1861-1863），单帧 43.5→343.7 ms、fps 2.9→23；非尖峰帧约 128 fps（274 帧里 12 帧慢帧吃掉 1.72 s）。
- 耗时结构（按行号核实）：`step_us ≈ frame_ms`（尖峰整帧都在物理里）；`step_us = Σ(native_us + damage_us)`，`damage_us` 覆盖整个 `calculate()`（`collision_damage.gd:176-220`）= contacts_us + force 采样 + 撞击扫描。逐帧核对：1863 帧 native 159.3 + damage 150.4 = 309.7 ≈ step 313.7；damage 内部 contacts 70.9 + force 采样 76.2 = 147.1 ≈ 150.4。
- 两笔「每对成本」是常数：`_contacts`（`collision_damage.gd:286`）7.40-8.13 µs/对；`force_debug.sample_contacts`（`force_debug.gd:39-58`）7.37-8.43 µs/对。12 帧合计 38005 对，两笔合计 596 ms / step 合计 1592 ms（37%）；native Rapier 959 ms（60%）。
- 唯一的乘数是子步：引擎 `pworld.gd:1622 _compute_substeps`（`ccd_enabled`、`ccd_max_motion=2.0`、`ccd_substep_budget=600`），本场 17→301 子步；`对数 = 子步 × 每子步对数(15.7-54.5)`。
- 场景规模：刚体 22→28、矩形 780→865；玩家本体 302 矩形/质量 6144，手 82 矩形/质量 84。跑在速度钳位附近的小碎片 id 23（质量 14、4 矩形）在 1719 帧还醒着、24964 px/s + ω49.3，1720 起 frozen（飞出视野被 cull_freeze 冻住、速度留着）。
- 发现（可动、但本轮未动）：`map/main.tscn:81-82` 的 ForceDebug 没覆盖 `enabled` → 用脚本默认 `true`（`force_debug.gd:5`），而 `ui/hud/src/hud.gd:16-18` 的 `_ready` 只关 `visible` 不关 `enabled`，所以力采样在成品 HUD 下也每帧在跑，尖峰帧占 24%（76.2 / 321.9 ms）。这是调试可视化成本，不是物理必需。
- 录制自身开销可忽略：写 JSON 合计 4.9 ms，单帧最多 2.08 ms（`previous_log_ms`）。
- 未查明：谁把子步顶到 301。日志只存数字（`debug_hud.gd:76` 存 `last_substeps`，`physics_profile.substeps` 是 `count` 累加），不存驱动刚体；用这 12 帧里所有刚体的 `|v| + |ω|·bounding_radius()`（`pbody.gd:191`）都反推不出 301（需要 motion≈602 px/步 → fastest≈36000 px/s，而日志里动态体最大 776 px/s，唯一 24528 px/s 的 id 23 已 frozen、且 mass 14 ≤ `ccd_ignore_mass` 16 已被豁免）。要定位得让引擎把「最快刚体」暴露出来 —— 属于改引擎，没动。
- 只读：没改引擎、没改游戏逻辑；本轮只新增文档（`ui/hud/doc/HUD.md` 加一条录制注意事项）与本记录。

## 2026-10-07 03:13 — BottledInk 修「看不见」+ 用户三问取证

- 三问：①主角变色 / ②player.tscn 一大堆 shape / ③墨水图层看不见。
- ①**不是状态机、不是调色板**。取证：`rg -i "state_machine|enum State"` 在 `actor` / `map` / `ui` 里 **0 命中**；`rg "modulate|flash|tint"` 在 `actor/player/src` 只有 `bottled_ink.gd:47` 的 `ink_color` 一处。真因是 HEAD 版 shader（`git show HEAD:actor/player/src/bottled_ink.gdshader`）只丢弃 `TEXTURE.a <= 0`，然后把**整个剪影**染成 `ink_color` → 整只瓶子变墨蓝。该图层由 `d1cf7ea`（用户 02:55 自己提交，信息里就写着「新增墨水」）引入。
- ②6 个 `Shape` 是烘焙规定，不是本轮加的：`tools/doc/烘焙.md:15`「每个 4 邻接连通块必须单独出一个 `.tres`」，理由是 `addons/pixel_destruction/physics/pworld.gd:493-516 ensure_connected()` 会把多岛 shape 就地拆成独立刚体（角色会散架）。逐版点数：`2098869` = 1 个、`2a574c0`（10-06 21:48「上动画」）= 6 个、`d1cf7ea` = 6 个。`烘焙.md:33-39` 的报告与 tscn 里的 `position`（0,0 / 23,66 / 58,66 / 40,76 / 60,59 / 24,59）逐项对得上。
- ③根因：**上轮改的 shader 是坏的** —— `interior` 判据和 `TEXTURE.a` 判据互斥。瓶内按定义就是剪影上的空像素，两条同时为真不可能 → 每一帧整层 `discard`，所以什么都看不见。已删掉 `TEXTURE.a` 那条。
- 本轮改动（3 个文件，均未 commit）：
  - `actor/player/src/bottled_ink.gd`：新增 `_ensure_interior()` / `_build_interior()` / `_push_empty()`，四边界泛洪出瓶内遮罩，缓存键 = 贴图 id + 尺寸 + offset + `_mask.get("_sig")`。
  - `actor/player/src/bottled_ink.gdshader`：只剩「不在瓶内 → discard」「液面以上 → discard」两条。
  - `test/test_ink.gd`：断言改到新语义（`INTERIOR_PX = 6241`、四角不画、描边不画、半瓶按液面上下分开），23 检查。
  - `actor/player/doc/墨水.md`：遮罩一节重写。
- 实测：`interior` = 6241 像素、bbox (6,4)-(91,116)；四角与描边都不在遮罩里；玩家仍是 6 形状 / 4378 格（`test_ink.gd` 断言）。
- 真窗口截图（不带 `--headless`）：`user://ink_full.png`（整瓶墨色）、`ink_half.png`（半瓶，标准墨水瓶观感）、`ink_empty.png`（只剩黑线稿）。
- 回归：`test_ink.gd` 23/23、`test_upright.gd` 17/17、`test_live_input.gd` 四组合 6/3/8/8 全 0 失败。
- ②的「抓握时仍然有回复力矩」：**当前 HEAD 未复现**。新探针 `test/_probe_grip2.gd` 把「有支撑的帧」单独统计 `debug_upright_torque`：A 复现 `test_upright._test_grip`（悬吊抓地）support 59/60、tau 0.000 MN；B 站地上抓地（脚 120/120 帧都有支撑）tau 0.000 MN；C 只按住左键、指尖 0.72 px 内没有东西（`grabbed_body == null`）tau **346.9 MN**。→ `player_input.gd:103-118` 的门语义正确，用户观察到的力矩只可能来自「其实没抓上」（`hand.gd:236 GRAB_RADIUS = 0.72`，指尖要贴到目标才 weld）。
- 未做：没改抓握半径、没改 `fill` 默认值（仍 1.0 = 整瓶）、没动 `res://` 以外的任何东西、没 commit、没删用户 F1 录制 `test/low_frames_2026-10-07T03-05-31_11417500.jsonl`。
- 临时探针已删：`test/_probe_grab.gd(.uid)`、`test/_shot.gd(.uid)`、`test/_inkprobe.gd(.uid)`、`test/_probe_grip2.gd(.uid)`。

## 2026-10-07 03:24 — 删抓握门控 + InkHealth/HUD 墨水生命值链

- 任务 1（用户明确：「我就是要抓我的时候仍然有回复力矩」）：删掉 `actor/player/src/player_input.gd` 里上一轮我自己加的
  抓握门控（原 106-109 行），并删掉因此变成孤儿的 `@onready var hand`（原 6 行）。现在只剩一条门：腾空
  （`support == null`）不出力。`_upright_angular_impulse()` 的 doc 不再提抓握。
- 任务 1 验收（`test/test_upright.gd`，真场景 + 真 Rapier，18/18）：`_test_grip` 断言反向 —— 手抓住世界、脚也踩在地上时，力矩必须非 0。
  实测 `GRIP frames=60 support=59 torque=600000000.0000`（即 600 MN，恰好顶在 `max_upright_torque` 上）。其余全未变：`KICK 3` / `KICK 12` / 关控制器 /
  腾空 `AIRBORNE frames=87 torque=0.0000` 与改前逐位相同。
- 任务 2（新增）：`actor/player/src/ink_health.gd` —— 玩家墨水生命值的单一真源。
  接口：查询 `ink` / `max_ink` / `ratio()`；改走 `add()` / `reduce()`（自动夹 0..max_ink）；`signal changed` 只在真变化时发。
  接线：`actor/player/player.tscn` 新增 Player 子节点 `InkHealth`（`load_steps` 13->14）；`bottled_ink.gd` 删掉 `@export fill`，
  改成每帧读兄弟节点的 `health_path`(`../InkHealth`).`ratio()`（接不到按满瓶画），液面与质量共用 `_fill`；
  `ui/hud/src/hud.gd` 新增 `health_path`（默认 `^"../Player/InkHealth"`），连 `changed` 并把 `StatusBar.value` 设成 `ratio()*100`，
  接不到才退回 `bar_ratio` 占位。
- 任务 2 验收：`test/test_ink.gd` 23 -> **31 checks / 0 failures**（新增 6 条生命值接口 + 2 条 HUD 横条；
  `_ink.fill = x` 10 处改成 `_set_fill(ratio)`）。HUD 断言走 `reduce()` 真信号：100 -> 25。
- 文档：新增 `actor/player/doc/生命值.md`；`actor/player/doc/墨水.md` 改掉 `fill` 说法；`ui/hud/doc/HUD.md` 新增「横条数据源」一节。
- 回归（headless，真 `map/main.tscn`）：`test_ink` 31/0；`test_upright` 18/0；`test_live_input` 6/0；`test_collision_damage` 41/0；
  `test_canvas` PASS；`test_hand_jitter` 无失败；`test_game_control` 29 checks / 4 failures、`test_hand_physics` 47 passed / 3 failed —— 两者
  与日记 03:0x 记录的基线逐字相同（失败项也相同），不是本轮引入；`test_game_control` 里手从未抓住
  东西（`grabbed_body == null`），门本来就没生效。
- 未做：任务 3（烘焙工具链）只给结论不改代码；没接碰撞伤害 -> `reduce()`（保留在 `player_physics.gd:apply_collision_damage`）；
  没动 `InkJar` 静态图标；没 commit、没 checkout/reset、没删用户`test/low_frames_*.jsonl`。

## 2026-10-07 04:11 修「Tab 调试 UI 没了」+ 核对血条↔ink_health

- 现象①（用户报告）：按 Tab 唤不出调试 HUD。**根因不是 WIP 的 HUD 脚本，是画布工具面板抢焦点**：`actor/canvas/canvas.tscn` 的 `Buttons/Brush`(41) `Eraser`(46) `Hand`(52) `Redraw`(58) `Generate`(64) `ReturnToCanvas`(70) 是 6 个 `Button`，默认 `focus_mode=FOCUS_ALL`；点过任一个之后焦点留在它身上，此时 Godot 的 GUI 把 Tab 当内置 `ui_focus_next` 处理并**标记事件已处理**，`_unhandled_input` 根本收不到。
- 复现实测（真实 `map/main.tscn`，临时探针用完即删）：`grab_focus` 到 `Main/Canvas/Buttons/Brush` 后发一个真实 `KEY_TAB`，状态 `hud=true debug=false` → 按后仍 `hud=true debug=false`，焦点仍是 `Brush:<Button#...>`；同一个探针不给焦点时 Tab 正常切到 `hud=false debug=true`。所以「有时候 Tab 好使、有时候没了」= 有没有点过工具按钮。
- 修法（只改我自己的文件，1 处）：`ui/hud/src/hud.gd` 的 Tab 处理从 `_unhandled_input` 挪到 `_input`，并 `get_viewport().set_input_as_handled()`。`_input` 在 GUI 之前跑，焦点在谁身上都不影响。修后同一复现路径实测 `hud=true debug=false` → `hud=false debug=true` ✓（无焦点场景同样 ✓）。备选根因修法是给那 6 个按钮设 `focus_mode = 0`（那是并行会话的文件，本轮没动，已写进 `ui/hud/doc/HUD.md`）。
- 现象②（用户要求）：顶部血条关联玩家 `ink_health`。核对结果：这条**当前代码已经是通的**（并行会话 03:22 已接）：`hud.gd:9-13,20-30` 用 `health_path = ^"../Player/InkHealth"`，`_ready()` 连 `changed` 并读一次 `ratio()`；`InkHealth` 是 `player.tscn:69-70` 的节点，脚本 `actor/player/src/ink_health.gd`（单一真源，`add()/reduce()` 才广播 `changed`）。实测：`bar=100.0 ink=100.0 ratio=1.0` → `health.reduce(30)` → `bar=70.0 ink=70.0 ratio=0.7`，同一帧同步 ✓。本轮没改这条链路。
- 回归（headless）：`test_game_control` 29 checks / 4 failures（与改前逐条相同，还是那 4 条既有物理项）；`test_live_input` 6/0。
- 未做：没给 6 个工具按钮设 `focus_mode=0`（避免与并行会话的 `canvas.tscn` 抢同一文件，改法已记在 doc）；没动并行会话的 `InkJar` 静态图标；没 commit。

## 2026-10-07 04:20 墨水图层改成引擎裁剪，删掉整个 shader（用户在追的「效果很烂 / 往左躺全消失」）

- 根因（上一版 shader，已在 04:0x 取证）：`bottled_ink.gdshader` 的液面判据是 `dot(VERTEX, down_local) - level`。`VERTEX` 是**帧缓冲像素**（本项目 2560x1600 窗口、渲染目标 6827x3840、还带画布原点偏移 (430.45, 206.44)），而 `level` 是**节点局部像素**（范围只有 -166..+166）。两个坐标系混用 -> ①液面从来不生效（满 / 半 / 四分之一画出来一模一样）；②`down_local.x <= 0`（往左躺）时整层 `discard`。这不是参数没调好，是实现从根上错了。
- 新实现（**总代码更少，且删掉一个文件**）：`BottledInk` 自己不画像素 —— 它的贴图是「瓶内遮罩」(alpha 1 = 瓶内)，`clip_children = 1`（仅裁剪）让它只当模板；唯一子节点 `Liquid` 是一个**世界轴对齐**的大方块：局部 X 轴 = 世界水平、局部 Y 轴 = 世界向下、左上角压在液面上。引擎把方块按遮罩 alpha 裁一遍，屏幕上剩下的就是「方块 ∩ 瓶内」。泛洪的瓶内遮罩保留（这是「只填瓶身内部 + 剪影被破坏后仍正确」的要求所必需）。
- 为什么确定引擎能做这件事：临时工程实测 `clip_children` 是**按父节点 alpha 逐像素**裁（不是矩形裁），且 Forward+ 与 `gl_compatibility`（本项目用的渲染器）结果一致，父节点旋转 + 子节点世界轴对齐的组合也正确。本地 `actor/player/doc/墨水.md` 记了这条旧坑。
- 实测（真实 `map/main.tscn` + 真 Rapier，2560x1440 帧缓冲，开关 `BottledInk.visible` 做差分像素；探针用完即删）：
  `满 0°=33177`、`满 -90°=33358`、`满 180°=33227`（**躺下 / 倒立不再消失**）、`半 0°=16674`（正好是满的一半）、`半 -90°=16799`、`1/4 0°=3986`。抽查截图：半瓶液面世界水平、墨水只在瓶身内部（描边与内部高光线都不上墨）。
- 改动文件：删 `actor/player/src/bottled_ink.gdshader` 与其 `.uid`；重写 `actor/player/src/bottled_ink.gd`；`actor/player/player.tscn` 加 `BottledInk/Liquid` 子节点并给 `BottledInk` 设 `clip_children = 1`；同步 `test/test_ink.gd`（19 -> 32 检查）、`actor/player/doc/墨水.md`、`test/doc/验收.md`。
- 回归（headless）：`test_ink` 32/0、`test_upright` 18/0、`test_live_input` 6/0、`test_collision_damage` 41/0、`test_canvas` PASS。
- 未做：没动 6 个 `Shape`（用户明确「先别动 shape，多就多吧」）；没动并行会话的 `actor/canvas/**`、`actor/nail`、`ui/hud`、`map/**`；没 commit、没 checkout/reset、没删用户 `test/low_frames_*.jsonl`。
- 取证但**未动手**（等用户定）：`actor/player/asset/player_body.png` 只有 3 种不透明色 —— 黑 916480 px（描边）+ 深灰 (85,85,85) 132096 px + 浅白 (170,170,170) 72192 px（后面两种是瓶身内部的**高光线**）。`tools/bake_art.gd:50` 只按 `alpha > 0` 判实心，`SOURCES`（`tools/bake_art.gd:20-23`）给 body 的材质 id 只有一个 2，而 `player.tscn:59` 的 palette[2] 是黑 —— 所以白色高光层现在①进物理、②被画成黑色。用户说这层「只有视觉效果」，与现状不符，怎么处理待定。

## 2026-10-07 04:19 高光层：非纯黑像素烘成「只显示、不改物理」的材质 5

- 用户澄清：「那个白色应该也烘焙了，是一个图层来着，不过只有视觉效果」。取证：`actor/player/asset/player_body.png`
  （1632x2304）只有 3 种不透明色 —— 纯黑 3580 格（描边）+ (85,85,85) 516 格 + (170,170,170) 282 格；
  后两者是**瓶身玻璃高光线**（瓶颈竖线 / 肩部弧 / 瓶底弧），且完美 16px 对齐（每种色的像素数都是 256 的整数倍，
  逐格抽样计数与全图像素数除以 256 完全相等）。旧烘焙把它们一律按材质 2 烘 -> 既全画成黑、又带上描边的物理。
- 改法（**逐格材质**：节点数、形状数、类型数都不变）：
  - `tools/bake_art.gd`：`SOURCES` 加第 5 项「高光材质 id」；`analyse()` 逐格判纯黑/非纯黑写 `mat`（顺带返回 `highlights`）；`write()` 从「整图一个材质」改成读逐格 `mat`；`run_all()/bake()` 透传。手第 5 项 = 0（不拆）。
  - `actor/player/asset/highlight.tres`（新，`PixelMaterial`：id 5、color (0.667,0.667,0.667)、density 1.40338）。
  - `map/main.tscn`：`materials` 加 `highlight`；`densities_fallback` 补第 6 项 `1.40338` —— `pixel_world.gd:504` 的 `_density_of()` 读的正是这张表，不补就按 2.0 算质量。
  - `actor/player/player.tscn`：`Visual.palette` 补第 6 项高光灰。
- 验收（真场景 + 真 Rapier，临时探针用完即删）：
  - 烘焙：`player_body.png -> player_body_*  98x138  实心 4378（高光 798）  连通块 6`；产物材质分布 `player_body_0.tres {0:9573, 2:3153, 5:798}`，`player_hand_unfold_*` 全是 3。
  - 物理**逐位不变**：`MASS=6143.9976 DENSITY=1.403380 SHAPES=6 PIXELS=4378`（改前改后同一组数字）。
  - 显示：`Visual.texture` 里 `(170,170,170,255) = 798` 像素（正好等于烘焙的高光格数），黑 3596，无 push_warning。
  - 真窗口 2560x1440 截图：瓶颈/肩/瓶底的高光线出来了，而且**墨水层给它让位**（瓶内遮罩只泛洪空像素，所以高光不上墨）。
- 回归：`test_ink` 32/0、`test_upright` 18/0、`test_live_input` 6/0、`test_collision_damage` 41/0、`test_canvas` PASS。
- 撞到并绕过的一个坑：`prune()` 删所有 `<前缀>_*.tres`，我起名 `player_body_hi.tres` 被同一次烘焙当场删掉 -> 改名 `highlight.tres`，并把这条写进 `tools/doc/烘焙.md`。
- 顺带发现（**未改**，不是本轮引入）：`Visual.texture` 比身体像素多 16 格黑。`player.tscn` 的 `Arm`（`PixelBody2D`、`rect_size=4x4`）是 Player 的**直接子节点**，而 `addons/pixel_destruction/nodes/pixel_sprite_2d.gd:_collect()` 只认「有 `build_shape()` 的兄弟、不查类型」（`pixel_body_2d.gd:407` 正好有），于是 Arm 被当形状画了 —— 实测截图瓶身左上一个 4x4 黑点，并且这 16 格还会进墨水层遮罩（被当成不透明）。修法：`_collect()` 加类型判断，或把 Arm 挪出 Player 的直接子节点。`addons/` 没动。
- 未做：没改 6 个 Shape（用户「先别动 shape，多就多吧」）；没动并行会话的 `actor/canvas/**`、`actor/nail/**`、`ui/hud/**`、`map/src/**`；没 commit、没 checkout/reset、没删用户 `test/low_frames_2026-10-07T03-05-31_11417500.jsonl`。

## 2026-10-07 04:41 bag 原生美术收尾：墨水质量回调、末端贴图、临时文件清理

- 源图换成 bag 原生稿（4px/格，不再重采样/放大）：`actor/player/asset/player_body.png` 272x428（68x107 格）、`player_hand_unfold.png` 124x144（31x36 格）。旧稿是被人为放大的（旧联合 bbox 98x138 实心 4378）。
- 烘焙产品（`tools/bake_cli.gd` 重跑，3 个 .tres 的 SHA256 逐位不变）：`player_body.png -> player_body_* 68x107 实心 3486（高光 1300）连通块 2` —— `player_body_0.tres` position (5,37) 58x34 1816 格、`player_body_1.tres` position (0,0) 68x107 1670 格；`player_hand_unfold.png -> player_hand_unfold_* 36x31 实心 354 连通块 1` —— `_0.tres` position (0,0)。
- **烘焙正确性取证**（不靠目视）：把 `player_body_1` @(0,0) 与 `player_body_0` @(5,37) 按 tscn 的 position 叠回去，与源图 4px 逐格抽样比 —— 实心差 0 格、材质差 0 格（纯黑=2、非纯黑=5）。`player_body.tres`/`hand.tres` 是 `map/main.tscn` 里的 `PixelMaterial`（密度表），不是烘焙产物，没删。
- 修 `actor/player/src/bottled_ink.gd:170`：`pw.world.refresh_mass(_body)` -> `refresh_mass(_body, Callable(pw, "_density_of"))`。原写法回退到引擎 `density_of_material()`（`pworld.gd:462` 把密度 0 兜底成 1.0），材质 5 那 1300 格被按 1.0 算。临时探针实测（已删）：满瓶多 1808.51、半瓶多 1554.25、空瓶多 1300.0。
- 重标 `actor/player/src/hand.gd:235` 的 `FINGERTIP`：24.201,3.122 -> **16.545,2.121**。旧值反推验证：`git show HEAD:` 的 3 张手图按 tscn 的 position 拼回，重心（格心坐标）=(29.7992,24.8776)，旧 `FINGERTIP + 重心` = (54.0002,27.9996) = 最右列外沿 (54.0,28.0)。新稿最右列 x=35 的格心均值 18.5、重心 (19.4548,16.37853)（引擎 `local_com` 实测同值）-> (36.0-19.4548, 18.5-16.37853)。
- 删临时文件：`test/_tmp_inkdbg.gd`、`test/_tmp_handcom.gd`、`test/_tmp_tumble.gd`、`_tmp_preview/`（9 张）、`_tmp_hand_rot.png`。**没删**用户的 `test/low_frames_2026-10-07T03-05-31_11417500.jsonl` 和用户原图 `player_hand_grab.png`。
- 回归（headless，真 `map/main.tscn` + 真 Rapier）：`test_ink` 32/0（修前 3 条 FAIL）、`test_live_input` 6/0、`test_collision_damage` 41/0、`test_canvas` PASS、`test_upright` 18/1。
- `test_upright` 那 1 条 FAIL = `a full tumble does not jitter`（`hard.tail_w=0.0392 > 0.02`、`tail_jerk=0.0356 > 0.02`）。**已证明与本轮改动无关**：把 `refresh_mass` 那行改回旧写法重跑，数字逐位相同（0.0392 / 0.0356）—— 现场 `capacity_mass = 0`，`_sync_mass()` 一直早退，墨水质量压根没参与。临时探针 420 帧轨迹：kick=12 后 i=105 时 rot=-0.0028，随后反向漂到 -0.033 并长期停在 -0.033±0.0014 rad、ω±0.041，回复力矩一直挂 3.5e7~4.5e7 N·m 顶着。即「翻滚后落在单条腿上、靠回复力矩硬撑在 -1.9°」的接触限幅极限环，幅值 0.08°（≈0.15 px 尖端位移），肉眼不可见但过了测试阈值。**没改** `player_input.gd` 的 k/d/cap（上一轮定的值，本轮没授权调）。
- 发现待定（未改）：`player.tscn` 没设 `BottledInk.capacity_mass`（默认 0）-> 「墨水按当前液面进质量」实现好了但现场是断的，墨水目前对物理零影响。要不要给个值（比如 1200）等用户定。
- 未做：没 commit、没 checkout/reset；没动并行会话的 `actor/canvas/**`、`actor/nail/**`、`ui/hud/**`、`map/src/**`、`mode/**`、`project.godot`。

## 2026-10-07 04:54 复核 bag 原生稿烘焙 + 查清 test_upright 那条 FAIL + 模块文档纠偏

- 复核（真实跑，非目视）：`tools/bake_cli.gd` 重跑 3 个 .tres 逐位不变（save=0）；`test_ink` 32/0、`test_live_input` 6/0、`test_collision_damage` 41/0、`test_canvas` PASS、`test_hand_jitter` exit 0、`test_upright` 18/1。
- 白色高光层量化（第 4 条「只有视觉效果」的证据）：`player_body.png` 68x107 格里 黑 2186 / 高光 1300，逐格 4px 判纯黑 -> **1300 个高光格有 0 格落在黑色剪影的内部填充之外**，所以既不扩碰撞体积也不出质量（`actor/player/asset/highlight.tres` density 0 + `map/main.tscn:29` `densities_fallback[5]=0`）。实测质量 3067.78868 = 2186 x 1.40338 吻合。
- `test_upright` 的 `a full tumble does not jitter` 定性（3 个受控实验 + 轨迹探针，探针已删）：
  1. 高光密度回 1.40338：0.0392 -> 0.0310 仍 FAIL，还多坏一条 airborne 落地 -> 高光密度不是根因；
  2. 黑描边密度 x3.7（惯量回到旧稿 1.51e7）：ω 只到 0.0365，残余倾角反涨到 0.240 rad -> ω 与质量/惯量无关；
  3. 轨迹（kick=12 后 540 帧）：质心 y 只动 0.03 px、接触点恒 cpy=231.0，倾角长期停在 -0.0335 rad（-1.9°）、ω≈0.04；把身体复位到初始位姿再 kick=12 -> tail_rot=0.0、tail_w=0.0013（15 倍余量 PASS）。
  -> 控制器没坏；是「第二次 kick 从漂移后的落点起跳、落在某条腿尖上，靠接触台阶锁住 1.9° 残余倾角」的位姿相关残余（ω 0.04 rad/s ≈ 尖端 0.07 px，肉眼不可见；兄弟判据 <0.05 rad 已通过）。换 bag 原生稿改变了落地姿态。**没动** k/d/cap。
- 墨水质量管线在**现场是断的**：`actor/player/player.tscn` 没设 `BottledInk.capacity_mass`（默认 0）-> `bottled_ink.gd:160` 一直早退，墨水对物理零影响；`test/test_ink.gd:216` 自己设 1200 才验到这条线。数值待用户定。
- 文档纠偏（本轮唯一写盘）：`actor/player/doc/脚.md:11` 还写着「手抓住世界时也不允许回复力矩 + grabbed_body 判据」，与代码/验收相反（`player_input.gd` 里 0 处 grab 引用），改成「抓住世界照样出力，判据只有 support != null」；同文件 :8 的 m·g·h 还是旧稿数字（≈2.7e8 @74 格），换成实测 m=3067.8、g=600、质心到接触 59 格 -> ≈1.1e8。`readme.md` 目录补 4 条（身体/脚/墨水/生命值）。
- 未做：没 commit、没 checkout/reset；没动并行会话的 `actor/canvas/**`、`actor/nail/**`、`ui/hud/**`、`map/src/**`、`mode/**`、`project.godot`；`map/**`/`mode/**`/`actor/nail/**` 还没有模块 doc（不在本轮范围）。
- 未删：`actor/player/asset/player_hand_grab.png`（抓握切换贴图还没做、无消费方）、用户录制 `test/low_frames_2026-10-07T03-05-31_11417500.jsonl`。
