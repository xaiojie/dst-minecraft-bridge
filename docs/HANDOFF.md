# 项目交接说明

交接日期：2026-10-22（Asia/Shanghai）。接收方：DeepSeek。当前停止开发，交接快照保留全部已有源代码、未审查的坐标轴 WIP 和历史提交；不把这些 WIP 描述为成品。

## 1. 已确认的目标与用户决策

- 两款真实游戏同时运行，采用“MC 第一人称控制移动/建造，饥荒提供真实世界、生物和原生行为”的路线。
- 画面通过 macOS 原生扩展进入 DST 渲染流程，使用真实颜色/深度/相机数据；MC HUD 独立处理，透明 MC 窗口接收输入。
- 首版限定本机、单玩家、独立测试存档、地面区域、完整实心立方体，先按 1 MC 方块 = 1 DST 单位。
- 用户已确认设计、实施计划和逐项实现/分别审查方式。不要要求用户重新选择视角或重新批准已确认方案。
- DST 只能由 Steam 或用户启动，禁止再次走直接游戏 exe 路径。进度不应以测试报告代替真实目标效果。

完整规格：[设计](superpowers/specs/2026-10-21-dst-mc-first-person-design.md)、[八步计划](superpowers/plans/2026-10-21-dst-mc-first-person.md)。

## 2. 各阶段真实进度

| 阶段 | 当前状态 | 已有证据与缺口 |
| --- | --- | --- |
| 早期独立原型 | 历史实测完成 | 真实两游戏坐标同步；同一真实 TNT 事件对应原生血量 1000→900。不能等同新架构事件系统完成。源码在 legacy/，证据在 handoff/observations/legacy-prototype/ |
| 任务 1：协议、配对、账本、帧 ABI | 完成并审查 | Java/native 二进制、租约、稳定原点、请求确认与去重。当前 WIP 扩展了坐标轴及存储格式，新增部分未审查 |
| 任务 2：native 渲染探针 | 完成并审查 | 真实 x86_64 进程附加，960×540，地面阶段深度研究。精灵原生 depth off，最终呈现清空深度，需要补充通道 |
| 任务 3：真实 MC 帧采集 | 完成并审查 | 真实石头颜色/深度、透明背景、独立 HUD、拆块、ARM64→x86_64 读取；历史单 MC 采集约 51.08 FPS、心跳约20 Hz，不能充当融合性能 |
| 任务 4：镜头、原生合成、透明窗口 | **未完成** | 候选实现与两轮旧代码修复已审查；Steam 加载成功、原生第一人称已采到；实际双游戏五项关口仍 NOT_VERIFIED |
| 任务 4：固定 X 反射 | **WIP，未独立审查、未部署** | Java/native/schema 与测试已有改动和历史 GREEN。停止前未提交，由交接快照统一保存；详见报告 |
| 任务 5：MC 移动权威与真实建造流 | 未开始 | 不把已有 MC 本身可放块等同跨端建造同步 |
| 任务 6：跨游戏碰撞网格/代理 | 未开始 | 仅有 native physics API 研究，不是已实现碰撞 |
| 任务 7：正式双向战斗/TNT/区块租约 | 未开始 | 早期原型仅供参考，不是此版验收 |
| 任务 8：输入切换、恢复、打包、完整验收 | 未开始 | 当前 GitHub 是开发交接源码，不是可运行发布包 |

## 3. 已实测的 Steam 启动与第一人称校准

本机 Steam 按 x86_64 运行，直接执行脚本会使 `/usr/bin/python3` 的 xcrun 以 x86_64 启动，而已装的 libxcrun 只有 ARM 架构，因此代码还没执行就退出。真实诊断已经复现，并用 ARM Python 前缀修正。Steam `%command%` 的 app 路由也在真实日志中确认。

可工作的调用形状：

```text
/usr/bin/arch -arm64 /usr/bin/python3 -B "<新克隆目录>/tools/steam_dst.py" %command%
```

随后实际观察到 Steam 父进程→wrapper→open→DST，native 的 loaded.json 及持续递增的 NSOpenGL 回调。历史 PID 只是索引，接手时必须重新验证，不能按历史 PID 结束进程。最近运行的 native SHA 为 `8079000eb6e56fa915e91fe1d5c6ae465e5eeaf494b1efced3480f0c2737a77d`，属于旧已审查版本，不是最新轴 WIP。新临时候选见下节。

两帧原生第一人称校准：frames 8947/8948，960×540，2838 draw，capture errors=[]。朝向 `(0,0,-1)`、up `(0,1,0)`、FOV90 时，MatrixV 基底 `diag(-1,1,1)`，det=-1；红标记位于 DST X-2 却显示右边、蓝标记 X+2 显示左边，与矩阵一致。因此采用持久 X 反射：

```text
MC = mcOrigin + diag(-1,1,1) * (DST - dstOrigin)
DST = dstOrigin + diag(-1,1,1) * (MC - mcOrigin)
```

方向只乘矩阵，不加原点；后续 AABB/方块/事件也必须使用同一变换。不能只翻图或在某个接口局部改符号。截图与矩阵摘要在 `handoff/observations/native-camera/`。

这两帧来自海岸/水域；最终呈现时 depth 全1属于已有清空阶段。它们证明原生相机与轴方向，**不证明地面/树/生物深度遮挡、MC 同帧融合或输入窗口**。校准12秒后观察到普通第三人称恢复。标记设置 persists=false 且15秒清理，但未逐实体统计清理结果。

## 4. 最新 WIP 内容与缺口

交接前已审查基线是 `676d46ac8fdc8417f98b002e5095f417f4157aa5`。新增 25 个文件的变更（含控制器文档）已保存为 WIP 提交 `aae1cc67482da12a7438f16758573ff049667a52`，不是已完成任务4。

- Java WorldTransform 增加 IDENTITY/REFLECT_X；旧双原点构造保留 identity。
- PairingStore 使用 DSP3，WorldExchange 使用 DMB3，保存两原点与轴模式。旧 DSP2/DMB2 解读为 identity；反射生产请求拒绝旧 identity，不能静默覆盖或迁移。
- 共享帧 ABI/布局和旧 identity golden fixture保持不变；同映射内禁止变换漂移。
- /v2/status 新增 nullable dst_origin/mc_origin/axes。native 将状态与新映射及缓存帧比对，不匹配清租约和窗口证明。旧 Java/new native 混用有意 fail closed。
- native 镜头、方向、view 转换和严格矩阵匹配支持反射；没有改 shader 翻图或放宽校验。
- 修正专用 `--shared-writer` 测试入口继续执行 client suites 的既有问题；不是生产功能变更。

**已知必须先解决的两个真实接口不一致，交接时均未修：**

1. `dst-mod/scripts/dstmc/connection.lua:39` 发送 `mc_origin={x=.5,y=64,z=.5}`，Java `WorldExchange.handshake` 仅接受 `(0,64,0)`。
2. Lua pair 的 `region="first-person-test"`，Java 生产 handshake 仅接受 `region="ground"`。

先新增覆盖真实 Lua 请求和 Java 接受条件的契约检查，再统一字段，不要通过放宽世界身份校验绕过。第二项是控制器整理交接时从相邻源代码确认的补充发现，轴工作者报告只记录了第一项。

**还没有做：** 最新轴 WIP 独立审查、真实 jar/native 同步部署、真实新握手、MC透明窗口实机键鼠/放块、两游戏同帧、实际树/生物/方块互遮挡、60秒融合性能。任务4的 camera/same_frame/transparency/depth_occlusion/ui 五项全部仍 NOT_VERIFIED。当前门禁摘要在 `handoff/observations/task4-gate-result.json`。

## 5. 验证记录与候选产物

详见 `handoff/development-log/task-4-axis-handoff-report.md`，其中完整列出 RED/GREEN、测试启动失败、兼容政策、临时目录和未做项。接手者应先复核报告，再运行与自己修改相关的必要测试；无需无差别重复所有旧测试。

轴 WIP 停止前的历史结果（控制器交接时未重新运行）：

- `mc/gradlew -p mc check --console plain`：28项 Java 契约断言通过；Gradle存在旧弃用提示，普通 test为NO-SOURCE。
- 临时 x86_64 native：实际 MatrixV 字面量、lease/transform、strict status、离屏合成、reader、GL state测试通过。
- ARM64 Java writer → x86_64 reader：完整200帧映射/租约测试通过。旧 harness 曾误跑后续 client suite失败，early-return修正后整条通过。
- 18项隔离 Python/schema/Lua/window/采样/假存档测试通过。
- 硬编码39379/39380的 NativeHttpTests 未跑，真实双游戏测试未跑。

临时 native `/tmp/dstmc-axis-native.6kxghW/libdstmc_probe.dylib` SHA `5fb38399c52eae3189957cae33b41cdd3ae0c6091941b766487471792d8bd2e0`。这些临时文件不属于远程发布包，不能默认它们仍存在或已部署。旧现场 native 与源码最新 WIP 有区别。

## 6. 本机环境、存档与现场操作

- 原始 MC 安装与不可写存档：`/Users/jay/Downloads/.minecraft`，原始世界 `saves/DST-MC-Test`。
- 已准备的正式副本曾位于旧工作树 `mc/run/saves/DST-MC-FirstPerson-Test`，最后确认未配对；旧目录清理后从任务外本地备份恢复或按工具重新准备。`DST-MC-Frame-Fixture` 是 mock 专用世界，不能拿来作最终真实配对。
- ARM64 Java21：`/Library/Java/JavaVirtualMachines/liberica-jdk-21-full.jdk/Contents/Home`；MC本地 assets index29，`mc/build.gradle` 仍有本机绝对资产路径。
- DST app：`/Users/jay/Library/Application Support/Steam/steamapps/common/Don't Starve Together/dontstarve_steam.app`；测试 Cluster_1 在用户 Documents/Klei/DoNotStarveTogether/434082735 下，历史 Master session EB92AD2F368F31F7。
- 已安装 Lua 模组 `Contents/mods/dst_mc_first_person`；最后配置 connect=false。旧探针禁用。改成真实连接前须核对世界UUID和MC副本身份，并按已保存变换对接。
- native历史实际GL渲染960×540，而桌面截图1920×1136含标题栏，不能混用。
- 部分 Klei后台服务仍有SSL错误；进入本地世界成功不等于所有在线服务恢复。不要绕过TLS验证或改全局代理。
- CUA SteamHelper可读但点击曾报frontmostApplicationChanged，必要时由用户点Steam启动；DST控制台用typeText，paste会发生旧剪贴板竞态，Cmd/Ctrl+A未清空SDL输入。经验证的清空方法是历史Up后Down到空行，输入后截图核对，再Return。
- 用户要求清空旧目录，原Steam启动选项已要求清空以免悬空。新clone后重新生成绝对路径配置；不要复用旧路径。

## 7. 最优先的接手顺序

1. 读本文件、设计/计划、轴 WIP 报告并独立审查最新改动，检查两个持久存储、严格 schema、相机/缓存变换和旧identity拒绝逻辑。
2. 修复上述 Lua/Java 的 origin 和 region 不一致，并验证匹配的真实契约。此时仍不启动任务5–8。
3. 保存退出当前真实游戏后，构建匹配的Java/native，准备并核对独立MC副本、世界身份、connect设置及原点。只能经Steam/用户启动；实际进程加载、持续回调与握手分别核实。
4. 在明亮陆地，完成任务4相机/同帧/透明/深度遮挡/UI五项实机门禁，另测透明窗口键鼠和放块。保留失败帧、FrameKey、实际矩阵和同帧证据。
5. 全部通过后按既有任务5→6→7→8实施：移动与建造→跨端碰撞→双向战斗/TNT→输入恢复、打包和60秒性能。

不要重新开展需求讨论、代建用户世界、直接改写原始存档、混用旧原型与新架构完成状态，或把离屏检查/alpha叠加/HTTP请求接收当成真实融合完成。
