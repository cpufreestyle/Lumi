# Lumi

> **当前版本：v1.1.8**（与 GitHub Release 保持一致）

macOS 顶部「动态岛」聚合面板。常驻屏幕顶部状态栏上方，鼠标悬停热区时显示，移开自动隐藏。把音乐歌词、电池状态、视频下载、Claude Code / Codex 集成收进一个轻量胶囊界面。

## 功能模块

| 模块 | 说明 |
| --- | --- |
| 检测 | 电量与充放电状态实时显示 |
| 音乐 | 当前曲目 + 滚动歌词（流媒体无内嵌歌词时回退在线歌词） |
| 视频下载 | 基于 yt-dlp，支持 1800+ 站点 |
| Claude Code | 本地 Claude Code CLI 集成入口 |
| Codex | 本地 Codex CLI 集成入口 |
| 许可证 | 付费模块解锁管理 |
| 插件 | 第三方 macOS 应用可接入灵动岛（实验性，见下） |

## 插件市场（实验性 · Phase 0）

Lumi 支持把**任意第三方 macOS 应用**接入灵动岛面板，形成可扩展的插件生态：

- 第三方 app 只需在 `Contents/Resources/lumi-plugin.json` 声明清单（id / 名称 / 图标 / 唤起 scheme / 权限），Lumi 启动时会自动扫描 `/Applications`、`~/Applications` 与 `~/Library/Application Support/Lumi/Plugins/` 并挂载。
- 点击插件即按 URL Scheme（如 `bartender://`）或 `open .app` 唤起该 app，**第三方 app 在自己进程运行，权限各自申请**，Lumi 宿主本体不共享敏感权限，side effect 面更小。
- 清单格式见 `Sources/Lumi/Core/Plugin/PluginManifest.swift`；扫描逻辑见 `PluginDiscovery.swift`。

快速体验：运行仓库内 `make_sample_plugin.sh` 会在 Plugins 目录生成一个示例插件 `.app`，重启 Lumi 后展开面板底部「插件」区即可看到。

**第三方开发者接入指南**：见 [`docs/PLUGIN_SDK.md`](docs/PLUGIN_SDK.md)（L1/L2/L3 三层级、清单字段、面板 JSON、上架市场、30 秒零编译演示）。

## 插件市场（已落地 · Phase 1）

展开面板底部「插件」区提供两个分段：

- **已安装**：本地发现的第三方 app，点击即唤起（URL Scheme / open .app）。
- **市场**：从官方源（仓库 `Lumi/plugin-feed.json`，远程失败回退内置副本）拉取可安装插件，支持**一键安装 / 卸载**，带下载进度。

### 让第三方 app 接入（两种方式）

1. **本地发现（L2）**：第三方 app 在 `Contents/Resources/lumi-plugin.json` 声明清单：

   ```json
   {
     "id": "com.example.myapp",
     "name": "我的应用",
     "iconName": "star",
     "urlScheme": "myapp",
     "panelHint": "一句话描述",
     "permissions": [{ "type": "network", "reason": "需要联网" }]
   }
   ```

   放入 `/Applications` 或 `~/Library/Application Support/Lumi/Plugins/` 即可被自动发现。
2. **上架市场**：维护者在 `plugin-feed.json` 增加条目（含 `downloadURL` 指向 `.app.zip`），
   把 zip 上传到 Release。用户点「安装」即下载 → 解压 → 去隔离 → 放入 Plugins → 重新扫描。

### 安全闸门（当前实现）

- 安装前在「市场」列表展示插件声明的 `permissions`（橙色徽标 + 悬浮说明），透明告知。
- 每个插件独立进程、独立权限，Lumi 宿主本体不共享敏感权限。
- 官方源为可信 JSON（v1.2 计划加签名校验）；社区源接口预留，默认关闭。

### L3 深度集成：插件内嵌面板（Phase 2 · 已落地）

除了被「唤起」（L1/L2），带 `panel: true` 的插件还能把**结构化内容内嵌**到 Lumi 展开面板，
像一个原生模块一样出现在标签栏，点击即显示其面板（文本/键值/进度/按钮）。

实现采用**零签名阻力**的共享目录桥接（不依赖 XPC / App Group，任何第三方 app 只要能写文件即可）：

1. 插件在 `lumi-plugin.json` 声明 `"panel": true`。
2. 插件周期性把面板数据写到
   `~/Library/Application Support/Lumi/PluginPanels/<pluginID>.json`：

   ```json
   {
     "id": "com.example.myapp",
     "title": "我的插件",
     "iconName": "star",
     "subtitle": "实时状态",
     "lines": [
       { "kv": { "key": "状态", "value": "运行中" } },
       { "progress": 0.42 },
       { "button": { "title": "执行" } }
     ],
     "updatedAt": 1700000000
   }
   ```

   `lines` 支持 `text` / `kv` / `progress`(0~1) / `button` 四种行。Lumi 每 1 秒轮询，
   超过 30 秒未更新会提示「插件可能已退出」。面板内按钮点击会向插件声明的
   URL Scheme 发 `myapp://action?name=<按钮标题>`，由插件自行处理。

3. Lumi 扫描到带 `panel: true` 的插件后，自动在标签栏追加其标签，无需额外配置。

> 说明：XPC 双向通信（v2 计划）能提供更低延迟与双向调用，但需要签名授权文件、
> 对 ad-hoc/免费账号不友好；当前文件桥接方案在「能被任意第三方接入」与「实现成本」
> 之间取得平衡。如后续需要，可平滑升级到 XPC。

### 示例插件打包

```bash
./make_sample_plugin.sh            # 生成示例插件 + L3 示例面板数据
./make_sample_plugin.sh --zip      # 生成并打包 LumiSamplePlugin.app.zip
./make_sample_plugin.sh --clean    # 清理示例插件
```

运行 `./make_sample_plugin.sh` 后，重启 Lumi，展开面板标签栏会出现「示例插件（天气）」标签，
点击即可看到内嵌的天气卡片（含进度条与「刷新天气」按钮，按钮通过 `lumi-sample://` 回传插件）。

## 安装

### 方式一：下载 Release（推荐）

1. 到 [Releases](https://github.com/cpufreestyle/Lumi/releases) 下载 `Lumi-vX.X.X-macos.zip`
2. 解压得到 `Lumi.app`，拖入「应用程序」
3. 首次打开若提示「无法打开」，在终端执行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/Lumi.app
   ```

   或在「访达」中右键 → 打开。

### 方式二：从源码构建

要求：macOS 14+，已安装 Xcode（含命令行工具），且 `DEVELOPER_DIR` 指向 Xcode。

#### 免费账号本地运行（推荐，无需付费开发者）

用你登录在 Xcode 里的**普通免费 Apple ID** 即可在本地签名运行，无需加入付费的 Apple Developer Program（¥688/年）。

1. 在 **Xcode ▸ Settings ▸ Accounts** 添加你的普通 Apple ID（免费即可）。
2. 任意打开/新建一个项目，在 Signing & Capabilities 勾选该账号，让 Xcode 自动生成「Apple Development」证书。
3. 回到 Lumi 目录直接运行：

   ```bash
   git clone https://github.com/cpufreestyle/Lumi.git
   cd Lumi
   bash Lumi/sign_and_run.sh        # 编译 + 免费账号签名 + 启动
   ```

   首次启动会弹出「Lumi 想控制『音乐』」等授权框，点击「好/允许」即可。若弹窗缺失，可在 **系统设置 ▸ 隐私与安全性 ▸ 自动化** 中手动勾选 Lumi。

常用命令：

```bash
cd Lumi
bash Lumi/sign_and_run.sh identities   # 查看本机可用的免费签名身份
bash Lumi/sign_and_run.sh run          # 仅重新签名并启动（证书过期重签时用）
bash Lumi/restart_lumi.sh              # 退出旧实例 → 重签名 → 启动
bash Lumi/sign_and_run.sh --adhoc      # 退回 ad-hoc 自签名（不依赖账号，但会改 TCC 数据库）
```

> 免费开发证书签名的 app 可长期在本机运行；若某天提示「已损坏/无法验证」，直接 `bash Lumi/restart_lumi.sh` 会自动检测并重签。

#### 其他方式

- `bash Lumi/run.sh restart`：构建并启动（ad-hoc 签名 + 写入用户级 TCC 授权库）。
- 手动构建：

  ```bash
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  cd Lumi
  swift build
  open .build/Lumi.app
  ```

## 使用

- **动态岛**：应用启动后，胶囊常驻屏幕顶部。把鼠标移到屏幕最顶部热区即可显示面板，移开鼠标自动隐藏。
- **隐藏整个界面**：展开面板后，点右上角「眼睛带斜杠」图标可隐藏；隐藏后再次把鼠标移到屏幕顶部热区，入口会重新出现。
- **切换模块**：展开面板顶部标签栏点击各模块图标。
- **拖动**：在展开面板内可拖动调整位置。

## 各模块说明

### 检测

显示当前电量百分比与充放电状态，无需额外配置。

### 音乐

连接系统的 **音乐（Music.app）**，显示当前播放曲目与**带时间轴的逐行高亮歌词**。

- 歌词来源优先级：Music.app 内嵌歌词 → [lrclib.net](https://lrclib.net) 的 `syncedLyrics`（社区从 Apple Music 扒取的逐行时间轴歌词）→ `plainLyrics` 纯文本兜底。
- 有同步歌词时，面板会按播放进度**逐行高亮并自动滚动**到当前句；无时间轴时退化为普通滚动文本。
- 需授权：系统设置 → 隐私与安全性 → **媒体与 Apple Music**，允许 Lumi 访问（首次启动会弹窗请求）。

> 说明：macOS 的 MusicKit 仅提供「媒体与 Apple Music」授权与目录匹配，并不暴露逐行歌词数据，因此 Apple Music 风格的逐行时间轴歌词取自 lrclib 的同步歌词库。

### 视频下载

基于 [yt-dlp](https://github.com/yt-dlp/yt-dlp)。首次使用前需安装：

```bash
brew install yt-dlp
```

粘贴视频链接即可下载，支持 YouTube、B 站等 1800+ 站点。

### Claude Code / Codex 集成

需要本机已安装对应的 CLI（`claude` / `codex`），模块内启动本地会话。

### 许可证

部分模块为付费功能。在「许可证」面板输入密钥解锁对应功能。

激活码格式：

- `LUMI1-<payload>-<签名>`：标准激活码（Ed25519 验签，公钥内置于 App，私钥仅留服务端工具，无法本地伪造）。
- `LUMI2-<payload>-<签名>`：绑定设备的激活码，payload 内含本机设备 ID，换机/重装后自动失效，需重新换发。
- 旧版 `LUMI-XXXX-XXXX-XXXX-XXXX`（CRC16）已废弃，输入会提示联系 <support@lumi.app> 换发。

**旧码自助换发**：在「许可证」面板点「我有旧版激活码？免费换发新码」，填写旧码与订单号，后端校验后签发绑定本机的新 `LUMI2-` 码并自动激活。本地开发可在 `server.js` 起一个后端：

```bash
# 起后端（默认 3000 端口，读 Lumi/secrets 内私钥，包装 license-tool）
PORT=3000 node server.js
# App 端在换发表单「后端地址」填 <http://localhost:3000/api/redeem>
# 设备上限（同订单最多绑定设备数，默认 2）
LUMI_DEVICE_LIMIT=2 node server.js
# 订单白名单（逗号分隔；未设置则放行，仅用于本地测试）
LUMI_VALID_ORDERS=ORD-XXXX node server.js
```

换发服务端约束（`license-tool redeem` 落地，状态持久化于 `Lumi/secrets/redeem_state.json`）：

- **旧码一次性**：同一旧码只能换发一次，再次请求直接拒绝。
- **防重放**：客户端每次请求携带唯一 `nonce`，重复 `nonce` 直接拒绝。
- **设备上限**：同一订单已绑定设备数达 `LUMI_DEVICE_LIMIT` 时拒绝换发更多设备。
- **订单白名单**：`LUMI_VALID_ORDERS` 未命中直接拒绝（生产必须配置）。

签发/校验工具：`cd Lumi && swift run license-tool gen --lifetime`（签发）、`redeem`（旧码换发）、`verify <码>`（用 App 内嵌公钥验签）、`revoke-list`（签发吊销清单）。

**可观测**：许可证面板底部「本地诊断数据」折叠展示本机埋点（仅存 UserDefaults，不上报）：激活次数与设备绑定占比、换码尝试/成功/失败及失败原因分布。

**吊销**：服务端用私钥对吊销清单（被吊销激活码的唯一标识 `nonce` 集合）签名，客户端联网时拉取 `GET /api/revocations` 并验签，命中本机即失效；离线期间沿用上一次缓存（存在最多到下次联网的吊销延迟，属已知取舍）。签发清单：

```bash
swift run license-tool revoke-list --nonces <N1>,<N2>
# 结果写入 Lumi/secrets/revocations.lumi，由 server.js 直接提供（server.js 不持有私钥）
```

**到期提醒**：授权剩余不足 7 天时状态转为橙色并提示续费；面板内「重新检查」按钮可手动刷新授权与吊销状态。

## 常见问题

- **歌词不显示**：确认 Music.app 正在播放且已授予「媒体与 Apple Music」权限；部分曲目的在线歌词库无数据属正常情况。
- **界面不出现**：把鼠标移动到屏幕最顶部（状态栏上方）热区。
- **下载失败**：确认已执行 `brew install yt-dlp`，且链接所属站点受支持。
- **签名/证书问题**：用免费账号运行 `bash Lumi/sign_and_run.sh` 时若提示「no identity found」，请在 Xcode ▸ Settings ▸ Accounts 先登录免费 Apple ID 并触发一次证书生成；若提示 app「已损坏/无法验证」，多半是免费开发证书过期，执行 `bash Lumi/restart_lumi.sh` 会自动检测并重签，或手动到 Xcode ▸ Accounts ▸ Manage Certificates 重置「Apple Development」证书。

## 开发

- 源码位于 `Lumi/Sources/Lumi/`，按 `Core`（状态/许可证）、`Modules`（各功能模块）、`Views`（界面）组织。
- 构建与运行：
  - `Lumi/sign_and_run.sh`（**免费账号自签名**，推荐日常本地使用）：用 Xcode 登录的免费 Apple ID 开发证书签名并启动，证书过期会自动重签；支持 `build`/`run`/`identities`/`--adhoc` 子命令。
  - `Lumi/run.sh`（ad-hoc 签名 + 写入用户级 TCC 授权库）：`build` 编译、`launch` 启动、`restart` 重新编译并启动、`tcc` 仅写 TCC 授权。
  - `Lumi/restart_lumi.sh`：退出旧实例 → 调用 `sign_and_run.sh` 重新签名并启动。

### 在 Cursor / VS Code 中调试（CodeLLDB）

项目已内置 `.vscode/` 配置，安装 **CodeLLDB** 扩展后即可断点调试 Swift。

1. 安装扩展：`vadimcn.vscode-lldb`（及 Swift 语言支持 `sswg.swift-lang`）。
2. `Cmd/Ctrl + Shift + D` 打开运行视图，选择下列配置之一按 `F5`：

   | 配置 | 行为 |
   | --- | --- |
   | `Lumi (build & run)` | 编译 debug 产物并直接启动（无 TCC 包装，适合快速验证） |
   | `Lumi (.app build & run)` | 编译 + 打包 + 授权，启动完整 `.build/Lumi.app`（带 Music 自动化等系统权限） |
   | `Lumi (attach & wait)` | 自动等待 `Lumi` 进程启动并附加调试器（适合排查已授权 App 的运行问题） |

3. 若调试带系统权限的完整 App 时权限异常，先执行一次：

   ```bash
   cd Lumi && ./run.sh tcc
   ```

   把 `com.lumi.app` 写入用户级 TCC 授权库（仅用户级，不影响系统级数据库）。

> 提示：调试器默认使用 Xcode 工具链（`DEVELOPER_DIR` 指向 Xcode），以正确解析 SwiftUI 宏。固定使用 `MacOSX26.5.sdk` 构建（见 `run.sh` 注释），当前 27 SDK 下 SwiftPM 无法解析 SwiftUI 宏插件。

### 单元测试（SwiftPM / XCTest）

项目已内置 `LumiTests` 测试目标与 `swift-test` 任务，使用 **swift-test** skill 驱动。

1. 测试代码放在 `Lumi/Tests/LumiTests/`（`*Tests.swift`，方法以 `test` 开头）。
2. 运行：

   - 编辑器：`Cmd/Ctrl + Shift + P` → Tasks: Run Task → `swift-test`（已设为默认测试任务）。
   - CLI：

     ```bash
     cd Lumi
     export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
     swift test
     ```

3. **关键约束**：
   - `swift test` **必须**在 Xcode 工具链下运行（默认 27 SDK 解析不了 SwiftUI 宏）。
   - `testTarget` 不应引入 `AppKit`/`SwiftUI`/`WebKit` 等 GUI 框架（无登录会话下会链接/运行失败）。只测纯逻辑（CryptoKit、Foundation、算法、编解码、校验）。GUI 行为用调试配置手动验证。
4. AI 助手可用 **swift-test** skill（位于 `.codebuddy/skills/swift-test`）生成/运行用例、排查 `SwiftUIMacros not found`、SDK 版本、GUI 链接等常见失败。

## License

本项目版权归作者所有，详见各模块许可证说明。
