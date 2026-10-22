# Task 4 实机联调报告（第一人称合成首个可复现实例）

日期：2026-10-23 Asia/Shanghai。工作目录：`/Volumes/OS/Work/个人开发/dst-minecraft-bridge-3`（接手提交 `a0de3bc`，main）。
状态：**任务 4 仍在进行中**。camera / same_frame / ui 三项已实机观察，transparency、depth_occlusion 未做像素级验收；透明输入窗口与 60 秒性能未验证。禁止进入任务 5。

## 1. 起点与复核

- 独立复核坐标轴 WIP（`aae1cc6`）：`WorldTransform` 的 `S=diag(-1,1,1)` 正反变换、方向变换、`V_DST=V_MC·[S,t]` 推导正确；DSP3/DMB3 与 `TRANSFORM_MISMATCH` 拒绝路径、帧内轴不可变、status 轴/原点、native 严格校验均成立。未发现新的数学缺陷。
- 记录三项非阻塞观察：`PairingStore` 无生产调用者；损坏 mode 名抛 `IllegalArgumentException`；旧 DMB2 identity 绑定无迁移。
- 离线验证：Java 28 条断言、native 全部测试、跨架构 `frame_contract_test`、Python 21 项（历史 18 + 新增 3）、`NativeHttpTests` 首次实跑，全部通过。

## 2. 两个握手契约问题（已修）

| 问题 | 原值（Lua） | Java 接受值 | 处理 |
|---|---|---|---|
| region | `first-person-test` | `ground` | Lua 改为常量 `REGION="ground"` |
| MC 原点 | `(0.5,64,0.5)` | `(0,64,0)` | Lua 改为常量 `MC_ORIGIN={0,64,0}` |

先加测试 `tests/test_handshake_contract.py`：lupa 真跑 `connection.lua` 截获真实 POST body → 从 `WorldExchange.java` 源码提取接受常量 → javac 编译真实网关喂 payload → 断言接受 + 两个负向对照（旧 region、半格原点仍 `WORLD_MISMATCH`）。RED 证据 `'first-person-test' != 'ground'`、`reason=WORLD_MISMATCH mc_origin=Vec3[0.5,64.0,0.5]`，修复后 3/3 GREEN。

## 3. 实机联调发现的四个真实缺陷与修复

1. **租约要求“请求帧号 = 最新帧”**。MC 实测 29.3fps（34.1ms/帧），客户端一轮 `status→lease→apply→ack` 约 640ms，请求必然过期（`exact frame changed; retry`）。改为：接受同会话中仍可读的精确帧；若三槽已覆盖，回退钉住最新帧并**以该帧 key 回答**，客户端（`sessionkey()`）以返回 key 为准。
2. **合成等 ack 造成空档**。`compose()` 原用 `ready()`（要求 acked），每次新租约到 ack 之间整段画面退回宿主。新增 `CameraService::pinned()`（只要求已租、已钉、key 一致），合成用它；ack 只用于 `/v2/window` 证明。`present()` 不再 `release()`，同一帧可持续参与后续绘制。
3. **drawable 尺寸必须精确等于流尺寸**。DST 窗口 960×540 drawable、MC 流 960×540 时通过，但 1470×895、882×635 时全部 `SKIPPED_MISMATCH`。`matching_camera()` 改为**同宽高比**（0.1% 容差），归一化采样与 NDC 反投影本身与像素尺寸无关；实测 960×540 与 480×270 两种流都能合成。
4. **合成写在中途被后续 pass 覆盖**。原 `before_draw` 在场景绘制中合成，DST 随后把地面/精灵/光照画上去，只剩 `present()` 里单独画的 HUD。现在合成移到 `present()`、`flushBuffer` 之前，直接写窗口 drawable（FBO 0），HUD 最后叠加。这一改动是“从闪黑到稳定画面”的关键。

顺带修复：native HTTP 只认 `Content-Length`（Java 认 chunked / `Expect: 100-continue`）——已补齐并新增 `native/tests/http_framing_test.mm`；DST 侧 `M.Release()` 在流为空/epoch 变化时永久停用桥——改为 `reset_session()` 重连，并加 Lua 回归测试；`native/Makefile` 隔离构建路径 bug。

## 4. 实机证据

- 配对：`dst_world=b02d4f86-9be4-44cb-9034-7e68754951a4`，`mc_world=7ffd8ed7-caf1-407b-ad77-92caebabcc27`，`dst_mc_bridge:stage`/`ground`，`axes=diag(-1,1,1)`，`dst_origin≈(-181.087,0,459.404)`，`mc_origin=(0,64,0)`。
- 首个合成：`compose key=4082 status=0 "matched complete frame"`；稳定阶段 **60/60 COMPOSITED**；流尺寸切到 480×270 后 **30/30 COMPOSITED**。
- 截图与摘要：`handoff/observations/task4-live/first-composite-74.png`、`first-composite.json`（DST 窗口内：石头地、带玻璃窗石墙、橡树、近处方块、MC 准星、DST HUD 完整）。
- gate 原始日志：`evidence/steam-launches/*/camera-gate.jsonl`（含 `t` 毫秒时间戳、lease 快照、ack 结果）。

## 5. 现场事故与处理

- 初次布置的 stage 平台只有 17×17，用户走动时掉进虚空死亡（`DSTBridgeTest掉出了这个世界`），在主世界重生 → 不再位于 `stage` 维度 → 帧流停止、桥接自然“消失”。
- 处理：地板扩到 97×97、四周 ±32 围墙、`spawnpoint` 设在 stage、用 `execute in dst_mc_bridge:stage run tp` 传送回场景。
- 遗留：`BridgeServer.tick` 每轮启动会在 y=63 铺 invisible barrier（中心 33×33），会覆盖手铺的石头地板，需要下轮启动后补铺或改初始化逻辑。

## 6. 五 gate 现状（诚实版）

| gate | 状态 | 依据 / 缺口 |
|---|---|---|
| camera | OBSERVED | 合成画面使用租约位姿，DST 相机跟随；仍需“走动/转视角时画面跟手”的连续证据 |
| same_frame | OBSERVED | compose 用精确 FrameKey 且矩阵匹配；`/v2/window` 证明尚未在同一时刻采样记录 |
| transparency | NOT_VERIFIED | 场景里有玻璃窗，但未做像素级透明采样 |
| depth_occlusion | NOT_VERIFIED | 有石墙/近方块/树，但未验证相互遮挡与 DST 生物前后关系 |
| ui | OBSERVED | DST HUD 正常叠加；MC HUD 与 DST HUD 底部区域重叠，期望未定义 |
| 透明窗口键鼠 / 放块 | NOT_VERIFIED | 未实现/未验证 |
| 60 秒融合性能 | NOT_VERIFIED | 未测 |

## 7. 未做与下一步

- 不宣称任务 4 通过；不放行任务 5。
- 下一步：重启 MC 客户端并补铺地板 → 按验收格式采集 camera/same_frame/transparency/depth_occlusion/ui 证据 → 透明窗口键鼠与放块 → 60 秒性能 → 任务 5。
