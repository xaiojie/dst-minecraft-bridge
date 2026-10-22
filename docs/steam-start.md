# 从 Steam 启动 macOS DST 探针

此包装器是待当前电脑实测的启动候选方案。它必须由 Steam 调用；当前尚未证明 Steam 的 `%command%` 在本机传入 `.app`、探针实际加载或游戏在线。

1. 先复制保存 Steam → Don't Starve Together → 属性 → 通用中现有的「启动选项」。退出已运行的 DST。
2. 在「启动选项」中使用下面这一整行。路径外的双引号和 `%command%` 都要保留。现有游戏参数放在 `%command%` 后；如果原配置包含其他包装器，先人工检查组合方式。

   ```text
   "/Users/jay/Documents/Codex/2026-10-20/https-mp-weixin-qq-com-s/work/dst-mc-bridge/.worktrees/implementation/tools/steam_dst.py" %command%
   ```

3. 由用户点击 Steam「开始游戏」。本任务没有代为修改 Steam 或启动游戏。
4. 恢复时移除新增的带引号包装器路径，恢复原来保存的启动选项；若原来为空，清空本次新增的整行。

包装器只接受包含 `preflight.DEFAULT_EXE` 的规范 DST `.app`。实际启动要求 `SteamAppId` 或 `SteamGameId` 为 `322330`，且所有已提供的标记一致；这是防止误操作的检查，不是身份认证。检查可执行文件、已有进程、探针库、库的 `x86_64` 架构和两项所需 entitlement 后，才会产生证据和调用 `/usr/bin/open`。旧 `preflight.py --launch` 继续拒绝直接启动。

包装器执行形状为 `steam_dst.py [--dry-run] APP [GAME_ARG ...]`。包装器选项放在 APP 前；APP 后的所有参数原样传给游戏，包括空格、单引号和以 `--` 开头的参数。不使用 shell 重建命令。Steam 提供的覆盖层库优先保留，也合并原有 `DYLD_INSERT_LIBRARIES` 并去重，再加入当前探针库。DYLD 变量通过 `open --env` 仅传给目标应用，不放进 `open` 进程环境；不设置全局环境。

可先从终端运行只读检查：

```sh
"/Users/jay/Documents/Codex/2026-10-20/https-mp-weixin-qq-com-s/work/dst-mc-bridge/.worktrees/implementation/tools/steam_dst.py" --dry-run
```

它不会创建文件或启动任何应用。普通终端缺少 Steam 标记时会列出相应阻塞项；这不是启动旁路。`--help` 同样只读。

每次获准的实际请求使用 `evidence/steam-launches/` 下的独立目录。`request.json` 记录 PID、规范应用与可执行文件路径、请求的模块路径和 SHA、输出目录、Steam 应用标记、`open` 参数及时间；`preflight.json` 为捕获工具保留预检结果；`completion.json` 记录 `open` 返回码。`open` 返回成功不表示探针加载或在线。实际加载仍要查看同目录由原生模块生成的 `loaded.json`、`heartbeat.json` 和实时回调，再完成独立图形验收。

本方案依据 [sgentle 的 2026 年 macOS Steam 启动记录](https://gist.github.com/sgentle/8cace35bfad585a2866a9e825a5203af)，其中 `.app` 替换行为是待本机验证的经验信息。包装器不创建 `steam_appid.txt`，不修改游戏包、签名或 Info.plist，不重启 Steam，不重建原生模块。
