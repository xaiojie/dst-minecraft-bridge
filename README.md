# DST × Minecraft Bridge

一个正在开发中的 macOS 跨游戏联动实验：让玩家使用 Minecraft 第一人称移动、建造和战斗，同时看到并影响真实的《饥荒联机版》世界。

**当前不是可日常游玩的成品。** 协议、原生探针、MC 帧采集已审查；固定 X 反射经独立复核并已实机生效。**双游戏第一人称合成已首次稳定出现**（camera / same_frame / UI 三项已观察），但透明区、深度遮挡、透明输入窗口与 60 秒性能仍未验收，任务 4 未完成。建造、通用双向碰撞和正式战斗系统尚未开始。

开始接手请先读 [完整交接说明](docs/HANDOFF.md) 和 [DeepSeek 接手提示词](handoff/DEEPSEEK_PROMPT.md)。资料有冲突时，以 HANDOFF.md 的当前状态和源代码为准，旧日志只用于追溯。

| 目录 | 内容 |
| --- | --- |
| `mc/` | Minecraft 1.21.11 / Fabric Java 模组、共享帧发布和桥接服务 |
| `dst-mod/` | 饥荒 Lua 模组、持久世界身份和镜头适配 |
| `native/` | macOS x86_64 OpenGL 探针、镜头服务、深度与合成候选实现 |
| `protocol/` | v2 协议、严格 JSON schema、跨架构二进制 fixture |
| `tests/`、`tools/` | 离线/现场测试、Steam 入口、预检和存档副本工具 |
| `docs/superpowers/` | 用户已确认的设计与八步实施计划 |
| `handoff/` | 进度账本、逐项报告与审查、代表性实测证据、接手提示词 |
| `legacy/dst-mc-probe/` | 早期坐标/TNT 原型源码，仅供参考 |

## 已确认的环境

- Apple Silicon macOS；MC 使用 ARM64 Java 21，DST 与图形扩展为 x86_64 / Rosetta。
- Minecraft 1.21.11，Fabric Loader 0.19.5，Fabric API 0.141.6+1.21.11，Loom 1.14.10，Gradle 9.7.1。
- DST 最近验证 build 756039，真实渲染缓冲为 960×540。
- HTTP 仅回环：MC 39379、native 39380。颜色/深度/HUD 通过有租约的共享内存帧传递。

## 运行前约束

1. 饥荒必须从 Steam 启动，或由用户操作启动；旧 `tools/preflight.py --launch` 已禁用。Apple Silicon 上需显式 ARM Python 前缀，参见 [Steam 启动说明](docs/steam-start.md)。克隆后必须更新其中的旧绝对路径。
2. 不写原始 MC 存档；使用用户创建的测试存档副本。仓库不包含游戏本体、完整资源、账号令牌或真实存档。
3. 先审查 WIP 并修复两个握手参数不一致，再部署匹配的 Java/native 版本。不要把旧 jar 与新 native 混用。
4. 不在 MC 开发客户端运行时构建同一 Loom 工程；不覆盖运行中 DST 已加载的 native 库。
5. 真实相机/同帧/透明/深度遮挡/UI 五项全通过后，再推进实施计划任务 5–8。

## 构建与验证入口

在 Java 21 环境下运行 `cd mc && ./gradlew check --console plain`。普通 `test` 可能显示 NO-SOURCE，实际契约检查是 `coreTest`。

在没有运行本项目 DST 扩展的情况下，可运行 `make -C native all gl-test lease-test reader-test transform-status-test`；跨架构契约入口为 `make -C native contract-test`。如需边运行旧游戏边检查新 native，请按交接报告使用临时构建目录及绝对测试执行路径。

Python 的 schema/Lua 测试需要 `jsonschema`、`lupa`。完整 discovery 会包含真实端口监听和实机测试，不能在游戏占用端口时盲目执行。历史实际命令与输出见 [轴修正交接报告](handoff/development-log/task-4-axis-handoff-report.md)。

资产路径和默认测试存档路径仍有本机配置；`runClient` 前须核对 `mc/build.gradle` 和 `tools/preflight.py`。构建通过不代表双游戏实机验收通过。
