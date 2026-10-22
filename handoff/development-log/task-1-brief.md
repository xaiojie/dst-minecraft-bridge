## Task 1: 可验证的协议、配对和新工程基础

**Files:** 创建 `protocol/frame-v2.md`、`protocol/http-v2.schema.json`、`protocol/fixtures/*`；创建 `mc/{build.gradle,settings.gradle,gradle.properties,gradlew,gradle/wrapper/*}`、`mc/src/main/java/dev/jay/dstmc/protocol/{BridgeTypes,WorldTransform,PairingStore,RequestLedger,FrameLayout}.java`；创建 `mc/src/contractTest/java/dev/jay/dstmc/ContractTests.java`、`mc/src/contractTest/java/dev/jay/dstmc/protocol/ProtocolContractTest.java`、`native/include/frame_protocol.h`、`native/tests/frame_contract_test.cpp`、`native/Makefile`、`.gitignore`。

**Interfaces:** 产生上述全部共享类型；Java `WorldTransform.toMc(Vec3): Vec3` / `toDst(Vec3): Vec3`、`PairingStore.loadOrCreate(PairKey, Vec3 dstOrigin, Vec3 mcOrigin): WorldTransform`、`RequestLedger.receive(Command): CommandResult` / `finish(UUID, CommandResult): void`；C++ `read_frame(const void*, size_t, FrameKey expected): optional<FrameView>`，`FrameView` 为已校验的只读槽视图。

- [ ] 写失败测试：`coordinate_roundtrip` 断言 DST 原点 `(100,0,-50)`、MC 原点 `(0,64,0)` 时 `(106.5,2,-47)` 映射为 `(6.5,66,3)` 且可逆；`restart_keeps_origin` 重启存储后原点相同；`foreign_epoch_rejected` 拒绝旧会话；`receipt_is_not_application` 收到只返回 PENDING，重复收到不执行两次，重启后未决项为 UNRESOLVED。
- [ ] 从旧工程仅复制 wrapper 和已核对的版本配置，建立独立 Java main 测试总入口 `ContractTests.main(String[])`，后续任务的测试加入同一总入口；执行 `cd mc && ./gradlew coreTest --console plain`，确认失败针对未实现接口；随后实现上述协议核心，不复制旧自动 TNT 和传送循环。核心断言包括 `toMc(new Vec3(106.5,2,-47)).equals(new Vec3(6.5,66,3))`、`receive(c).status()==PENDING`、`receive(oldEpoch).status()==REJECTED`。
- [ ] 写并运行 C++ 失败测试：Java 导出的固定二进制样本可读；截断文件、奇数序列、超大尺寸、NaN 矩阵、不同会话均不可读；用 `make -C native contract-test` 观察预期失败，再实现布局读取与边界检查。原子提交和租约测试使用真实共享映射，不仅检查打包字节。
- [ ] 运行 `./gradlew coreTest` 与 `make -C native contract-test`；输出 Java ARM64 写入、C++ x86_64 读取同一样本的通过记录。固定样本的格式断言属于跨语言兼容测试。
- [ ] 仅提交本任务列出的实现、配置和样本：`git commit -m "feat: add versioned bridge protocol and persistent world pairing"`。


# Binding shared context from approved plan

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
