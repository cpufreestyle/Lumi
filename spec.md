# Lumi 项目契约（spec）

本文件是项目的行为契约与外部依赖契约的单一事实源。改动涉及契约时必须同步更新本文件；
验证执行方式见 `harness.md`。两份文档一起维护，引用一律写相对路径。

## 版本与运行时

- 产品名：Lumi（macOS 动态岛 + Node 后端服务）
- Swift 目标：macOS 14+；测试 target：LumiTests（依赖完整 Lumi target，含 AppKit/SwiftUI）
- 构建约束：必须指定 `--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` 且
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`（macOS 27 SDK 下 SwiftUIMacros 解析失败，逐次验证过）
- CI 门禁：`.github/workflows/ci.yml` = Swift 全量（`swift-macos`，`runs-on: macos-26`）+ 根
  `npm test`（`node-server`）+ `windows` 端 `tsc`/`vite` 编译（`windows-app`，跳过 Electron 二进制
  下载、不打包 NSIS）。SDK 绝对路径由 `scripts/ci/resolve-sdk.sh` 解析——本机与 runner 的 26.5
  SDK 位置不同，找不到任何 26.x SDK 时脚本以退出码 1 终止，不静默回退到 27 SDK。
  CI 只覆盖编译与单测，实机行为自检仍是发布前置条件（执行方式见 `harness.md`）。
- 后端：`node server.js`，默认 PORT=3000，可由 `.env` 覆盖

## 行为契约（硬性约定）

以下行为受测试守护，任何修改需同步更新对应测试并更新本节：

1. **标签栏恒为两行**：由 `Core/TabBarLayout.swift` 的纯函数决定，改回 `adaptive` 会破坏两行不变式。
2. **桌面歌词双语间距**：用户自定义行高只影响双语（译文行存在时）窗口高度，单行不应虚高。
3. **英文字号不低于中文**：`DesktopLyricsLayout.bilingualSizes` 的既有约定。
4. **多屏镜像**：主面板所在屏之外的其他屏建立镜像；拔屏即收、插屏即建。
5. **授权守卫**：已授权（calendar `.fullAccess`、通知 authorized/provisional/ephemeral、麦克风 authorized）
   不得再触发系统授权请求；只有 notDetermined 才允许请求。
   见 `CalendarController.shouldRequestEventAccess(status:)` 与对应测试。
6. **全局快捷键 ⌘⌥P（默认关闭）**：只在用户从菜单栏开启后注册监听；按 keyCode 匹配、
   修饰键只比较 ⌘⌥⇧⌃，忽略 CapsLock 等噪声位；触发后不弹胶囊。
7. **快捷键目录单一数据源**：胶囊右键菜单与「快捷键与手势说明」面板共用
   `KeyboardShortcutCatalog`，文案禁止两处各写一份。
8. **歌词分享卡片**（复刻 Musixmatch / Apple Music 付费功能，PremiumFeature `lyricsShare`）：
   - 仅 Premium 解锁后显示分享按钮；未解锁/原文为空一律禁用；
   - 文本截断上限 `LyricsShareCard.maxLineLength`（60 字符），超出加省略号；
   - 文件名非法字符（/\:?%*|"<>）替换为下划线，空标题兜底为 `Lumi-Lyrics`；
   - 渲染失败（ImageRenderer 不可用）返回 nil，调用方禁用按钮；
   - 分享用 NSSharingServicePicker（macOS 13+ 推荐路径），不用已 deprecated 的 `sharingServices(forItems:)`。
   见 `Modules/Music/Models/LyricsShareCard.swift` 与 `Modules/Music/Views/LyricsShareCardView.swift`。
9. **逐行歌词语法注解**（复刻 Musixmatch 语言学习付费档，PremiumFeature `lyricsGrammar`）：
   - 仅 Premium 解锁后显示语法注解按钮；未解锁一律不显示；
   - 原文为空（未播放 / 纯音乐）时点击无反应；
   - 请求 prompt 要求 AI 只输出 JSON 数组（point/keyPhrase/example），解析容忍 Markdown 代码块包裹、
     单对象而非数组、keyPhrase/example 缺失、point 为空白；
   - 解析失败时行内给错误提示，不阻塞歌词主流程；
   - 复用 AIAssist 的 HTTP 链路（Keychain API Key，用户自配端点）。
   见 `Modules/Music/Models/LyricsGrammarNote.swift` 与 AIAction 的 `grammar` 预设。
10. **支付宝购买链路（后端已实现，休眠中）**：
    - 默认无凭证时走内置 `/pay/sandbox/...` 模拟网关；配置 `ALIPAY_APP_ID` /
      `ALIPAY_PRIVATE_KEY` 后同一 API 跳真实 page.pay；
    - 回调必须通过 RSA2 验签或受 `LUMI_ALIPAY_SANDBOX_TOKEN` 保护的模拟回调；
      金额、订单、设备绑定在发码前校验；只允许 `TRADE_SUCCESS`；
    - 发码复用 `license-tool redeem --lifetime`，产出绑定设备的 `LUMI2-` 永久码；
      未支付 / 非本设备查询不返回激活码；
    - 客户端暂不接入：前端无购买入口，不发请求、不轮询；链路仅以后端端点存在，
      待真实商户资质与公网回调地址就绪后再打开。
    见 `server.js` 与 `test/server.test.js`。

## 外部依赖契约

- Apple Music：AppleScript `tell application "Music"`；Music 未运行时 AppleScript 会拉起（已知限制）
- lrclib：同步歌词来源，详见 `docs/music-lyrics-troubleshooting.md`
- whisper.cpp：语音听写模型 `ggml-base.bin`，见 `docs/whisper-dictation-integration.md`
- MusicKit JWT 凭据：`.env`（不入版本库），见 `POST /api/setup`
- license 私钥：`Lumi/secrets/license_private_key.b64` 本地文件，不入版本库

## 后端端点契约（由 `test/server.test.js` 守护）

| 端点 | 语义 |
|---|---|
| `GET /api/token` | 签发 MusicKit 开发者 JWT |
| `GET /api/config-status` | 凭据状态（脱敏） |
| `POST /api/setup` | 写入 MusicKit 凭据（校验 PEM） |
| `POST /api/redeem` | 激活码换发 |
| `GET /api/revocations` | 吊销清单 |
| `POST /api/alipay/order` | 创建支付宝订单并返回支付页 URL |
| `POST /api/alipay/notify` | 支付宝异步回调；验签/模拟 token 后签发激活码 |
| `GET /api/alipay/query` | 按订单号 + 设备轮询支付与发码状态 |

> 支付宝三个端点当前为「后端保留、客户端休眠」状态：App 无购买 UI，链路仅可经 curl /
> 测试驱动；上线需补商户资质、公网 HTTPS notify 与订单持久化（见 HANDOFF 待办）。

新增端点必须：1）在 `server.js` 实现；2）在 `test/server.test.js` 加测试；3）在本表登记，缺一不可。

## 测试命令

- Swift：`cd Lumi && swift test --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`
- Node：仓库根 `npm test`

两套都绿才能视为契约保持。当前基线：Swift 621 passed / 0 failed；Node 51 pass / 0 fail。
