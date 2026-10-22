你接手的是一个已有代码和实测证据的跨游戏联动项目，请直接在现有进度上继续开发。

仓库：https://github.com/papa-a11y/dst-minecraft-bridge.git
项目：dst-minecraft-bridge（饥荒 × Minecraft 联动桥）

先克隆仓库，在新目录工作。依次阅读：
1. README.md、docs/HANDOFF.md。
2. docs/superpowers/specs/2026-10-21-dst-mc-first-person-design.md。
3. docs/superpowers/plans/2026-10-21-dst-mc-first-person.md。
4. handoff/development-log/task-4-axis-handoff-report.md、task-4-axis-brief.md。
5. handoff/observations/task4-gate-result.json 及 native-camera/ 下的实际截图和矩阵。

我已经确认的目标和方案：两款真实游戏同时运行，使用 MC 第一人称控制移动、建造和战斗，由真实饥荒提供世界与生物；通过 macOS native 扩展在 DST 内做真实深度合成。沿用逐项实现、分别审查的方式，不要让我重新选择视角或重新批准整个设计。

当前进度必须准确区分：
- 早期 legacy 原型曾实测真实坐标同步和 TNT 事件对应饥荒血量 1000→900，但它不是现在这套第一人称系统。
- 任务1协议/配对/账本/帧ABI、任务2 native渲染探针、任务3真实MC颜色/深度/HUD采集已完成并审查。
- 任务4有镜头、native合成、透明输入窗口的候选代码。Steam启动、x86_64扩展实际加载及持续回调已确认，也取得两帧960×540真实原生第一人称画面。
- 相机校准证明 DST 的基底有 X 反射。最新代码加入持久 REFLECT_X、两套存储升级、帧/状态/镜头一致性检查；这些是交接时保留的 WIP，尚未独立审查、尚未真实部署，不能当作已完成。
- 双游戏 camera、same_frame、transparency、depth_occlusion、UI 五项实机验收全部仍 NOT_VERIFIED；任务5–8（真实建造流、双向碰撞、正式战斗、输入恢复/打包）没有完成。

最先处理的工作：
1. 独立审查最新轴变换 WIP，重点检查 WorldTransform、PairingStore、WorldExchange、native metadata/camera/compositor、schema与缓存失效。不要推倒已有协议或无故重新实现任务1–3。
2. 修复两个已确认但尚未修正的握手不一致：Lua connection.lua 发送 mc_origin=(.5,64,.5)，Java仅接受(0,64,0)；Lua region=first-person-test，Java仅接受ground。先加能覆盖两端真实契约的检查，再统一字段，不能放宽世界身份校验来绕过。
3. 通过必要检查后，部署匹配的 Java/native，核实测试世界副本、真实DST世界UUID、配对原点和connect设置，再恢复双游戏实测。
4. 在明亮陆地通过任务4完整门禁，包含真实方块/树/生物前后遮挡、透明洞、HUD、同FrameKey、透明窗口键鼠和放块。通过后再按任务5→6→7→8推进。

坐标规则是固定的，不要局部翻图：
MC = mcOrigin + diag(-1,1,1) × (DST - dstOrigin)
DST = dstOrigin + diag(-1,1,1) × (MC - mcOrigin)
方向不加原点。轴规则与原点一起持久化，旧identity记录不得静默迁移。原共享内存ABI和identity golden fixture保持兼容。

环境与操作约束：
- Apple Silicon macOS；MC使用ARM64 Java21，MC1.21.11/Fabric0.19.5/API0.141.6+1.21.11/Loom1.14.10/Gradle9.7.1；DST最近验证build756039，native为x86_64/Rosetta。
- DST必须从Steam或由我启动，不能直接运行游戏exe。Apple Silicon正确Steam启动选项形状为：/usr/bin/arch -arm64 /usr/bin/python3 -B "<新克隆目录>/tools/steam_dst.py" %command%。旧目录的启动选项已要求清空，按新路径重新配置。
- 不改写 /Users/jay/Downloads/.minecraft/saves/DST-MC-Test 原始存档；只用用户已有世界的独立副本。DST-MC-Frame-Fixture是mock，不得当最终真实配对世界。
- 旧测试副本、完整现场证据和Git备份在本地任务外归档，位置见下方；GitHub不包含游戏本体、真实存档和完整资源。
- MC开发客户端运行时不要重建同一Loom工程；DST运行时不要覆盖已加载的native库。先保存退出，或用隔离临时构建目录。不能按历史PID杀进程。
- HTTP仅回环39379/39380；实机占用时不要跑硬编码这些端口的fixture。所有世界操作走游戏线程，图形操作走渲染线程。
- 当前native和Java的新旧版本不能混用。后台Klei仍可能有SSL错误，不绕过TLS验证，不擅改全局网络。

轴WIP历史检查：Java check 的28项断言、隔离native/200帧跨架构共享读写、18项Python/Lua/schema检查曾通过，完整命令与失败过程在handoff报告。它们不等于最新独立审查或实机验收；按自己的改动做必要复核，别反复跑无关测试。

请先报告你对当前代码状态、两个握手阻碍和下一步的理解，然后直接开展审查与修正。每个阶段说明实际改动、验证证据及剩余问题；不要把启动成功、HTTP收到请求、离屏测试或透明叠加描述成完整融合成功。除真实阻塞外持续推进，不重复询问已确认的方案。需要我点Steam或配合实机操作时，一次说明操作步骤。

本地交接备份目录：/Users/jay/Documents/项目交接/dst-minecraft-bridge-2026-10-22-220453
