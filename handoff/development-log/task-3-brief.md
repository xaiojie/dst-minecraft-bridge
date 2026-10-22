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


# Controller notes
Read mc-render-research.md for pinned-source findings. Task 2 runtime observations below are verified; Task 3 still starts only after Task 2 independent review approval.

## Current native evidence and runtime adapter rulings
- Native executable build756039, x86_64 Rosetta; isolated launcher now uses an owned temporary documented Steam app-ID hint. Actual native client PID20074 is paused; do not terminate or rebuild native sources. Controller will coordinate any game UI.
- Native GL viewport960x540 corresponds to screenshot1920x1136 including56px title, so window capture pixels and render pixels must never be equated.
- Real shader camera is perspective, native near approximately1/far200. Scene FBO has valid ground depth; sprites (trees/crows/avatar) use depth test/write off; final default FBO depth all1. Task4 supplies alpha-aware sprite depth. Native diagnostic report and forest-paused-depth identification.json will be available; this task only publishes MC frames.
- Pinned MC rendering source findings and camera/full-view convention are in mc-render-research.md. Use actual view/projection from rendering and reconstruct full world view from rotation+eye position. Capture complete GPU readback only; keep mappings/leases generation-safe.
- Runtime uint64 values consumed by Lua must be validated as exactly representable (0..2^53-1) and fail explicitly outside supported range, never silently rounded. Keep binary ABI uint64 and document the HTTP adapter support bound.
- FrameLayout numeric payload snapshots use BigDecimal; handle Number. read_frame requires an exact committed FrameKey. Publish latest_frame plus generation mapping path in status so the future native reader discovers keys without racing header reads.
- Do not copy account data, credentials, or full assets into the repository. Original MC save stays unchanged. Use the compatible source FileChannel lock throughout copy and the separate run/saves destination specified above.

- Live test handshakes must not permanently bind the intended final test copy to a mock DST identity. A separate throwaway save copy for frame-capture fixture tests is allowed; keep the required DST-MC-FirstPerson-Test copy unpaired for the real DST world in Task4, or document an equally safe strategy. Never silently re-anchor an already paired save.

## Verified local build/asset paths
Current mc/build.gradle remains the Java-only protocol test setup. The previous verified Fabric build is ../../../dst-mc-probe/mc/build.gradle relative to this worktree; inspect it only for pinned Loom/assets setup, do not overwrite old prototype. Existing source save currently has level.dat and session.lock at /Users/jay/Downloads/.minecraft/saves/DST-MC-Test. No Java game process was observed on resumed preflight. JAVA_HOME for builds is /Library/Java/JavaVirtualMachines/liberica-jdk-21-full.jdk/Contents/Home. Installed assets are /Users/jay/Downloads/.minecraft/assets; launch cfg must use asset index29 rather than Loom renamed1.21.11-29. All exact version properties are already in mc/gradle.properties.

## Controller-authorized interface correction
StatusResponse currently has strict additionalProperties=false and no discovery fields. You may modify protocol/http-v2.schema.json and protocol/frame-v2.md for the minimal status/stream contract: explicit paired versus unpaired state; persistent mc_world; fresh pid/run identity and heartbeat; latest_frame and mapping path/generation for exact-key native leasing. Preserve strict property checks and add tests validating actual emitted responses. Keep existing handshake request and binary frame ABI; no arbitrary extra-property escape hatch or unrelated endpoint changes.

## Authorized bounded fixture loader (after confirmed startup gate)
CUA cannot bind unbundled Java; actual dev-screen log confirms BackupConfirmScreen for experimental custom dimension. You may add a narrow in-engine startup helper/mixin, gated by BOTH dev property and exact DST-MC-Frame-Fixture save ID/path. Call official world backup and continue official world load only on success; backup failure must not continue. No synthesized desktop clicks/keys; no general UI helper, no final/original save use. Add focused guard/order tests and actual backup evidence. Actual future transparent-window keyboard/mouse acceptance still requires real input.
