

## Codely Structured Memories

### User

### Feedback

### Project
- [2026-08-16 16:16:44] JacobeAPI（Skill/MCP 管理工具，原仅支持 Windows）已做 macOS 移植并注册为 Lumi 插件。源码在 "/Users/a1-6/AI Shared/repo/JacobeAPI"，已推送到 fork cpufreestyle/JacobeAPI（commit fc4fb47）。改动：非 Windows 平台用 LocalKeyBackupProtector（AES-256-GCM + ~/Library/Application Support/com.jacobe.skills/backup.key）替代 DPAPI；paths.rs 支持 HOME 回退；capabilities 平台加 macOS；tauri.macos.conf.json 平台覆盖含 macOSPrivateApi。重建命令：PATH 加 ~/.cargo/bin 和 nvm node 后 `NODE_ENV=development npm ci && npm run tauri -- build --config src-tauri/tauri.macos.conf.json`；注册到 Lumi：`./install_lumi_plugin.sh`。本机工具链坑：NODE_ENV=production 全局生效（npm ci 会跳过 devDependencies，需 NODE_ENV=development）；brew 在 /opt/homebrew/bin 但不在 CLI PATH；node 走 nvm（v22/v24）；Rust 用 rustup（~/.cargo/bin）；Lumi 免费证书签名身份不可用时 `open .build/Lumi.app` 可直接启动。注意： JacobeAPI 无上游 LICENSE，公开分发有合规风险。

- [2026-08-16 18:09:19] Lumi 重启的正确姿势（2026-08-16 踩坑）：裸 `swift build` 只更新 .build/debug/Lumi，**不会更新 .build/Lumi.app bundle**——直接 open 旧 .app 会跑旧代码。必须用 `cd Lumi/Lumi && ./restart_lumi.sh`（免费证书身份失效时 `./sign_and_run.sh --adhoc`），它会 package（拷贝新二进制+Info.plist 进 .app）→ codesign → launch。验证方法：`stat -f "%Sm" .build/Lumi.app/Contents/MacOS/Lumi` 对比 debug 二进制时间戳。构建用 SDK MacOSX26.5.sdk。

- [2026-08-16 17:16:08] ClipboardPlus（剪贴板增强）已从 Lumi 内置模块抽离为独立 SwiftUI .app 插件并上架官方源。源码在 "/Users/a1-6/AI Shared/repo/ClipboardPlus"（Git 仓库，cpufreestyle/ClipboardPlus）。Swift Package, macOS 13+。功能：剪贴板历史（100条，JSON 持久化）、格式转换（大小写/URL/Base64/JSON）、隐私过滤、置顶固定、菜单栏常驻。LumiPanelWriter 每 2s 写面板数据到 PluginPanels/<id>.json 供 L3 渲染。注册 lumi-clipboard-plus URL Scheme 支持面板回跳。Manifest 含 panel:true + urlScheme。构建打包：`bash build.sh --zip`。市场下载：v1.1.19 Release 的 ClipboardPlus.app.zip。Lumi commit b6bceba（移除内置模块）+ 26458c8（插件无数据时显示占位面板而非回退音乐）已推 main。官方 feed 现有 3 插件：sample-plugin、JacobeAPI、clipboard-plus。
- [2026-08-16 18:09:27] Lumi 市场管线关键坑（2026-08-16 修复，commit 7a1ec90）：`ditto -c -k` 打包 .app 必须加 `--keepParent`，否则 zip 根是 Contents/，市场安装报「压缩包内无 .app」→ 卸载后无法重装。PluginArchive.locateOrWrapApp 已做坏包自愈（按清单 appName 补外壳）。官方 feed = GitHub main 的 Lumi/plugin-feed.json；Release 资产上传用 git credential fill 提取钥匙串 token + curl（本机无 gh CLI）。JacobeAPI 已上架官方源（v1.1.19 资产，id com.jacobe.skills）。
- [2026-08-16 18:27:52] JacobeAPI macOS HiDPI 坑（2026-08-16 修复）：QUICK_WIDTH/HEIGHT(420×700) 等常量按逻辑像素设计，但 set_size(PhysicalSize)/work_area 均为物理像素——Retina 2x 下面板实际只有设计值一半宽（内容挤压截断）。修复：place_quick_panel 加 scale 参数 + work_area_scale_factor 按 work area 匹配显示器取 scale_factor；悬浮球初始位置 position() 收逻辑坐标需除以 monitor_scale。Tauri 跨 Windows/macOS 时务必区分 PhysicalSize vs LogicalSize。

### Reference

