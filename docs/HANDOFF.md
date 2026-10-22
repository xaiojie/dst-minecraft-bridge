# 项目交接说明

更新：2026-10-23。接手方 DeepSeek 已在新克隆目录 `dst-minecraft-bridge-3` 完成一轮复核、修复与实机联调。本文描述**当前真实状态**，不把未验证的东西写成通过。

## 1. 已确认的目标与用户决策

- 两款真实游戏同时运行，采用“MC 第一人称控制移动/建造，饥荒提供真实世界、生物和原生行为”的路线。
- 画面通过 macOS 原生扩展进入 DST 渲染流程，使用真实颜色/深度/相机数据；MC HUD 独立处理，透明 MC 窗口接收输入。
- 首版限定本机、单玩家、独立测试存档、地面区域、完整实心立方体，先按 1 个 MC 方块 = 1 DST 单位。
- 用户已确认设计、实施计划和逐项实现/分别审查方式；不要要求用户重新选择视角或重新批准已确认方案。
- DST 只能由 Steam 或用户启动；不要直接运行游戏可执行文件。进度不应以测试报告代替真实目标效果。

完整规格：[设计](superpowers/specs/2026-10-21-dst-mc-first-person-design.md)、[八步计划](superpowers/plans/2026-10-21-dst-mc-first-person.md)。

## 2. 各阶段真实进度

| 阶段 | 当前状态 | 证据与缺口 |
| --- | --- | --- |
| 早期独立原型 | 历史实测完成 | 真实两游戏坐标同步；同一真实 TNT 事件对应原生血量 1000→900。不能等同新架构事件系统完成。源码在 `legacy/`，证据在 `handoff/observations/legacy-prototype/`。 |
| 任务 1：协议、配对、账本、帧 ABI | 完成并审查 | 本轮又复核了坐标轴 WIP（`aae1cc6`）：`WorldTransform` 数学、DSP3/DMB3 持久化、`TRANSFORM_MISMATCH` 拒绝路径、帧内轴不可变、status 轴/原点、native 严格校验均正确。 |
| 任务 2：native 渲染探针 | 完成并审查 | 真实 x86_64 进程附加，960×540，地面阶段深度研究。 |
| 任务 3：真实 MC 帧采集 | 完成并审查 | 真实石头颜色/深度、透明背景、独立 HUD、拆块、ARM64→x86_64 读取；本轮实机再次确认 960×540 与 480×270 两种流尺寸都能被 native 正确读取。 |
| 任务 4：镜头、原生合成、透明窗口 | **进行中** | **已实机拿到第一人称合成画面**（camera / same_frame / ui 三项已观察），透明区与深度遮挡未做像素级验收，透明输入窗口/放块与 60 秒性能未验证。任务 4 未完成，禁止进入任务 5。 |
| 任务 5：MC 移动权威与真实建造流 | 未开始 | 不把已有 MC 本身可放块等同跨端建造同步。 |
| 任务 6：跨游戏碰撞网格/代理 | 未开始 | 仅有 native physics API 研究，不是已实现碰撞。 |
| 任务 7：正式双向战斗/TNT/区块租约 | 未开始 | 早期原型仅供参考，不是此版验收。 |
| 任务 8：输入切换、恢复、打包、完整验收 | 未开始 | 本轮已顺带修好“断线即永久停用”的恢复缺陷。 |

## 3. 本轮修复的确定性问题

1. **坐标轴 WIP 复核**：结论是数学与持久化正确；记录三个非阻塞观察——`PairingStore` 在生产代码里没有调用者、损坏 mode 名抛 `IllegalArgumentException` 而非统一包装、旧 DMB2 identity 绑定会被 `TRANSFORM_MISMATCH` 拒绝且无自动迁移。
2. **两个握手契约不一致**（已修）：
   - `connection.lua` 原来发 `region="first-person-test"`，Java 只接受 `ground`；
   - 原来发 `mc_origin=(0.5,64,0.5)`，Java 只接受 `(0,64,0)`。
   - 先把两端契约写成测试（`tests/test_handshake_contract.py`：lupa 真跑 Lua 截获真实 body，javac 编译真实 `WorldExchange` 网关并喂入该 body，附两个负向对照），RED 后修 Lua，GREEN。没有放宽 Java 的世界身份校验。
3. **租约生命周期**（已修）：原实现要求“请求的帧号恰好等于最新帧”，而 MC 每 ~34ms 发布一帧，必然 `exact frame changed`。现在 native 接受同会话中仍可读的精确帧；读不到时回退钉住最新帧并把**真实 key** 回给客户端，客户端以返回 key 为准。
4. **ack 空档导致的闪烁**（已修）：合成不再等待 ack（ack 只用于 `/v2/window` 证明），租约钉住的帧在每一帧绘制都参与合成；`present()` 不再释放 pin。
5. **尺寸/时序导致的“合成不可见”**（已修）：
   - `matching_camera` 原来要求 drawable 尺寸**精确等于**流尺寸，改为**同宽高比**（容差 0.1%），归一化采样本就与分辨率无关；
   - 合成原来放在场景绘制中途，被后续 pass 覆盖，只剩 HUD；现在移到 `present()`、`flushBuffer` 之前直接写入窗口 drawable。
6. **native HTTP 封帧**（已修）：原来只认 `Content-Length`，Java 一半认 chunked / `Expect: 100-continue`。已补齐两种封帧、拆出可测的 `serve_client()`，新增 `native/tests/http_framing_test.mm`（含坏终止符、截断、gzip 等负例）。
7. **DST 侧断线恢复**（已修）：原 `M.Release()` 在“流暂时为空 / epoch 变化 / 交换失败”时把 `enabled` 永久关掉，MC 一重启桥就死。现在这些路径只 `reset_session()` 并重新握手，只有显式 Release 才停用；新增 Lua 回归测试。
8. **隔离构建**：`native/Makefile` 的 `./$(BUILD)` 在 `BUILD=/tmp/...` 下拼错，导致 `gl-test`/`reader-test` 等目标不可用；已修。
9. **文档路径**：`docs/steam-start.md` 的旧绝对路径已指向当前克隆目录。

## 4. 实机联调进展与证据

- 配对真实成功：DST 世界 UUID `b02d4f86-9be4-44cb-9034-7e68754951a4`，MC 世界 `7ffd8ed7-caf1-407b-ad77-92caebabcc27`，`dst_mc_bridge:stage` / `ground`，`axes=[-1,0,0,0,1,0,0,0,1]`，`dst_origin≈(-181.087,0,459.404)`、`mc_origin=(0,64,0)`。
- 第一帧真实合成：`compose key=4082 status=0 "matched complete frame"`；随后稳定运行，最近一次统计 **60/60 COMPOSITED**，并在 480×270 流 + 960×540 drawable 下同样 30/30 通过。
- 证据：`handoff/observations/task4-live/first-composite-74.png`（DST 窗口内可见石头地、带玻璃窗的石墙、橡树、近处方块与 MC 准星，外层是 DST HUD）与同名 `.json`；原始 gate 日志在 `evidence/steam-launches/`。
- DST 侧相机循环实测约 640ms 一轮（`camera-gate.jsonl` 中 473 次 accepted ack 间隔 p50 638ms），因此租约默认有效期定为 1 秒（`DSTMC_LEASE_MS` 可临时覆盖）。

## 5. 当前缺口与风险（按优先级）

1. **Task 4 剩余 gate**：玻璃透明区像素级验证、树/近方块/DST 生物的前后遮挡、透明输入窗口键鼠与放块、60 秒融合性能。camera/same_frame/ui 只是“观察到”，还需按验收格式落证据。
2. **MC 服务端每轮启动会在 y=63 铺 invisible barrier**（`BridgeServer.tick`），会把手铺的石头地板在中心 33×33 区域变成隐形方块；下轮启动后需要重新铺一次，或后续把“场景初始化”改成不覆盖已有方块。
3. **MC HUD 会被 DST HUD 覆盖**：合成把 MC 的 HUD 层画在 DST 本体之上，但 DST 自己的 HUD 随后绘制，底部物品栏区域互相遮挡；MC 的手臂（hand pass）不在世界帧里，所以看不到手。二者属于已知设计边界，需在 ui gate 里明确定义期望。
4. **stage 仍是空虚空维度**，按计划到任务 6 才替换为精确桥接形状；本轮临时布置的验收场景（97×97 石地板、±32 围墙、石墙+玻璃窗、小树、出生点）属于测试布景，不是产品内容。
5. 用户对反复重启 DST 已明显不耐烦；任何 native 改动都必须攒批次、一次重启验证。

## 6. 本机环境与现场操作

- 当前克隆：`/Volumes/OS/Work/个人开发/dst-minecraft-bridge-3`（接手提交 `a0de3bc`，main）。
- MC 原始安装 `/Users/jay/Downloads/.minecraft`，原始世界 `saves/DST-MC-Test`（**不写**）；本轮用 `tools/prepare_test_copy.py` 生成独立副本 `mc/run/saves/DST-MC-FirstPerson-Test`（无 `dst-mc-bridge/binding.bin`）。
- MC 开发客户端：`./mc/gradlew -p mc runClient`，`--quickPlaySingleplayer DST-MC-FirstPerson-Test`，`mc/run` 为运行目录；`mc/run/options.txt` 已写 `onboardAccessibility:false` 跳过引导弹窗。
- DST：Steam 启动项
  `/usr/bin/arch -arm64 /usr/bin/python3 -B "/Volumes/OS/Work/个人开发/dst-minecraft-bridge-3/tools/steam_dst.py" %command%`
  （**不要再加 `-offline`**：离线模式会让 Klei 账号登录判失败并报“连不上服务器”；在线模式下那些 SSL 报错只是日志噪音）。
- 模组安装目录：`.../dontstarve_steam.app/Contents/mods/dst_mc_first_person`（写入需要 macOS「App 管理」权限）。
- DST 窗口固定 960×568 点（drawable 960×540，16:9），与 MC 流同宽高比；窗口尺寸持久化在 `~/Documents/Klei/DoNotStarveTogether/434082735/client.ini` 的 `[graphics] windowed_width/windowed_height`。
- native 部署：`native/build/libdstmc_probe.dylib`（x86_64）；换库必须先退出 DST。
- Klei 域名当前解析到 Clash TUN 的假 IP（`198.18.x.x`），登录接口时好时坏；不要绕 TLS、不要改全局网络配置。

## 7. 接手顺序（下一次迭代）

1. 复跑：`mc/gradlew -p mc check`、`make -C native BUILD=/tmp/... all lease-test compositor-test transform-status-test http-framing-test`、`uv run --with lupa --with jsonschema python -m unittest ...`。
2. 重新启动 MC 客户端，补铺石头地板（barrier 覆盖问题），确认 `/v2/status` 有 `latest_frame`、DST 侧自动重新配对（本轮已加恢复逻辑）。
3. 按验收格式完成 Task 4 的五项：camera（走动/转动时画面跟手）、same_frame（窗口证明 200 + 帧号一致）、transparency（玻璃窗像素）、depth_occlusion（树/近方块/DST 生物）、ui（DST HUD 与 MC HUD 的期望关系）；再测透明输入窗口键鼠与放块、60 秒性能。
4. 五项全过后才进入任务 5→6→7→8。

不要重新开展需求讨论，不要代建用户世界，不要改写原始存档，不要把离屏测试或 alpha 叠加当成真实融合完成。
