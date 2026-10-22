## Task 2: DST 原生扩展的加载与渲染诊断

**Files:** 创建 `native/src/{entry.mm,gl_observer.mm,frame_reader.cpp}`、`native/include/gl_observer.h`、`native/tests/gl_state_test.mm`；修改 `native/Makefile`；创建 `tools/{preflight.py,launch_dst.command,capture_render_probe.py}`。

**Interfaces:** 消费 `FrameView`；产生 `RenderProbe(frame_no, context_id, viewport, draw_no, projection, modelview, depth_enabled, depth_mask, depth_range, blend_state, target_id)` 诊断 JSONL。C++ `observe_draw(const RenderProbe&): void`、`capture_probe_frame(): ProbeCapture`；`ProbeCapture` 包含场景颜色/深度和阶段信息。`preflight.py --json` 输出可执行文件哈希、架构、权限、端口和存档锁状态。

- [ ] 写 CGL 离屏失败测试 `gl_state_restored`：预先设置非默认 viewport、纹理绑定、blend、depth、program/FBO，调用一次扩展诊断后逐项相同；`context_recreated` 在销毁并新建上下文后没有复用旧 GL 对象。运行 `make -C native gl-test` 观察失败。
- [ ] 实现 x86_64 Objective-C++ 动态库，以 `NSOpenGLContext` 的呈现方法和可核验 OpenGL 调用为入口采样；对上下文分别保存状态，避免递归调用。加载器只通过专用启动入口设置本次 `DYLD_INSERT_LIBRARIES`，不修改可执行文件或签名。未识别的绘制状态只记录，不注入合成绘制。
- [ ] `make -C native all gl-test` 通过后做现场预检；请用户保存并退出当前 DST，再用专用入口重新启动同一测试世界。不得强行结束现有游戏。采样一次地面、树木、生物和 UI 场景，输出 `evidence/render-probe/` 的颜色、原始深度、矩阵、调用阶段和扩展加载记录。
- [ ] 执行 `python3 tools/capture_render_probe.py --seconds 10 --out evidence/render-probe`。人工检查原生场景是否提供透视深度及 alpha 裁剪；记录哪些 draw 属于场景和 UI，并生成带版本/哈希的识别配置。不能由一张非全黑深度图认定可用。
- [ ] 若需要额外深度通道，诊断报告必须明确原深度缺失在哪些物体；任务 4 负责验证补充通道。提交 `feat: add macOS DST render diagnostics and isolated launcher`。


# Binding shared context

## Global Constraints

- 两款真实游戏同时运行。玩家使用 Minecraft（MC）的第一人称、键鼠、物品栏和建造操作。
- 首版限定为本机、单名玩家、独立联动测试存档、地面区域。
- 首版按 1 个 MC 方块对应 1 个 DST 世界单位开始校准。
- HTTP 保持绑定回环地址；所有游戏对象操作在各自游戏线程执行，图形操作在渲染线程执行。
- 首版处理完整实心立方体；玻璃仍按完整碰撞体处理。DST 生物不增加攀爬 MC 楼梯的能力。
- 先以 960×540 或等比窗口进行验证；连续 60 秒样本，目标合成 30 FPS、状态同步 20 Hz。
- 测试扩展通过专用启动入口加载，不替换原游戏可执行文件；不写入用户原始 `DST-MC-Test` 存档。
- 不宣称崩溃下的严格 exactly-once；未决伤害先对账，禁止无条件回放到新会话。
- 可运行包、使用说明和验证证据集中输出到 `outputs/`；不包含完整游戏资源、账号信息或授权令牌。
- 不在运行开发客户端时重建同一 Loom 工程；停止自己启动的测试实例后再构建，不按历史 PID 结束进程。

## Review Focus

1. Retina 像素与窗口尺寸、切换分辨率：按物理帧尺寸校验、重建缓冲，不错位或越界（任务 1、3、4）。
2. 换世界、旧日志和恢复后的 UUID：固定原点且拒绝旧世界/旧会话的伤害和碰撞（任务 1、5、7）。
3. HTTP 延迟回调、进程退出和输入切换：迟到回复不重新接管镜头，按键释放，断联不继续驱动角色（任务 4、8）。
4. 快速放拆、负坐标及区块边缘：版本缺口触发快照，移除后无碰撞残留，旧障碍不阻挡新区域（任务 5、6）。
5. OpenGL 状态、透明像素和上下文重建：透明处不遮挡 DST，丢弃未完成帧，恢复原游戏绘制状态（任务 2、3、4）。

## 执行范围、目录与固定接口

根目录为 `work/dst-mc-bridge/`。本计划是一条有先后依赖的联动链；任务 4 是画面关口，未通过时不进入任务 5—8 的完整集成。旧临时原型留在相邻 `dst-mc-probe/`，仅按文件审查后借用已验证部分。

| 路径 | 单一职责 |
|---|---|
| `protocol/frame-v2.md`, `protocol/http-v2.schema.json`, `protocol/fixtures/` | 跨语言格式及固定样本 |
| `mc/src/main/java/dev/jay/dstmc/protocol/` | 配对、变换、消息、结果和共享帧格式 |
| `mc/src/main/java/dev/jay/dstmc/server/` | 权威状态、虚拟地形、方块差异、战斗和区块加载 |
| `mc/src/client/java/dev/jay/dstmc/client/` | 画面捕获、MC 界面与控制权切换 |
| `mc/src/main/resources/`, `mc/src/client/resources/` | 模组入口、Mixin、空场景维度及不可见代理方块 |
| `native/include/`, `native/src/`, `native/tests/` | 帧读取、HTTP 镜头租约、渲染诊断与合成 |
| `dst-mod/scripts/dstmc/`, `dst-mod/scripts/prefabs/` | 原生采样、镜头、碰撞和伤害适配 |
| `tools/`, `tests/` | 构建、测试副本、启动、采样和真实游戏验收 |

本计划中模块共享的值类型在任务 1 定义，后续不另起同义字段：

- `Vec3(x: double, y: double, z: double)`；`Box(min: Vec3, max: Vec3)` 为闭开区间 AABB；MC 放置格坐标用 `Cell(x: int, y: int, z: int)`。
- `PairKey(dst_world: UUID, dst_shard: string, mc_world: UUID, mc_dimension: string, region: string)` 标识配对；`Epoch: UUID` 标识一次握手。两者均必须匹配。
- `Pose(space: MC|DST, position: Vec3, forward: Vec3, up: Vec3, view: float[16], projection: float[16])` 为列主序矩阵；共享图像附 MC 空间 Pose，镜头租约返回转换后的 DST 空间 Pose，不能直接比较两个空间的绝对视图矩阵。
- `FrameKey(pair: PairKey, epoch: Epoch, id: uint64)`；`FrameLease(key: FrameKey, pose: Pose, width: int, height: int)`。
- `Body(id: UUID, box: Box, health: double, max_health: double, revision: uint64)` 使用 DST 持久对象 UUID，不以会变动的运行时 GUID 作为持久主键。
- `BlockChange(revision: uint64, cell: Cell, state: string)`；`TerrainCell(cell: Cell, boxes: Box[])`；`ActorSnapshot(revision: uint64, bodies: Body[])`。
- `Command(id: UUID, pair: PairKey, epoch: Epoch, kind: string, payload: object)`；`CommandResult(id: UUID, status: PENDING|APPLIED|REJECTED|UNRESOLVED, reason: string)`。
- `DamageEvent(id: UUID, pair: PairKey, epoch: Epoch, source: MC|DST, target: UUID, position: Vec3, amount: double, kind: string)`；按 `(pair, id, target)` 去重。

帧格式 v2：小端；文件头 4096 字节、3 个槽、槽头 512 字节；最大物理尺寸 1920×1080。每槽依次是预乘 alpha 的 RGBA8 世界颜色、float32 深度、预乘 alpha 的 RGBA8 HUD，每层 `width*height*4` 字节。固定头内含配对键规范 JSON 的 SHA-256（32 字节）、Epoch、帧编号、两个原点与轴变换、矩阵、格式、尺寸、层偏移、提交序列和租约编号；不把变长世界名称直接塞入槽头。深度为 MC 原始 OpenGL [0,1] 深度，比较前用相应逆投影和世界变换重建空间位置；不得直接比较两引擎的原始深度值。奇数提交序列为写入中，偶数为完整；有租约的槽不得覆盖。检查乘法溢出、文件长度和矩阵有限值。

MC HTTP 使用 `127.0.0.1:39379` 的 `/v2/handshake`、`/v2/exchange`、`/v2/status`。若端口属于旧 protocol=1 实例，报冲突并要求关闭该测试实例，不结束其他用户进程。原生扩展的镜头 HTTP 使用 `127.0.0.1:39380` 的 `/v2/camera/lease` 与 `/v2/camera/applied`，另提供 `/v2/window` 返回 DST 内容区的屏幕坐标、逻辑点尺寸、物理像素尺寸和缩放比例。两个服务都不在网络线程调用游戏 API。


# Controller handoff
Read render-research.md in this workspace for observed shader API names. This is read-only research, not runtime acceptance. Controller owns desktop UI/save/exit and evidence/backups. Do not automate the desktop through shell APIs. Native tests and loader tools belong to this task; current games must not be killed. Runtime extension launch occurs only after controller verifies save/exit. Limit full-resolution diagnostic captures to a few selected frames rather than writing every frame; include actual shader uniform matrices, since fixed-function matrices do not establish DST camera state.

## Committed Task 1 handoff
- Task 1 approved at commit 1e3df96 (initial 0e8ac4b, numeric snapshot fix 1e3df96). Read native/include/frame_protocol.h and protocol/frame-v2.md for actual interfaces; do not change layout casually.
- Java shared types are nested BridgeTypes records/enums. Payload numeric leaves are immutable BigDecimal; consumers treat them as Number.
- Native read_frame returns move-only RAII FrameView; its mapping must be writable and outlive views. Resizing/new epoch requires a new mapping path, never truncate a live mapping. Crashed leases are retired via a new mapping, not forced clear.
- Current DST process has exited after controller CUA Command-Q. The latest on-disk save checkpoint was hash-backed up under evidence/backups/DST-before-native-render before exit; no fresh save completion log was observed. Do not claim a new save or launch the game without telling controller.
- Known successful game executable: /Users/jay/Library/Application Support/Steam/steamapps/common/Don't Starve Together/dontstarve_steam.app/Contents/MacOS/dontstarve_steam. Working directory must be the app Contents/data.
- Controller handles native game UI (save/world selection/pause) through cua_repl. Prepare the launcher/capture tools; notify controller when offline tests are GREEN and live capture can begin.
