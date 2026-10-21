# DST × Minecraft 第一人称联动 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让玩家使用 MC 第一人称移动、建造和战斗，同时看到真实 DST 世界，且方块、原生障碍与伤害能够双向作用。

**Architecture:** MC 负责玩家移动、真实方块和物品栏，DST 负责原生世界与生物。逐帧颜色、深度、HUD 和镜头走共享内存，世界状态与带确认的事件走回环 HTTP；Mac 本地扩展在 DST 渲染线程完成合成。先通过镜头与深度关口，再推进建造、碰撞和战斗。

**Tech Stack:** Minecraft 1.21.11 / Java 21 / Fabric Loader 0.19.5 / Fabric API 0.141.6+1.21.11 / Loom 1.14.10；DST Lua API 10；Objective-C++17、OpenGL 2.1、macOS SDK、x86_64 动态库；Python 3 标准库验收工具。

**Spec:** `../specs/2026-10-21-dst-mc-first-person-design.md`（与本计划一起阅读）。

**状态:** 设计与本实施计划均已由用户确认；用户选择分派子代理逐项实现并分别审查。尚未勾选的复选框表示未来工作，不表示已实现或已通过测试。

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

## Task 1: 可验证的协议、配对和新工程基础

**Files:** 创建 `protocol/frame-v2.md`、`protocol/http-v2.schema.json`、`protocol/fixtures/*`；创建 `mc/{build.gradle,settings.gradle,gradle.properties,gradlew,gradle/wrapper/*}`、`mc/src/main/java/dev/jay/dstmc/protocol/{BridgeTypes,WorldTransform,PairingStore,RequestLedger,FrameLayout}.java`；创建 `mc/src/contractTest/java/dev/jay/dstmc/ContractTests.java`、`mc/src/contractTest/java/dev/jay/dstmc/protocol/ProtocolContractTest.java`、`native/include/frame_protocol.h`、`native/tests/frame_contract_test.cpp`、`native/Makefile`、`.gitignore`。

**Interfaces:** 产生上述全部共享类型；Java `WorldTransform.toMc(Vec3): Vec3` / `toDst(Vec3): Vec3`、`PairingStore.loadOrCreate(PairKey, Vec3 dstOrigin, Vec3 mcOrigin): WorldTransform`、`RequestLedger.receive(Command): CommandResult` / `finish(UUID, CommandResult): void`；C++ `read_frame(const void*, size_t, FrameKey expected): optional<FrameView>`，`FrameView` 为已校验的只读槽视图。

- [x] 写失败测试：`coordinate_roundtrip` 断言 DST 原点 `(100,0,-50)`、MC 原点 `(0,64,0)` 时 `(106.5,2,-47)` 映射为 `(6.5,66,3)` 且可逆；`restart_keeps_origin` 重启存储后原点相同；`foreign_epoch_rejected` 拒绝旧会话；`receipt_is_not_application` 收到只返回 PENDING，重复收到不执行两次，重启后未决项为 UNRESOLVED。
- [x] 从旧工程仅复制 wrapper 和已核对的版本配置，建立独立 Java main 测试总入口 `ContractTests.main(String[])`，后续任务的测试加入同一总入口；执行 `cd mc && ./gradlew coreTest --console plain`，确认失败针对未实现接口；随后实现上述协议核心，不复制旧自动 TNT 和传送循环。核心断言包括 `toMc(new Vec3(106.5,2,-47)).equals(new Vec3(6.5,66,3))`、`receive(c).status()==PENDING`、`receive(oldEpoch).status()==REJECTED`。
- [x] 写并运行 C++ 失败测试：Java 导出的固定二进制样本可读；截断文件、奇数序列、超大尺寸、NaN 矩阵、不同会话均不可读；用 `make -C native contract-test` 观察预期失败，再实现布局读取与边界检查。原子提交和租约测试使用真实共享映射，不仅检查打包字节。
- [x] 运行 `./gradlew coreTest` 与 `make -C native contract-test`；输出 Java ARM64 写入、C++ x86_64 读取同一样本的通过记录。固定样本的格式断言属于跨语言兼容测试。
- [x] 仅提交本任务列出的实现、配置和样本：`git commit -m "feat: add versioned bridge protocol and persistent world pairing"`。

## Task 2: DST 原生扩展的加载与渲染诊断

**Files:** 创建 `native/src/{entry.mm,gl_observer.mm,frame_reader.cpp}`、`native/include/gl_observer.h`、`native/tests/gl_state_test.mm`；修改 `native/Makefile`；创建 `tools/{preflight.py,launch_dst.command,capture_render_probe.py}`。

**Interfaces:** 消费 `FrameView`；产生 `RenderProbe(frame_no, context_id, viewport, draw_no, projection, modelview, depth_enabled, depth_mask, depth_range, blend_state, target_id)` 诊断 JSONL。C++ `observe_draw(const RenderProbe&): void`、`capture_probe_frame(): ProbeCapture`；`ProbeCapture` 包含场景颜色/深度和阶段信息。`preflight.py --json` 输出可执行文件哈希、架构、权限、端口和存档锁状态。

- [ ] 写 CGL 离屏失败测试 `gl_state_restored`：预先设置非默认 viewport、纹理绑定、blend、depth、program/FBO，调用一次扩展诊断后逐项相同；`context_recreated` 在销毁并新建上下文后没有复用旧 GL 对象。运行 `make -C native gl-test` 观察失败。
- [ ] 实现 x86_64 Objective-C++ 动态库，以 `NSOpenGLContext` 的呈现方法和可核验 OpenGL 调用为入口采样；对上下文分别保存状态，避免递归调用。加载器只通过专用启动入口设置本次 `DYLD_INSERT_LIBRARIES`，不修改可执行文件或签名。未识别的绘制状态只记录，不注入合成绘制。
- [ ] `make -C native all gl-test` 通过后做现场预检；请用户保存并退出当前 DST，再用专用入口重新启动同一测试世界。不得强行结束现有游戏。采样一次地面、树木、生物和 UI 场景，输出 `evidence/render-probe/` 的颜色、原始深度、矩阵、调用阶段和扩展加载记录。
- [ ] 执行 `python3 tools/capture_render_probe.py --seconds 10 --out evidence/render-probe`。人工检查原生场景是否提供透视深度及 alpha 裁剪；记录哪些 draw 属于场景和 UI，并生成带版本/哈希的识别配置。不能由一张非全黑深度图认定可用。
- [ ] 若需要额外深度通道，诊断报告必须明确原深度缺失在哪些物体；任务 4 负责验证补充通道。提交 `feat: add macOS DST render diagnostics and isolated launcher`。

## Task 3: MC 真实画面捕获与帧传输

**Files:** 创建 `mc/src/main/java/dev/jay/dstmc/BridgeMod.java`、`mc/src/main/java/dev/jay/dstmc/server/{BridgeServer,WorldExchange}.java`；创建 `mc/src/client/java/dev/jay/dstmc/client/{BridgeClient,FrameCapture,FramePublisher}.java`、`mc/src/client/java/dev/jay/dstmc/client/mixin/{WorldCaptureMixin,GuiCaptureMixin,BridgeSceneMixin}.java`；创建 `mc/src/main/resources/fabric.mod.json`、`mc/src/client/resources/dst_mc_bridge.client.mixins.json`、`mc/src/main/resources/data/dst_mc_bridge/dimension/stage.json`；创建 `mc/src/contractTest/java/dev/jay/dstmc/client/FramePublisherTest.java`、`tools/prepare_test_copy.py`、`tests/__init__.py`、`tests/test_test_copy.py`、`tests/test_live_frames.py`，修改 `mc/build.gradle`。

**Interfaces:** 消费 `FrameKey`、`Pose`、`FrameLayout`；产生 `FrameCapture.captureWorld(Pose): void` / `captureHud(): void`、`FramePublisher.publishCompleted(): Optional<FrameKey>`、`WorldExchange.handshake(UUID dstWorld, String shard, Vec3 dstOrigin): HandshakeResult(pair, epoch, transform, reason)`。共享帧只能在 GPU 读回完成后发布；槽被原生租用时跳过，不覆盖。

- [ ] 写并运行失败测试 `leased_slot_not_overwritten`、`partial_readback_not_published`、`resize_discards_pending_readback`、`alpha_and_channel_order`。断言：RGBA 红色透明样本在 x86_64 读回仍是红色；未完成或上下文失效的 GPU 回调不发布新帧。
- [ ] 写 `test_active_save_copy_refused`，以持有实际文件锁的源存档夹具确认拒绝复制；实现 `prepare_test_copy.py --source PATH --dest PATH`，只复制无活动锁的测试存档，不覆盖现有目标并记录来源。运行 `python3 -m unittest tests.test_test_copy -v` 后，生成独立 `mc/run/saves/DST-MC-FirstPerson-Test`；不再等到最终打包阶段才准备测试副本。
- [ ] 配置 Loom 客户端源码集，并把客户端输出加入 contractTest 的编译/运行 classpath，固定已验证版本和原安装 assets/index=29；模组 ID 使用 `dst_mc_bridge`。独立副本增加空场景维度 `dst_mc_bridge:stage`，临时底面先用原版不可见 barrier 块，任务 6 再替换为精确桥接形状；MC 原有测试世界的地形不渲染到共享画面。先在该维度放一个真实石头方块做图形验收。
- [ ] 建立最小 `BridgeServer/WorldExchange`，提供 v2 握手、状态和本机心跳，MC 世界 UUID 保存在副本内；首次配对原点为 MC `(0,64,0)` 与 DST 当时的脚底位置。同一 MC 副本已配对另一 DST 世界时返回 `WORLD_MISMATCH`，不得把新世界直接锚定到旧方块。任务 5 在此接口增加 actor 和方块流。
- [ ] 按本机 1.21.11 源码挂接：在 `GameRenderer.renderLevel` 内调用 `CommandEncoder.clearDepthTexture` **之前**复制世界颜色和深度；随后清空世界颜色供手部/HUD 分层；在 GUI 实际绘制后捕获 HUD。使用当前 `RenderTarget.getColorTexture/getDepthTexture` 与 `GlTexture.glId()`，不套用 1.21.1 的 `frameBufferId` 字段。取消天空/云和不属于合成层的背景，保留真实方块、必要实体和粒子。
- [ ] 停止本工程开发客户端后运行 `./gradlew build coreTest --console plain`；再启动开发客户端，运行 `python3 -m unittest tests.test_live_frames -v`。必须观察到新进程产生的新帧、实际石头纹理、有效深度和透明背景；不能用磁盘旧样本满足 live 测试。
- [ ] 提交 `feat: stream real Minecraft world and HUD frames with matched poses`。

## Task 4: 第一人称镜头与原生深度合成——画面关口

**Files:** 创建 `native/src/{camera_service.cpp,compositor.mm,scene_depth.mm}`、`native/include/{camera_service.h,compositor.h}`、`native/tests/{lease_test.cpp,compositor_test.mm}`；创建 `dst-mod/{modmain.lua,modinfo.lua}`、`dst-mod/scripts/dstmc/{camera.lua,connection.lua,world.lua}`、`dst-mod/scripts/components/dstmcidentity.lua`；创建 `mc/src/client/java/dev/jay/dstmc/client/PassthroughWindow.java`、`mc/src/client/java/dev/jay/dstmc/client/mixin/{WindowCreateMixin,WindowPresentMixin}.java`、`tests/test_first_person_gate.py`，修改 `native/src/entry.mm`。

**Interfaces:** 消费 `FrameView`、`RenderProbe`；产生 C++ `lease_latest(PairKey, Epoch): optional<FrameLease>`、`camera_applied(FrameKey): bool`、`compose(FrameKey, RenderProbe): ComposeResult`；Lua `camera.ApplyLease(lease): boolean` / `camera.Release(): void`；Java `PassthroughWindow.enable(WindowBounds): void` / `restore(): void`，`WindowBounds` 使用 `/v2/window` 的点/像素及缩放数据。`ComposeResult` 明确 `COMPOSITED`、`SKIPPED_MISMATCH`、`SKIPPED_STALE`、`DEPTH_UNAVAILABLE`。

- [ ] 写失败测试：`lease_pins_matching_pose`、`late_camera_ack_rejected`、`stale_frame_releases_camera`、`retina_resize_cancels_lease`、`transparent_pixel_preserves_host`、`closer_surface_wins`、`ui_state_restored`、`passthrough_window_retains_input`。离屏测试用眼前距离 2 与 6 的红/蓝平面，近表面输出红，透明洞输出宿主蓝：`abs(pixel.r-expected.r)<=1/255`；`compose(expiredFrame).status==SKIPPED_STALE`。键鼠保留测试须在实际透明窗口中走动和放置一次。
- [ ] 为当前测试世界附加持久身份组件，保存 DST 世界 UUID 和分片；只在本机主世界初始化时发出 v2 握手。接受的配对、变换和 Epoch 交给相机模块；拒绝时保持原生镜头，关闭的旧 probe 模组不参与本次连接。
- [ ] 实现 39380 回环镜头服务。Lua 在相机更新期间最多维持一个请求，取得租约后调用原生 `SetCameraPos/Dir/Up/FOV`，保持该 pose，异步确认 `FrameKey`；原生扩展必须同时满足确认、实际绘制矩阵匹配和完整帧三个条件才合成。新帧首次被读取后 250ms 未成功呈现即丢弃；重新配对或释放控制权使旧回调失效。世界交换仍按 20Hz，镜头请求随绘制更新，不被旧 5Hz 交换节流。
- [ ] 在 MC 创建 GLFW 窗口前开启透明 framebuffer，融合有效时保存并切换为与 DST 内容区对齐的无边框浮动窗口，清空本窗口颜色与 alpha，阻止主 RenderTarget 再把 MC 画面显示第二遍。通过现有 LWJGL `GLFWNativeCocoa`、`ObjCRuntime` 设置 NSWindow 不忽略鼠标事件并移除阴影；不新增 ARM64 注入库。融合解除时恢复位置、尺寸、装饰、浮动和正常 MC 显示。首版用窗口模式；完整窗口透明仅负责接收输入，图像仍在 DST 内按深度合成。
- [ ] 根据任务 2 的实际阶段配置，把 MC 世界合成插入场景完成、UI 绘制之前，MC HUD 放在正确的独立层。若原深度不适用，增加重放场景几何的深度通道，必须保留透明裁剪并排除 UI；无法可靠识别的 draw 不猜测深度。恢复所有修改过的 GL 状态。
- [ ] 运行 `make -C native gl-test lease-test` 和 `python3 -m unittest tests.test_first_person_gate -v`；在两款实际游戏中转动第一人称镜头，观察石头方块、树和一个 DST 生物前后互遮挡；检查截图、矩阵、帧编号及 UI。自动数值检查通过和人工视觉通过都必须有证据。
- [ ] 生成 `evidence/first-person-gate/result.json`，只有镜头、同帧、透明与深度遮挡、UI 五项全通过才进入任务 5；否则保留失败帧和原因，提出最小调整。提交 `feat: composite Minecraft into the DST first-person scene`，不以 alpha 叠加代替通过。

## Task 5: MC 移动权威、真实建造与可恢复状态

**Files:** 修改 `mc/src/main/java/dev/jay/dstmc/server/{BridgeServer,WorldExchange}.java`、`dst-mod/scripts/dstmc/world.lua`、`dst-mod/scripts/components/dstmcidentity.lua`；创建 `mc/src/main/java/dev/jay/dstmc/server/{BlockStream,PlacementGuard,ActorRegistry}.java`、`mc/src/main/java/dev/jay/dstmc/server/mixin/BlockChangeMixin.java`、`dst-mod/scripts/dstmc/actors.lua`、`mc/src/contractTest/java/dev/jay/dstmc/server/WorldStateTest.java`、`tests/test_live_building.py`。

**Interfaces:** 消费任务 1 的配对和命令账本；产生 `BlockStream.snapshot(Box): BlockSnapshot(revision, changes)` / `since(long): BlockDelta(from, to, changes, needs_snapshot)`、`PlacementGuard.canPlace(Cell, ActorSnapshot): CommandResult`、`ActorRegistry.snapshot(): ActorSnapshot`；Lua `world.ApplyPlayer(Vec3, epoch): boolean`、`actors.Sample(): ActorSnapshot`。

- [ ] 写失败测试 `same_pair_keeps_anchor_after_restart`、`gap_requests_snapshot`、`duplicate_delta_is_idempotent`、`foreign_world_has_no_side_effects`、`actor_overlap_rejects_place`、`stale_actor_snapshot_rejects_place`。原点稳定测试要读取实际保存文件；方块测试含负坐标和区块边界。
- [ ] 在 `BridgeServer` 按服务端 20Hz 发布 MC 玩家脚底位置；DST 使用同一变换更新隐藏的对应角色，停用旧 DST→MC 传送逻辑。扩展身份组件以保存原生对象 UUID，沿用任务 4 已保存的世界 UUID；MC 配对文件位于该副本存档内。每个异步回复都检查当前 `PairKey/Epoch`。
- [ ] 记录服务端成功的方块变化，覆盖普通放置、拆除、爆炸和状态替换；虚拟地形/原生代理不进入用户方块流。首版允许碰撞形状为完整立方体的块，原生角色占用或 actor 快照超过 250ms 时拒绝放置。拒绝有明确游戏提示且不产生 DST 碰撞体。
- [ ] 构建和核心测试通过后运行 `python3 -m unittest tests.test_live_building -v`：操作实际 MC 放置/堆叠 10 块、拆除其中 3 块、保存重启、重新配对，断言 `remaining_block_count==7`、`reloaded_origin==original_origin`，读取服务端实际块状态；记录玩家连续行走、跳跃时两端位置误差。测试必须携带本次运行 ID，排除旧快照。
- [ ] 提交 `feat: add Minecraft-led movement and persistent block synchronization`。

## Task 6: 双向地形与方块碰撞

**Files:** 创建 `mc/src/main/java/dev/jay/dstmc/server/{TerrainProxyBlock,TerrainProxyStore,CollisionMeshBuilder}.java`、`mc/src/main/resources/assets/dst_mc_bridge/blockstates/terrain_proxy.json`；创建 `dst-mod/scripts/dstmc/{terrain.lua,collision.lua}`、`dst-mod/scripts/prefabs/dstmc_collision.lua`；创建 `mc/src/contractTest/java/dev/jay/dstmc/server/CollisionContractTest.java`、`tests/test_live_collision.py`。

**Interfaces:** 消费 `BlockSnapshot/BlockDelta`、`TerrainCell[]`；产生 Java `CollisionMeshBuilder.build(List<Box>): TriangleMesh(vertices: float[])`、`TerrainProxyStore.apply(long revision, List<TerrainCell>): void`；Lua `terrain.Sample(position, radius): TerrainCell[]`、`collision.Apply(revision, mesh): boolean` / `collision.Clear(epoch): void`。网格顶点为 DST 空间 xyz 三元组，按连续三点一三角形传递。

- [ ] 写失败测试：`touching_cubes_have_no_internal_wall`、`negative_chunk_boundary_matches`、`remove_restores_passage`、`floating_cube_does_not_block_ground_agent`、`missed_delta_rebuilds_mesh`。用跨两个区块的一堵墙检查边界坐标与表面连通，不能仅断言三角形数量。
- [ ] 玩家周围半径 32 个世界单位内采样原生可行走地面及树、石、墙；MC 使用不可见、不可挖掘且不掉落的代理方块碰撞形状。限制代理只位于专用空场景维度，离开区域时清理旧代理；不覆盖玩家真实方块，冲突时拒绝并回报该格。
- [ ] 把确认后的 MC 方块外表面交给原生 `SetTriangleMesh`，按区域更新而非每块每帧重建；角色、生物、投射物分别设置碰撞掩码。路径阻挡只为与地面角色高度相交的表面建立；旧网格在新网格就绪后替换，移除后同步解除导航阻挡。
- [ ] 核心测试通过后运行 `python3 -m unittest tests.test_live_collision -v`，观察真实玩家撞树、玩家和一种地面生物被方块墙阻挡、绕墙及拆墙后通行。复测转角、负坐标、区块接缝和快速连续放拆；对照实际轨迹及当前碰撞体数量，不能只以角色坐标未变化判定通过。
- [ ] 提交 `feat: connect Minecraft blocks and native DST collision geometry`。

## Task 7: 双向伤害、真实爆炸与区块生命周期

**Files:** 创建 `mc/src/main/java/dev/jay/dstmc/server/{DstActorProxy,DamageBridge,ChunkLeaseManager}.java`、`mc/src/main/java/dev/jay/dstmc/server/mixin/TntExplosionMixin.java`；创建 `dst-mod/scripts/dstmc/combat.lua`；创建 `mc/src/contractTest/java/dev/jay/dstmc/server/CombatContractTest.java`、`tests/test_live_events_v2.py`。

**Interfaces:** 消费 `DamageEvent`、`Body`、命令账本；产生 Java `DamageBridge.receive(DamageEvent): CommandResult` / `proxyHit(UUID target, float mcDamage, String kind): DamageEvent`、`ChunkLeaseManager.acquire(dimension, chunk, owner): Lease` / `release(Lease): void`；Lua `combat.Apply(event): CommandResult` / `combat.SampleNativeHit(hit): DamageEvent`。

- [ ] 写失败测试 `damage_retry_applied_once`、`echo_not_forwarded`、`old_world_damage_rejected`、`height_and_reach_checked`、`unresolved_not_replayed_on_restart`、`two_tnt_share_chunk_lease`、`preexisting_forced_chunk_preserved`。以目标原健康 1000、一次 MC 伤害 10 的夹具断言 `after==900`、重复后仍 `900`；同一区块两次 acquire、一次 release 后 `refcount==1`，全部释放后自建强制加载解除。无新爆炸时旧日志不能满足本次 live 测试。
- [ ] 用不可见的 MC 生物代理表示 DST 目标的身体和健康，使 MC 武器、箭与真实爆炸经过 MC 实际命中逻辑；伤害换算固定 `1 MC HP = 10 DST HP` 并记录两端数值。代理不运行自己的 AI；原生对象快照修正代理，跨端伤害标记来源，避免再次转发。
- [ ] 隐藏 DST 对应角色受到原生攻击时，捕获原生有效伤害并交给 MC 健康系统计算；避免该对应角色在确认前独立死亡，确认后按 MC 健康比例更新。目标身份、高度、攻击来源与范围都检查，不把附近所有原生对象无差别扣血。
- [ ] TNT 仅在真实服务端爆炸完成后发布结果；事件保留生成时的配对/原点快照，不能使用随后新会话的全局原点。区块加载按所有者计数，创建实体失败或卸载时清理，只释放本桥接实际取得的强制加载权限。取消任何启动后自动生成目标或自动发射 TNT 的代码。
- [ ] 构建通过后运行 `python3 -m unittest tests.test_live_events_v2 -v`，明确触发本次 MC 攻击、原生生物攻击和一次 TNT；检查对应目标的前后健康、唯一事件 ID、执行确认与方块变化。提交 `feat: add reconciled bidirectional combat and real explosion events`。

## Task 8: 输入、恢复、打包与完整验收

**Files:** 创建 `mc/src/client/java/dev/jay/dstmc/client/InputOwnership.java`；完善 `dst-mod/scripts/dstmc/connection.lua`；创建 `tools/{launch_bridge.command,package_release.py,record_acceptance.py}`、`tests/{test_recovery.py,test_acceptance.py}`、`README.md`、`THIRD-PARTY-NOTICES.md`；完善 `tools/prepare_test_copy.py`；按需修改 `native/src/{entry.mm,camera_service.cpp}`。

**Interfaces:** 消费前面各模块；产生 `InputOwnership.setOwner(MC|DST): void`；`prepare_test_copy.py --source PATH --dest PATH`、`launch_bridge.command`、`package_release.py --out PATH`、`record_acceptance.py --seconds 60 --out PATH`。验收 JSON 每项含 `run_id/pair/epoch/observed_at/result/evidence`，失败或未观察到均不得写 PASS。

- [ ] 写失败测试 `late_reply_does_not_reclaim_control`、`disconnect_releases_keys_and_camera`、`protocol_one_port_conflict_is_reported`、`active_save_copy_refused`、`package_excludes_private_and_game_files`。恢复测试实际重启自己的测试进程并重连，检查原点、玩家方块及未决事件。
- [ ] F8 在 MC 与 DST 间切换控制权，MC 侧使用 GLFW，DST 侧在扩展中监听本应用 F8 并经窗口服务发布归属；不依赖失焦窗口接收按键。切换时释放 MC 按键并解除光标捕获，复用任务 4 的窗口恢复；以同一 `Epoch` 管理镜头租约与输入归属。失去原生心跳 2500ms 后关闭融合、停止角色驱动，恢复原生镜头与界面；后来到达的回复不重新接管。所有退出路径释放自己的共享映射、临时加载和 GL 资源。
- [ ] 独立副本准备工具只复制无活动锁的测试存档并记录来源/目标；启动器验证路径、二进制版本、架构、端口、扩展和模组，再顺序启动。沿用用户创建的测试世界，不通过桌面自动化代建。执行前请用户保存退出 DST，以专用入口重新启动；后续只重启我们管理的测试实例。
- [ ] 运行各模块测试后执行 `python3 -m unittest tests.test_acceptance -v` 和 60 秒真实场景采样；逐项核对设计第 9 节的六项验收。另记录 960×540 物理帧的实际 FPS、延迟、状态频率、内存与丢帧；未达 30 FPS 或 20Hz 时单独标记性能未达标，不抹掉功能测试结果。
- [ ] 打包 Fabric jar、DST Lua 模组、x86_64 dylib、启动/卸载说明、源码许可及验收证据到任务总目录 `outputs/`。运行 `package_release.py` 的清单检查；通过普通入口启动一次 DST 验证退出融合后的恢复。提交 `feat: package the first-person DST Minecraft bridge and acceptance evidence`。

## 自审与实施交接

规格覆盖：设计第 1、3—6 节由任务 2—4、8 覆盖；第 7 节由任务 5—6 覆盖；第 8 节由任务 1、5、7—8 覆盖；第 9—10 节由任务 4、8 的现场验收与包检查覆盖。历史结果只作参照，不能代替新运行证据。

接口检查：共享类型只在任务 1 定义；`BlockSnapshot/BlockDelta` 在任务 5 定义并供任务 6 消费；原生渲染探针在任务 2 定义并供任务 4 消费。两个 HTTP 端口、客户端/服务端线程归属、帧尺寸、超时和结果状态均已写明。新增 MC Mixins 在实施时必须从本机当前版本源码确认描述符，编译成功仍须现场观察。

建议执行方式为 **Native**：由当前会话逐项实现，每个任务完成针对性验证，画面关口通过后再扩大范围，最后由独立审查者检查整条分支。各模块高度依赖同一帧、镜头与世界配对，串行推进能减少接口分歧。用户也可选择逐任务交给子代理实现并分别审查的方式；当前未启动任何子代理。

计划审阅确认后，按选定方式开始任务 1。进入任务 2 的游戏重启前再次查看实际进程、存档与模组状态，不重复使用历史 PID 或假设旧连接仍然有效。
