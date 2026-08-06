# Lumi

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

```bash
git clone https://github.com/cpufreestyle/Lumi.git
cd Lumi
bash Lumi/run.sh restart      # 构建并启动
```

或手动构建：

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

## 开发

- 源码位于 `Lumi/Sources/Lumi/`，按 `Core`（状态/许可证）、`Modules`（各功能模块）、`Views`（界面）组织。
- 构建与运行统一通过 `Lumi/run.sh`：`build` 编译、`launch` 启动、`restart` 重新编译并启动。

## License

本项目版权归作者所有，详见各模块许可证说明。
