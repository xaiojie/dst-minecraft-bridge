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



# Controller notes (draft; Task3 handoff pending)
Read task-4-camera-notes.md for a measured native camera handedness risk and near/far calibration. Do not infer complete camera matching from nominal FOV. Task2 diagnostic native scene profile/evidence is at evidence/render-probe-3/forest-paused-depth/identification.json and task-2-report.md; current game build756039. Native shader sources were hashed, not stored; actual linked shader fingerprints distinguish observed ground/sprite/final-composite roles, with explicit uncertainty for unseen paths.

The same-frame ground-depth bytes remain unchanged across the complete tree/crow/avatar sprite phase. A supplemental alpha-aware sprite depth path is load-bearing, not optional; native default framebuffer depth is all1 after postprocess. Replay original draw geometry immediately while program/texture/vertex state is still valid, only for verified scene roles, preserving the shader's alpha silhouette, and restore every changed state. This is a candidate to validate, not an accepted implementation.

Controller owns all desktop UI. No shell-based AppleScript/CGEvent/OS UI automation. Game APIs, test startup and rendering tests are allowed; do not launch/rebuild a game extension while an existing instance is active without coordinating controller. Previous native world has a verified save-only backup under evidence/backups/DST-before-native-render.


# Task3 concrete handoff (review pending; no Task4 implementation yet)
Task3 candidate commit1900a29ed25231c61dcc701ed654d3eb220d160d. Read task-3-report.md for full runtime/build commands and evidence. Actual1920x1080 world/depth/HUD via x86_64 leased reader worked, including real stone removal; final60second capture51.08FPS/20Hz (not composition performance). Both games currently stopped; Java7966 seen on process inventory may be Gradle daemon, never terminate by historicalPID.

MC BridgeMod.server exposes BridgeServer.active() returning HandshakeResult(pair,epoch,transform,reason), framesDirectory(), updateStream(session,Stream), invalidateStream(). Status explicit UNPAIRED/PAIRED with mc_world,pid,run_id,started_at_ms,heartbeat,peer_last_seen_ms,fixture,stage_ready,frame_path,generation,latest_frame,width,height. Read strict JSON schema before implementing consumer. Existing /v2/exchange accepts empty commands/damage only, serving peer heartbeat untilTask5. Do not invent a second protocol or separate pairing directory. Frame files use fresh epoch/generation-specific paths and exact FrameKey; respect reader leases. WorldExchange persists first origin; later handshake uses stored anchor.

Actual dev run: JAVA_HOME=/Library/Java/JavaVirtualMachines/liberica-jdk-21-full.jdk/Contents/Home ./gradlew runClient -x downloadAssets (from mc; see build.gradle/jvmArgs). Installed assets /Users/jay/Downloads/.minecraft/assets index29. Do not rebuild with a live client. mc/run/saves/DST-MC-FirstPerson-Test exists and is deliberately unopened/unpaired for real native identity; never use mock DST pairing there. mc/run/saves/DST-MC-Frame-Fixture contains mock identity and must not be used as final real pairing.

Task3 fixture VM property is narrowly restricted to exact DST-MC-Frame-Fixture; its BackupConfirmScreen loader creates official backup before official continuation. Do not pass fixture property for final copy, do not silently generalize its loader. Current CUA cannot bind unbundled Java (inventory omits it; getApp realJava path returns Invalid app). Controller can coordinate final-copy startup; real input acceptance still needs actual OS keyboard/mouse through permitted UI or human operation, not in-game synthesized input.

Old native probe remains enabled in current Master/modoverrides.lua: return { dst_mc_probe={ configuration_options={ }, enabled=true } }. Controller will back up config and disable old probe / enable new adapter before native launch, preventing old auto-tests/position writes. Build new adapter first; tell controller when installation and native launch are needed. Native full executable path and launcher/preflight settings are in task-2-report.md; current app build756039, saved forest checkpoint, verified save-only backup retained. Steam may need normal launch before native startup.


# Retina alignment risk to resolve explicitly
Observed same nominal logical960x540: DST actualGL960x540 while desktop screenshotcontent1920x1080; MC actualGL1920x1080. Aligning windowcontent bounds alone is insufficient. A candidate is configure MC dedicated bridge window framebuffer scaling hint before GLFW window creation (inspect installed pinned GLFW macOS Retina hint support), giving MC physical capture resolution matching DST render viewport while preserving true screen content bounds. Alternatively define and verify an explicit resample/projection mapping. This is a candidate, not measured acceptance. Do not equate NSWindow backingpixels to actual renderpixels or declare mismatch resolved from screenshot size. /v2/window must report each real quantity clearly; resize cancels leases and forces a fresh matched generation. Nominal FOV and nominal width/height alone are insufficient.
