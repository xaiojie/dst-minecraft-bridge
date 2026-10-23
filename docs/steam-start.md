# 从 Steam 启动 macOS DST 探针

此包装器必须由 Steam 调用。下方路径对应本轮工作树；迁移目录后以 `tools/launch_bridge.py` 打印的路径为准。已在本机 Steam 日志中确认 `%command%` 正确传入 DST `.app`；原来的直接脚本入口因 Intel 模式下的系统 Python 启动失败而退出。下面的 ARM 启动前缀已通过本机实测：用户由 Steam 进入原测试世界，x86_64 探针加载且持续产生绘制回调。两款游戏的合成、输入和遮挡验收仍未完成，部分后台 Klei 服务仍有 SSL 错误。

1. 先复制保存 Steam → Don't Starve Together → 属性 → 通用中现有的「启动选项」。退出已运行的 DST。
2. 在「启动选项」中使用下面这一整行。路径外的双引号和 `%command%` 都要保留。现有游戏参数放在 `%command%` 后；如果原配置包含其他包装器，先人工检查组合方式。

   ```text
   /usr/bin/arch -arm64 /usr/bin/python3 -B "/Volumes/OS/Work/个人开发/饥荒融合MC/implementation/tools/steam_dst.py" %command%
   ```

3. 点击 Steam「开始游戏」，进入原测试世界。
4. 恢复时移除本项目添加的整段启动前缀和包装器配置，恢复原来保存的启动选项；若原来为空，清空本次新增的整行。

包装器读取 Steam 的 `libraryfolders.vdf` 和 `appmanifest_322330.acf`，只接受当前登记安装的 DST `.app`；支持迁移到外置 Steam 库，不会选用未登记的旧副本。安装缺失、登记冲突或元数据异常时拒绝启动。实际启动要求 `SteamAppId` 或 `SteamGameId` 为 `322330`，且所有已提供的标记一致；这是防止误操作的检查，不是身份认证。检查可执行文件、已有进程、探针库、库的 `x86_64` 架构和两项所需 entitlement 后，才会产生证据和调用 `/usr/bin/open`。旧 `preflight.py --launch` 继续拒绝直接启动。

包装器执行形状为 `steam_dst.py [--dry-run] APP [GAME_ARG ...]`。包装器选项放在 APP 前；APP 后的所有参数原样传给游戏，包括空格、单引号和以 `--` 开头的参数。不使用 shell 重建命令。Steam 提供的覆盖层库优先保留，也合并原有 `DYLD_INSERT_LIBRARIES` 并去重，再加入当前探针库。DYLD 变量通过 `open --env` 仅传给目标应用，不放进 `open` 进程环境；不设置全局环境。

Steam 以 Intel 兼容模式运行时，会把直接调用的系统 Python 也按 Intel 模式启动。本机 Command Line Tools 的 libxcrun 只有 ARM 架构，因此必须用 `/usr/bin/arch -arm64 /usr/bin/python3 -B` 显式运行包装器。这个前缀只控制 Python 入口，游戏和 x86_64 探针仍保持原架构。不能只填写脚本路径。

可先从终端运行只读检查：

```sh
/usr/bin/arch -arm64 /usr/bin/python3 -B "/Volumes/OS/Work/个人开发/饥荒融合MC/implementation/tools/steam_dst.py" --dry-run
```

它不会创建文件或启动任何应用。普通终端缺少 Steam 标记时会列出相应阻塞项；这不是启动旁路。`--help` 同样只读。

每次获准的实际请求使用 `evidence/steam-launches/` 下的独立目录。`request.json` 记录 PID、规范应用与可执行文件路径、请求的模块路径和 SHA、输出目录、Steam 应用标记、`open` 参数及时间；`preflight.json` 为捕获工具保留预检结果；`completion.json` 记录 `open` 返回码。`open` 返回成功不表示探针加载或在线。实际加载仍要查看同目录由原生模块生成的 `loaded.json`、`heartbeat.json` 和实时回调，再完成独立图形验收。

本方案依据 [sgentle 的 2026 年 macOS Steam 启动记录](https://gist.github.com/sgentle/8cace35bfad585a2866a9e825a5203af)，其中 `.app` 替换行为已由本机 Steam 启动日志确认；加上 ARM Python 前缀后的 Steam 重启及探针加载已在本机实测；双游戏合成与完整验收仍待完成。包装器不创建 `steam_appid.txt`，不修改游戏包、签名或 Info.plist，不重启 Steam，不重建原生模块。
