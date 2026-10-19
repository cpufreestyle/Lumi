# Lumi 验证 harness

本文件是「如何把项目验证跑一遍」的单一入口。改代码后应按下面顺序执行；
行为契约本体见 `spec.md`。

## 命令（按依赖顺序）

```bash
# 1. Swift 全量（编译 + 单元测试，SDK 必须固定，否则宏插件解析失败）
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd Lumi
swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift test  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
# 期望：Build complete（0 warning / 0 error）；586 tests / 0 failures

# 2. Node 后端
cd ..
npm test
# 期望：41 pass / 0 fail
```

两条都绿才视为 harness 通过。任何新 commit 前都要跑；发布前必跑（见 spec.md 的发布约束）。

## 可选自检（实机行为级）

- App 启动 10 秒内不应出现快捷键说明面板（防「启动就跳出来」回归）
- 菜单栏图标菜单应含五项：显示/隐藏动态岛 · 播放状态标题 · 全局快捷键开关 · 快捷键与手势说明 · 退出
- ⌘⌥P 触发时 Music 应切换播放态，且不弹胶囊（可用 `/tmp/keyto <pid>` 真实合成按键）
- 触发后菜单栏图标在 0.8 秒内短暂换为 play/pause 符号后还原（短时窗需密集采样截图验证）
- 日历面板可见时数据来自 EventKit 且不重复弹授权窗（已授权时 request* 不应被调用）
- 歌词卡片分享按钮：Premium 未解锁不显示；解锁后未播放时点击无反应（原文空）；
  播放中点击应在 ~1 秒内弹出系统分享面板（含 AirDrop / 邮件 / 备忘录）
- 语法注解按钮：Premium 未解锁不显示；解锁后未播放时点击无反应；播放中点击应在 2-20 秒内
  显示 1-3 条小卡（失败给行内错误提示，不阻塞歌词主流程）

## 打包与安装（macOS）

```bash
cd Lumi
./run.sh install     # 显式把 .build/Lumi.app 同步到 /Applications（默认不同步）
```

`/Applications/Lumi.app` 已于 2026-10-19 按用户要求删除；实际运行的永远是
`.build/Lumi.app`，桌面启动器（`~/Desktop/Lumi.app`，由 `tools/make_desktop_shortcut.sh`
生成）自带 `.build` 回退，删安装位不影响任何启动路径。为什么需要同步、为什么默认
不同步，完整理由见 `Lumi/run.sh` 内 `install_to_applications()` 注释（TCC csreq 按
cdhash 钉死那一段），不要凭直觉加回去。

## Windows 交叉打包（无需 Wine）

```bash
cd windows
npm run build:win    # 同时出 x64 与 arm64：Lumi-0.1.0-win-x64.exe / -win-arm64.exe / -win.exe
```

验证分两层：

- **x64 已用 Wine 实跑**（`WINEPREFIX=~/.wine wine Lumi.exe`）：主进程、GPU 进程、
  renderer 全部初始化，renderer 路径 bug 已修。证据见
  `docs/handoff-品牌安装位与Windows构建-2026-10-19.md` 文末附录。
- **arm64 只验证产物完整**（asar 内容 / PE 头 / 大小）：本机 Wine 是 Intel 二进制跑
  Rosetta，跑不了 PE32+ Aarch64（`ShellExecuteEx failed: Bad format.`），需真机。

完整 UI 交互与 NSIS 安装流程两个架构都未验证。当前未接 CI。

## 已知测试盲区

- AppKit/SwiftUI 层（IslandWindowController / 桌面浮窗的行为）由「实机行为级自检」覆盖；
  单测只覆盖纯逻辑，GUI 行为没有 E2E 自动化 —— 新增依赖 GUI 行为的功能要手动验
- 多屏镜像的运行时三场景依赖真实外接屏（已在本机验证过，未自动化）
- AppleScript 播控链路依赖 Music 运行态，未在 harness 里自动化
