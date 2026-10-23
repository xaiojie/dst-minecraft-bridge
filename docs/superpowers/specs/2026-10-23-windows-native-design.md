# Windows 原生联动开发范围

用户已授权完成编码、提交并推送，Windows 双游戏测试与验收随后共同进行。本文件记录实施选择，不再引入重复审批。

## 目标和职责

Windows x64 上同时运行真正的 Minecraft 1.21.11/Fabric 和 Steam 饥荒联机版。MC 负责第一人称、移动、方块、物品、血量；DST 负责原生世界、生物、寻路及伤害行为。继续使用 protocol v2 的同一帧颜色/深度/姿态以及独立手臂/HUD。

## 路线

保留已有 macOS 实现，增加 Windows 原生适配。参考项目的 D3D11 注入方式不能直接作为饥荒后端：Klei 开发者说明 Windows 使用 ANGLE/OpenGL ES；因此 Windows 适配接入游戏随带的 libGLESv2/libEGL 导出接口，不要求 CrossOver、Wine 或游戏二进制替换。当前安装版本的实际接口、shader 和扩展能力留待 Windows 实测确认；缺失能力时报告具体原因并保持原生显示和输入。

不选择将饥荒地图完整重建到 MC，也不在本轮改为导出所有 MC 网格。保留现有颜色/深度合成和 Lua 世界交换，减少迁移范围。

## 必须完成的编码

- Windows 原生 DLL、EGL present 与 GLES draw 钩子、相机 HTTP/本地邮箱、共享帧映射、画面深度与 HUD 合成、输入/窗口状态。不得用空实现冒充渲染支持。
- Windows Steam 入口：只包装 Steam 提供的命令，保留 Steam 环境；不直接绕过 Steam。加载失败有日志和退出码，不静默宣称成功。
- Steam 安装发现、x64 PE 检查、Java/Gradle/资源目录发现、独立存档复制锁、构建/部署/打包/离线检查入口。
- MC 窗口支持 Windows 高 DPI；仅在新鲜、同一会话的成功合成证明后透明接管。独立窗口几何查询允许先对齐尺寸，解决“未合成不能查询尺寸、尺寸不同又不能合成”的启动循环。
- Windows 文件持久化兼容；地图采样票据按发放时间验证，过期或跨会话不得恢复移动。
- 自动构建检查和 Windows 验收文档，清楚区分编译、离线契约、图形测试和真实双游戏验收。

## 共同约束

单玩家、MC 集成服务器、DST 地面、完整实心立方体；比例 1、固定 X 反射；端口 39379/39380 仅监听回环。保留请求去重、会话/epoch、帧租约及过期拒绝。只使用独立存档，不提交游戏、账号、存档或个人日志。不得修改全局系统安全设置。

## 交付标准

源代码应能够在 Windows x64 构建；Windows 专属代码至少通过交叉编译或真实 Windows CI 编译。Mac 可运行的 Java、C++、Python/Lua 检查必须运行。Windows 图形、键鼠、放置/拆除、双向碰撞、攻击/TNT、保存重进、断线恢复和性能保持 NOT_VERIFIED，直到实机记录证据。

参考： https://kleiforums.com/forums/topic/41689-dont-starve-uses-angle-for-rendering/ （历史引擎说明，当前构建必须实测）；https://github.com/Xu060113/SekiroCraft-Passthrough；https://github.com/chasmlol/SkyCraft。
