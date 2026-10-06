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
