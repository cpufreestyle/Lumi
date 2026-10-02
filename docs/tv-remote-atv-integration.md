# 电视遥控：调用开源 ATV Remote 服务的接入说明

> 建立时间：2026-09-25 ｜ 关联模块：`Modules/TV`
> 对应本轮目标：**学习和调用开源项目，增加项目实用性**

## 1. 为什么是「调用」而不是「重写」

Apple TV 的遥控协议是 **MediaRemote / Companion** 私有协议（iOS 自带「遥控器」App 同款），
自己实现要处理：

- Companion 配对凭据的生成与存储（`companion_cred` 是四段式凭据串）；
- MRP（tvOS ≤15）与 Companion（tvOS ≥16）两套协议并存，按广播能力自动选择；
- 局域网 Bonjour 广播发现设备。

这套东西以千行计，且**无法在本机验证**（没有第二台 Apple TV 可回归）。

而 [`~/atv-remote`](../../atv-remote) 已经用 [pyatv](https://github.com/postlund/pyatv) 把上面全部
做成了本机 HTTP 服务（LaunchAgent 常驻 `127.0.0.1:8300`，`bash start.sh` 可手动起）。
Lumi 因此只做「遥控 UI」这一层——协议能力零成本获得，上游更新自动跟上。

> 这是「融合开源项目」的落地方式：**接口朝上复用，不在 Lumi 里复制上游协议实现**。

## 2. 依赖的 HTTP API（读 `~/atv-remote/server.py` 得出）

| 方法 | 路径 | 用途 | 请求体 |
| --- | --- | --- | --- |
| GET | `/api/status` | 连接态 / 当前设备 / 睡眠定时 / 宏运行态 | – |
| GET | `/api/macros` | 预设宏清单（含步骤） | – |
| GET | `/api/atv/apps` | 对端已安装应用 | – |
| GET | `/api/screenshot` | Apple TV 当前画面（ artwork ） | – |
| POST | `/api/cmd` | 所有遥控命令（按当前设备类型分发） | 见下 |
| POST | `/api/atv/scan` | 局域网扫描 Apple TV | `{}` |
| POST | `/api/atv/connect` | 连接已配对设备 | `{"type":"connect","id":"<MAC>"}` |
| POST | `/api/atv/disconnect` | 断开 | `{}` |

### `POST /api/cmd` 的 `type`

| type | 字段 | 说明 |
| --- | --- | --- |
| `key` | `codes: [Int]` | Android `keyevent` 编号；服务端映射到 pyatv 指令 |
| `text` | `text`, `enter?` | 发送文字；`enter=true` 发完补一次 select |
| `tap` | – | 轻点（Apple TV 等价 OK） |
| `swipe` | `x1,y1,x2,y2,duration?` | 归一化坐标 0.0~1.0 |
| `app` | `pkg` | 启动应用（tvOS bundle id 或 Android 包名） |
| `macro` | `action:"run" \| "cancel"`, `name`, `steps` | 跑 / 取消宏 |
| `timer` | `action:"set" \| "cancel"`, `minutes?` | 睡眠定时（1~720 分钟） |

### 键码（与上游 `KEY_MAP_MRP` / `KEY_MAP_COMPANION` 的并集）

19 上 · 20 下 · 21 左 · 22 右 · 23 OK · 4 菜单 · 3 主屏 · 82 控制中心 ·
85 播放/暂停 · 126 播放 · 127 暂停 · 86 停止 · 87 下一个 · 88 上一个 ·
92/93 快退/快进（仅 Companion）· 223 睡眠 · 164 静音（仅 Android）·
24/25 音量加减 · 26 关机 · 224 唤醒

## 3. 三个必须知道的坑

1. **错误在 HTTP 200 的 body 里。** 上游业务失败统一返回 `200 + {"error": "..."}`，
   只有未匹配路由才是 404。所以「失败」不能只看 `error == nil`，必须解析 body 的 `error`
   字段——否则「未连接电视」会被当成成功，界面毫无反应。
2. **`/api/atv/connect` 必须带真 `id`。** 上游 `entry["id"]` 在 id 缺失时直接 KeyError → 500。
   Lumi 的 `TVCommandPayload` 因此有独立的 `id` 字段，不能用别的字段捎带。
3. **纯延时宏步骤不能带 `type`。** 上游靠 `step.get("type") or "delay"` 识别，
   发 `type:"delay"` 会命中「类型不在 `MACRO_STEP_TYPES`」而 400；
   同样，预设宏里 `code`（单数）与 `codes`（复数）两种写法都有，解码时要归一。

## 4. Lumi 侧分层

| 文件 | 职责 |
| --- | --- |
| `Modules/TV/Models/TVRemoteProtocol.swift` | 键码目录、请求体编解码、状态/宏/应用解析、错误提取（**纯逻辑，可单测**） |
| `Modules/TV/Controllers/TVController.swift` | HTTP、`PollingCoordinator` 轮询档位、面板反馈 |
| `Modules/TV/Views/TVExpandedView.swift` | 遥控面板（方向键 / 播放 / 音量 / 文字 / 宏 / 应用 / 定时 / 设备） |
| `Modules/TV/Views/TVBriefView.swift` | 收缩态副标题 |
| `Tests/LumiTests/TVRemoteProtocolTests.swift` | 25 条协议用例，样本抄自服务真实响应 |

遵守的既有约定：周期任务统一走 `PollingCoordinator`（不手写常驻 Timer）；
测试目标只依赖 Foundation（不实例化控制器、不发网络请求）。

## 5. 验证方式

```bash
# 协议层单测（含「Lumi 所有键码必须在上游 KEY_MAP 内」的回归测试）
cd Lumi && swift test

# 对真实服务验证请求体是否被接受
curl -s -X POST -H 'Content-Type: application/json' \
     -d '{"type":"key","codes":[19]}' http://127.0.0.1:8300/api/cmd
# → {"ok": true, "sent": [19]}

curl -s -X POST -H 'Content-Type: application/json' \
     -d '{"type":"key","codes":[999]}' http://127.0.0.1:8300/api/cmd
# → {"error": "Apple TV 不支持键码 999"}   （错误提取路径）
```

面板层需要在真机点开「电视」页确认；本机曾因 ToDesk 全屏 + Lumi 辅助功能权限丢失
导致 hover 不弹岛，**这不是模块问题**，属环境问题（见 HANDOFF §7 的 TCC 说明）。

## 6. 未做 / 后续

- **电视端文字输入的中文输入法**：Android TV 需要 ADBKeyboard（上游已处理），
  Lumi 只负责把文字发过去；上游返回的 `kb_focus` 已在画面上方提示。
- **音量静音**：上游 `KEY_MAP` 里没有 164（仅 Android 支持），因此「静音 / 取消」
  预设宏在 Apple TV 上会单步失败（不中断整条宏）。这是上游现状，未在 Lumi 侧绕过。
- **设备配对**（`/api/atv/pair` 的 begin/finish + PIN）未接入面板：
  首次配对仍需在 ATV Remote 的网页/App 里完成。Lumi 只连接已配对设备。
