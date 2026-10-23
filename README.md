# DST × Minecraft Bridge

保留真正的 Minecraft 第一人称和真正的《饥荒联机版》世界，通过 Fabric 模组、DST Lua 模组和原生渲染扩展连接两款游戏。当前主开发方向为 **Windows x64 原生运行**，保留 macOS 适配；不需要 CrossOver 或 Wine。

**2026-10-23 开发版：四项功能的编码已接通，发布状态为待实机验收。** 本轮完成了旧帧修复、场景深度与手臂/HUD 合成、真实方块与碰撞、双向受击/TNT、保存恢复和输入切换。自动化测试与离屏渲染验证不能代替两款游戏中的最终效果验证。

Windows 迁移增加 ANGLE/GLES2/EGL 原生 DLL、Steam 包装入口、窗口尺寸引导、Windows 文件锁与持久化、CMake/CI 和开发包。构建、安装、启动和共同验收步骤见 **[Windows 开发与验收](docs/windows-start.md)**。Windows 实机合成、键鼠、碰撞与性能尚未验收。

当前说明以 [本轮开发交付](docs/development-2026-10-23.md)、[当前交接](docs/HANDOFF.md) 和源码为准。旧 `handoff/` 中的“任务5–8未开始”等内容是历史记录。

| 模块 | 职责 |
| --- | --- |
| `mc/` | 真正的第一人称、物品栏、方块、玩家运动/血量；帧发布、世界交换、地形与生物代理 |
| `dst-mod/` | 真实饥荒世界和生物行为；相机、碰撞网格、伤害账本、原生状态采样 |
| `native/windows/`、`native/CMakeLists.txt` | Windows x64 ANGLE/GLES2/EGL、相机/帧映射、深度合成、输入与 DPI 窗口适配 |
| `native/src/`、`native/Makefile` | macOS x86_64 OpenGL 适配与公共帧/租约逻辑 |
| `protocol/` | 帧 ABI、JSON schema、[玩法与相机协议](protocol/gameplay-v2.md) |
| `tools/`、`tests/` | 构建检查、启动预检、打包和独立实机验收工具 |

首版范围：本机单玩家、MC 集成服务器、DST 地面世界、完整实心立方体、1 MC 方块 = 1 DST 单位、固定 X 反射。MC 负责玩家移动/物品/血量及方块；DST 负责原生生物和世界。楼梯、流体、红石、多玩家和洞穴不在本版联动范围。

## 构建与检查

通用版本：Java 21、Minecraft 1.21.11、Fabric Loader 0.19.5、Fabric API 0.141.6+1.21.11。

Windows：x64 Python、JDK 21、Visual Studio 2022 C++ 工具和 CMake；`python -m pip install lupa jsonschema` 后运行 `python -X utf8 tools/check_development.py --out evidence/windows-local-01`。原生 Loader/HTTP 烟雾测试不启动游戏，也不模拟合成成功。

macOS：Apple Silicon、ARM64 Java 21、Xcode Command Line Tools、Rosetta。Mac 原生渲染适配基于 DST build 756039 的历史 shader 指纹；当前重装后的 build 759671 及后续更新仍需重新实测。

退出测试游戏后，在仓库根目录运行：

```sh
uv run --with lupa --with jsonschema python tools/check_development.py --out evidence/development-check
```

输出目录必须不存在。工具依次执行 Java 干净构建/契约测试、原生跨架构与 OpenGL 测试、Python/Lua 离线测试，并保存原始日志和结果。它不会启动游戏。单独构建入口为 `cd mc && ./gradlew check build --console plain` 与 `make -C native all`。

## 运行与交付

- 只使用 `tools/prepare_test_copy.py` 创建的独立 MC 存档副本；桥接服务拒绝未准备的存档。仓库和开发包不包含游戏本体、账号令牌或存档。
- Java 模组 0.2.0、DST 模组 0.5.0 与本次 native 库必须配套。DST 模组的 Connect 配置需要启用；默认仍为关闭。
- `python3 tools/launch_bridge.py` 只做预检并打印当前目录对应的 Steam 启动选项；安装匹配模组和 Steam 入口后，`--start` 才会请求启动。详见 [Steam 入口](docs/steam-start.md)。
- MC 资源目录默认 `~/Downloads/.minecraft/assets`；启动器可用 `--assets`，Gradle 可用 `-PminecraftAssets=绝对路径` 指定。
- 打包：`python tools/package_release.py --platform windows --out /绝对路径/dst-mc-windows-development.zip`（macOS 选择 `--platform macos`）。输出包含源码、配套 jar 与 DLL/dylib 和逐文件 SHA-256，标记 `live_acceptance: NOT_VERIFIED`。
- F8 在 MC 与 DST 之间切换输入；断线时恢复原生相机/控制器，MC 保持当前位置，重新取得有效地形和角色状态后恢复移动。

真实画面、键鼠、放置障碍、攻击、重进存档、登高和 60 秒性能仍须按开发交付文档逐项验收。
