# Windows 原生开发与实机验收

当前版本提供 Windows x64 原生代码与构建入口，两款游戏直接运行，不需要 CrossOver、Wine 或 Windows 虚拟机。真实 Windows 双游戏画面、键鼠、玩法及性能验收仍为 **NOT_VERIFIED**；构建和离线契约通过不会自动改变这个状态。

## 环境和取代码

- 实体 x64 Windows 10/11，Steam 已正常登录，饥荒联机版通过 Steam 启动。
- 正版 Minecraft Java Edition 1.21.11，先用启动器完成一次正常安装并进入独立测试世界。Minecraft 资源由自己的启动器下载，不包含在仓库里。
- x64 JDK 21，设置 JAVA_HOME；x64 Python 3.11 或更新版本；CMake 3.20 或更新版本；Visual Studio 2022 的“使用 C++ 的桌面开发”组件。
- 在两款游戏退出后构建和复制存档。建议先用 960×540 窗口模式；本版帧 ABI 上限为 1920×1080。首次验收使用单玩家、地面世界和完整实心方块。

在 PowerShell 中：

```powershell
git clone --branch codex/complete-fusion https://github.com/xaiojie/dst-minecraft-bridge.git
cd dst-minecraft-bridge
python -m pip install lupa jsonschema
python -X utf8 tools/check_development.py --out evidence/windows-local-01
```

输出目录必须尚不存在。此命令发现 Java 21，先构建原生 DLL/测试，再构建 Fabric 模组、运行 Python/Lua 检查。Gradle 通过 Java wrapper JAR 启动，不依赖缺失的 gradlew.bat 或命令行拼接。CMake 自动下载固定 SHA256 的 MinHook 和 nlohmann/json；网络失败时保留日志并重试构建。

原生 DLL 位于 `native/build-windows/dstmc_bridge.dll`，Fabric jar 位于 `mc/build/libs/`。原生构建和测试也可单独运行：

```powershell
cmake -S native -B native/build-windows -A x64
cmake --build native/build-windows --config Release
ctest --test-dir native/build-windows -C Release --output-on-failure
```

GitHub Actions 的 “Windows native development checks” 运行同一检查流程，并上传包含逐文件校验清单的开发包及原始日志。它不会运行两款游戏或验证 Steam/Klei 登录。

## 安装 DST 模组并准备独立世界

```powershell
python -X utf8 tools/deploy_dst_mod.py
python -X utf8 tools/deploy_dst_mod.py --apply
```

第一条仅预览，第二条在饥荒退出后安装配套 Lua 模组。工具只接受 Steam 当前登记的安装位置，替换旧模组前将它移动到 `mods/.dstmc-backups/<唯一标识>/original`，失败时恢复。它不会读写游戏存档，也不自动更改 Steam 启动选项。

饥荒通过 Steam 新建一个专用的本地测试世界，在该世界的服务器模组中启用 **DST MC First Person Bridge** 并开启 Connect。不要在原游戏世界上验收。若已创建专用世界，可以继续使用它；不要把普通原世界当作测试副本。

MC 的开发实例使用 `mc/run`，由 Fabric Loom 自动加载本仓库模组，不要再把同一 jar 复制到它的 mods 目录。先退出正式 MC，再复制自己的独立测试存档：

```powershell
python -X utf8 tools/prepare_test_copy.py --source "$env:APPDATA\.minecraft\saves\DST-MC-Test" --dest "mc/run/saves/DST-MC-Live-Acceptance"
```

源世界名称和目录以自己的启动器实例为准。Windows 使用与 Java FileChannel 重叠的字节区间锁；源世界仍在使用时拒绝复制。复制会移除旧桥接身份，原存档内容和锁文件字节保持不变。

## Steam 入口和启动

```powershell
python -X utf8 tools/launch_bridge.py --save DST-MC-Live-Acceptance
```

该命令只预检并打印 `steam_launch_option`。把打印的完整值放入 **Steam → 饥荒联机版 → 属性 → 通用 → 启动选项**，保留末尾 `%command%`。不要填写 macOS 的 `/usr/bin/arch`，不要复用本机开发目录路径。

Windows 入口继承 Steam 环境，只接受 AppID 322330 和 Steam 安装目录里匹配的 x64 游戏程序。它创建这一轮的游戏子进程，等待系统加载器初始化后载入本仓库的 x64 DLL；不覆盖游戏 DLL，也不向已有或其他进程注入。加载或初始化失败时结束它自己创建的子进程并保存诊断。正常启动后包装器等待游戏退出。

```powershell
python -X utf8 tools/launch_bridge.py --start --save DST-MC-Live-Acceptance
```

Minecraft 资源默认位于 `%APPDATA%/.minecraft/assets`。其他启动器应附加 `--assets "实际资源目录"`。MC 若出现“实验性设置”确认，需要手动继续进入专用世界。饥荒进入刚创建的专用世界。首次验收共同观察时再执行本节启动操作。

游戏进程启动、DLL 加载和成功合成是三个不同阶段：

1. `evidence/steam-launches/windows-*/request.json` / `completion.json` 记录本轮启动与返回码。
2. 同目录 `loaded.json` 只在原生相机服务和 GLES/EGL 钩子就绪后生成；它不能证明相机、遮挡或玩法已正确。
3. `camera-gate.jsonl` 中实际成功合成的唯一帧事件，以及眼前画面/操作共同支持实机判断。缺少所需扩展或矩阵不匹配时会记录拒绝原因，保持普通显示。

原生后端接入游戏随带的 `libGLESv2.dll` / `libEGL.dll`。GLES2 的具体深度能力和当前游戏 shader 需要实机确认；不通过未经验证的启动参数强制更换渲染器。MC 先取得仅用于尺寸对齐的 geometry，再在新鲜成功合成证明成立后透明接管。F8 切换 MC/DST 输入；断线、过期和会话变化恢复普通窗口。

## 共同验收顺序

1. 连续转头/移动，确认没有旧帧、闪烁，手臂和物品栏正常。
2. 树木、生物与方块相互遮挡；透明区域保留正确原生画面。
3. 放置方块 → MC 和 DST 原生角色被挡住 → 拆除 → 恢复通行；覆盖跨区块位置。
4. MC 武器/TNT 对原生生物产生可观察伤害，原生攻击按约定影响 MC；重复回执不重复扣血。
5. 登高、跳跃、断线重连/F8、保存退出后重新进入，检查方块和配对状态。
6. 记录同一会话连续 60 秒的唯一合成帧率和服务器 tick。帧率目标 30 FPS、服务器 19–21 Hz；不能用重复显示同一帧凑数。

```powershell
python -X utf8 tools/record_acceptance.py --seconds 60 --native-log "evidence/steam-launches/本轮目录/camera-gate.jsonl" --out evidence/windows-acceptance-01
```

人工项需要同一 run_id/pair/epoch 的证据，未观察的项目保持 NOT_VERIFIED。出现错误时先提供本轮启动、native gate 和 MC 日志，再定位对应模块；不通过重建原世界或降低安全设置处理。

## 停用与回退

退出两款游戏，在 Steam 清空本项目的启动选项，取消测试世界的服务器模组即可恢复普通启动。DLL 没有替换游戏文件；旧 Lua 模组保存在部署回执所示的 backup。删除/移动仓库前先清空 Steam 对它的路径引用。
