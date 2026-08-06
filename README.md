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
连接系统的 **音乐（Music.app）**，显示当前播放曲目与滚动歌词。

- 当 Apple Music 流媒体曲目无内嵌歌词时，自动回退到 [lrclib.net](https://lrclib.net) 在线歌词。
- 需授权：系统设置 → 隐私与安全性 → **媒体与 Apple Music**，允许 Lumi 访问。

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

## 常见问题

- **歌词不显示**：确认 Music.app 正在播放且已授予「媒体与 Apple Music」权限；部分曲目的在线歌词库无数据属正常情况。
- **界面不出现**：把鼠标移动到屏幕最顶部（状态栏上方）热区。
- **下载失败**：确认已执行 `brew install yt-dlp`，且链接所属站点受支持。

## 开发

- 源码位于 `Lumi/Sources/Lumi/`，按 `Core`（状态/许可证）、`Modules`（各功能模块）、`Views`（界面）组织。
- 构建与运行统一通过 `Lumi/run.sh`：`build` 编译、`launch` 启动、`restart` 重新编译并启动。

## License

本项目版权归作者所有，详见各模块许可证说明。
