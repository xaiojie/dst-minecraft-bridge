# 当前交接：Windows 原生编码与待实机验收

用户在 2026-10-23 确认：先完成 Windows 迁移编码、检查、提交推送，之后共同在 Windows 上测试验收。不要重新开始设计审批，不要把离线检查、DLL 加载或配对成功写成真实融合验收通过。

当前开发分支 `codex/complete-fusion`，仓库 `https://github.com/xaiojie/dst-minecraft-bridge.git`。Mac 工作树 `/Volumes/OS/Work/个人开发/饥荒融合MC/implementation`；Windows 克隆后的真实路径应重新发现。原有 main 和原始存档不需要重建。

## 已有实现

- `mc/`：真正的 MC 第一人称、运动、方块、物品/血量；独立 stage 世界；地形/生物代理；TNT、双向伤害回执；保存重进与恢复。全部是实际调用链，旧 handoff “任务5–8未开始”已过期。
- `dst-mod/`：原生世界/生物采样、相机、方块碰撞/寻路墙、战斗去重。Windows 邮箱接受盘符绝对路径，处理 Lua rename 不能覆盖目标的差异。
- `native/windows/`：x64 ANGLE/GLES2/EGL 钩子、相机 HTTP/邮箱、共享帧映射、同帧矩阵/深度/颜色校验、离屏世界目标及 resolve/blit、独立手臂/HUD、F8 输入与窗口几何、初始化与唯一帧遥测。
- `native/src/`：保留 Mac 适配；公共 `frame_protocol.h` 与 `CameraService` 被 Windows 复用，新增 MSVC 原子操作兼容，ABI 仍为 v2。
- `PassthroughWindow`：Windows/Mac 分支；几何查询先对齐窗口，成功合成的新鲜同会话证明才激活透明显示；恢复/切换不把几何响应当作合成成功。
- `AtomicFiles`：原子替换前强制文件数据，Windows 不再尝试把目录当 Java FileChannel 打开；POSIX 保留目录 fsync。
- `tools/`：Java/Steam/PE/资源发现、Steam 命令包装与只向自身新建子进程载入 DLL、独立存档锁、可回滚 DST 模组安装、构建检查、平台开发包和验收记录。

## 下一步

按 [Windows 开发与验收](windows-start.md) 在实体 x64 Windows 电脑克隆、构建，准备独立 MC 和 DST 测试世界。DST 必须通过 Steam 启动；清楚区分 request/completion、loaded.json、成功合成唯一帧和真实玩法。使用新的本机路径设置 Steam 入口。

验收顺序：连续转头 → 手臂/HUD/树木生物遮挡 → 放置—双向阻挡—拆除—恢复通行 → 攻击/TNT/双向受击 → 登高/重进存档/断线/F8 → 同一会话 60 秒性能。真实 Windows 项目在观察前均为 NOT_VERIFIED。

Windows 图形能力要求是 GLES2，需 depth texture、float texture 和 fragment depth 扩展；不支持或矩阵/纹理目标不匹配会明确拒绝激活。GLES3 需要额外 VAO/PBO/indexed 状态支持，当前主动拒绝。实际 Windows 饥荒构建、shader 保留方式、透明精灵和输入行为必须实测。不要移除失败关闭检查来“修复”黑屏或没有融合画面。

本版范围仍是单玩家、MC 集成服务器、DST 地面、完整实心立方体、比例1/固定X反射。楼梯、流体、红石、洞穴、多玩家不在本轮联动范围；生物/静态障碍高度是显式近似。未确认伤害在崩溃/重新配对后丢弃，避免跨会话重放；不能承诺断电时严格恰好一次。

Mac 历史实测曾确认独立测试世界配对和第一人称相机，但合成/地形代理仍有待定位项；不能替代 Windows 验收。Steam 配置、安装位置与存档属于实时状态，继续测试前重新核对。移动/删除目录之前先清除 Steam 对旧目录的启动引用。
