# Lumi for Windows — 技术方案

> 目标:把 Lumi 的核心能力(双语歌词 + 翻译 + 插件市场)带到 Windows。
> 本文档为 Phase 0 前的对齐方案,确认后再写代码。

---

## 1. 决策(已与用户确认)

| 维度 | 决策 | 理由 |
|------|------|------|
| 技术栈 | **Electron + React/TS + Node 后端** | 用户机器已有 Node/npm,无需安装 Rust;Windows 构建直接出 exe,无交叉编译坑 |
| 音乐源 | **Apple Music(Windows 版)**,经 Windows 系统媒体控制(SMTC)读取 | 用户指定 Apple Music 架构 |
| 歌词源 | **lrclib(默认,免费无 key)+ Musixmatch(补充)**,翻译层做双语 | 与 Mac 版一致,已在 Mac 版验证可行 |
| 双语+翻译 | 双语显示 + 翻译后端,逻辑 1:1 对齐 Mac 版 | 是 Lumi 核心资产 |
| 插件市场 | 保留,feed 格式与 Mac 版对齐 | 用户明确要求 |

---

## 2. Windows 平台的现实约束(必须接受)

1. **Apple Music on Windows 没有公开本地 API**。Mac 上 `MusicKit` 能拿官方时间轴歌词,
   Windows 上 Apple Music 不暴露逐行歌词。
   - 曲目名/艺人/播放进度:可经 **Windows Media Control (SMTC / `GlobalSystemMediaTransportControls`)** 读取。
   - 逐行时间轴歌词:**Apple Music 不提供** → 用 **lrclib**(社区从 Apple Music 扒取的同步歌词,你 Mac 版已在用)补全。
   - 结论:Windows 上"双语歌词" = SMTC 曲目信息 + lrclib 同步歌词 + 翻译层,体验接近 Mac 版但歌词源非官方。

2. **没有"动态岛"**。Windows 等价物是 **桌面歌词悬浮窗**:
   - 置顶(`alwaysOnTop`)、可拖拽、鼠标穿透(不挡操作)
   - 系统托盘常驻(右键菜单:显示/隐藏/退出/设置)
   - 这是 Windows 歌词软件标准形态(如 Lyrics Overlay)。

---

## 3. 架构

```
Lumi-Win/  (仓库内 windows/ 子目录)
├── package.json            # Electron + React + Vite
├── src/
│   ├── main/               # Electron 主进程(Node)
│   │   ├── media.ts        # SMTC 读取 Apple Music 当前曲目/进度
│   │   ├── lyrics.ts       # lrclib / Musixmatch 拉取同步歌词
│   │   ├── translate.ts    # 翻译后端(对齐 Mac 版)
│   │   ├── plugin.ts       # 插件市场(feed 拉取 + 本地桥接)
│   │   └── tray.ts         # 系统托盘
│   ├── renderer/           # React 前端
│   │   ├── LyricOverlay.tsx# 桌面歌词悬浮窗(原文+译文双行)
│   │   ├── Panel.tsx       # 主面板(等价 Mac 总面板)
│   │   └── PluginPanel.tsx # 插件 WebView 容器(iframe)
│   └── shared/
│       └── types.ts        # 跨进程类型(与 Mac 版 PluginManifest 对齐)
├── plugin-feed.win.json    # Windows 版插件市场 feed(格式同 Mac)
└── docs/windows-plan.md
```

主进程(Node)负责所有系统/网络操作,渲染进程(React)只负责 UI。
翻译、歌词、插件逻辑放在主进程,通过 IPC 暴露给渲染进程。

---

## 4. 双语 + 翻译(对齐 Mac 版 `MusicController.swift`)

Mac 版已实现的逻辑,Node 重写、行为一致:

- **默认翻译后端**:Google 公开接口
  `https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=<target>&dt=t&q=<text>`
  无需 key、无每日硬限额,质量足够。
- **可选增强后端**:阿里通义千问 `qwen-plus`(`dashscope.aliyuncs.com/compatible-mode/v1`),
  配置 `LUMI_TRANSLATE_API_KEY` + `LUMI_FORCE_LLM=1` 时优先,失败回退 Google。
- **双语模式**(对齐 Mac `BilingualMode`):`off` / `auto` / `on`
  - `auto`:歌词自带双语则显示对照,否则联网翻译补全
  - `on`:强制翻译补全另一语言
- **行级对齐**:逐行翻译(RC 每行独立翻译),保留 lrclib 时间轴做逐行高亮。
- **重试/节流**:串行节流(批次间隔 ~0.3s)+ 最多重试 2 次;失败行保留"翻译中",下轮轮询补译(对齐 Mac 版 `translateWithRetry`)。
- **配置来源**:`translate.env`(绝对路径 `~/Library/Application Support/Lumi/translate.env` 在 Windows 上为 `%APPDATA%/Lumi/translate.env`),只认文件、不回退进程环境变量(对齐 Mac 版 `envValue`)。

---

## 5. 音乐源(对齐 Mac 版 Apple Music 架构)

- Mac 版:AppleScript 控制 Apple Music,读 `title/artist/artwork/playbackState/currentTime`。
- Windows 版:
  - **SMTC** 读 Apple Music(Windows)当前 `title/artist/position/duration/playbackStatus`。
  - 专辑封面:SMTC `Thumbnail`(若 Apple Music 提供)或回退占位。
  - **限制**:SMTC 不提供逐行歌词 → 见第 2 节,用 lrclib 补全。
  - 歌词匹配:用 SMTC 的 `title+artist` 去 lrclib 搜索同步歌词,按 `currentTime` 做逐行高亮 + `lyricsOffset` 校准(对齐 Mac 版偏移逻辑)。

---

## 6. 插件市场(对齐 Mac 版)

feed 格式**完全复用** Mac 版 `plugin-feed.json`:

```json
{
  "schemaVersion": 1,
  "plugins": [
    {
      "id": "com.lumi.sample-plugin",
      "name": "示例插件（天气）",
      "iconName": "cloud.sun",
      "urlScheme": "lumi-sample",
      "appName": "LumiSamplePlugin.app",
      "panelHint": "演示第三方 app 接入灵动岛",
      "minHostVersion": "1.1.9",
      "downloadURL": "https://github.com/cpufreestyle/Lumi/releases/download/v1.1.9/LumiSamplePlugin.app.zip",
      "permissions": [ { "type": "network", "reason": "获取天气数据" } ]
    }
  ]
}
```

- Windows 版维护独立 feed `plugin-feed.win.json`(downloadURL 指向 `.exe`/`.zip` 资产)。
- **桥接机制对齐 Mac 版**:文件桥接 `~/Library/Application Support/Lumi/PluginPanels/<id>.json`
  (Windows: `%APPDATA%/Lumi/PluginPanels/<id>.json`),主进程每 1s 轮询,渲染进程 `PluginPanel.tsx` 用 `iframe` 加载插件面板(等价 Mac `PluginPanelBridge`/`PluginDiscovery`)。
- 插件面板内容:第三方 Web H5(天气/小游戏等),通过 `postMessage` 与主进程通信(等价 Mac 的桥接协议)。
- 版本比较:实现 `PluginManifest.isVersion(_:newerThan:)`(分段数字比较,对齐 Mac)。

---

## 7. UI 形态(Windows 等价物)

| Mac 版 | Windows 版 |
|--------|-----------|
| 动态岛(刘海黑岛) | 桌面歌词悬浮窗(置顶+鼠标穿透+可拖拽) |
| 菜单栏图标 | 系统托盘图标(右键菜单) |
| 收缩态黑岛 | 悬浮窗单行(原文+译文) |
| 悬停预览态 | (Windows 无 hover 概念,省略) |
| 展开总面板 | 点击悬浮窗/托盘 → 弹出主面板 |

悬浮窗交互:
- 单击悬浮窗:展开主面板
- 双击:重置歌词偏移
- 长按拖拽:微调歌词位置(对齐 Mac `lyricOffset`)
- 右下角:取消固定/尺寸调节手柄(对齐 Mac)

---

## 8. 构建与交付

- 开发(macOS 验证):`npm install && npm start` → Electron 起 macOS 版 UI + 翻译后端跑通
- 打包 Windows exe:`npm run build:win`(electron-builder,在 Windows 机器上执行出 `.exe`)
- 自动更新:复用 Mac 版 Updater 思路(GitHub Release tag 比对),Windows 用 `electron-updater`

> 注:当前开发机为 macOS,Phase 0 先在 macOS 用 `npm start` 验证 UI/翻译/插件逻辑;
> 出 Windows exe 需在 Windows 机器执行 `npm run build:win`(cross-compile 不推荐)。

---

## 9. 分阶段计划

- **Phase 0**:Electron 空壳 + 系统托盘 + 置顶歌词悬浮窗原型 + 翻译后端(Google/阿里)打通,显示一行"原文→译文"
- **Phase 1**:SMTC 接 Apple Music 当前曲目 + lrclib 拉同步歌词 + 逐行滚动 + 双语模式
- **Phase 2**:插件市场(feed 拉取 + WebView 面板 + 桥接轮询)
- **Phase 3**:设置面板/双语切换/快捷键/自动更新打磨

---

## 10. 与 Mac 版共享的资产

- 翻译后端协议(Google/阿里、env 配置、重试节流)—— Node 重写,行为一致
- 插件市场 feed 格式 + 桥接协议 —— 跨平台复用
- 双语歌词产品逻辑(模式/偏移/行级对齐)—— 跨平台复用
- 翻译配置 `translate.env` 约定 —— 跨平台复用(路径按平台映射)

---

## 待确认(已用户授权"你定",按上述默认值执行)

- 歌词源默认 lrclib(免费无 key),Musixmatch 作补充 —— 已定
- 项目放 `Lumi/windows/` 子目录,共享插件 feed 设计 —— 已定
- 技术栈 Electron(因 Rust 安装被拒)—— 已定
