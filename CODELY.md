

## Codely Structured Memories

### User

### Feedback

### Project
- [2026-08-27 23:46:06] JacobeAPI（Skill/MCP 管理工具，原仅支持 Windows）已做 macOS 移植并注册为 Lumi 插件。源码在 "/Users/a1-6/AI Shared/repo/JacobeAPI"，已推送到 fork cpufreestyle/JacobeAPI（main: fc4fb47 macOS 移植 + 6fe0703 HiDPI 修复，上游 PR #1 已含两 commit）。改动：非 Windows 平台用 LocalKeyBackupProtector（AES-256-GCM）替代 DPAPI；paths.rs HOME 回退；capabilities 加 macOS；tauri.macos.conf.json 含 macOSPrivateApi。HiDPI 修复：place_quick_panel 加 scale 参数，Tauri 跨平台务必区分 PhysicalSize vs LogicalSize。重建命令：PATH 加 ~/.cargo/bin 和 nvm node 后 `NODE_ENV=development npm ci && npm run tauri -- build --config src-tauri/tauri.macos.conf.json`；市场资产更新：ditto -c -k --keepParent 打包后 DELETE+POST Release assets。本机工具链坑：NODE_ENV=production 全局生效；brew 不在 CLI PATH；node 走 nvm；Rust 用 rustup。注意：JacobeAPI 无上游 LICENSE，公开分发有合规风险；卸载时不杀进程，重装前需先退出。


- [2026-08-16 18:09:19] Lumi 重启的正确姿势（2026-08-16 踩坑）：裸 `swift build` 只更新 .build/debug/Lumi，**不会更新 .build/Lumi.app bundle**——直接 open 旧 .app 会跑旧代码。必须用 `cd Lumi/Lumi && ./restart_lumi.sh`（免费证书身份失效时 `./sign_and_run.sh --adhoc`），它会 package（拷贝新二进制+Info.plist 进 .app）→ codesign → launch。验证方法：`stat -f "%Sm" .build/Lumi.app/Contents/MacOS/Lumi` 对比 debug 二进制时间戳。构建用 SDK MacOSX26.5.sdk。

- [2026-08-27 23:45:53] ClipboardPlus（剪贴板增强）已从 Lumi 内置模块抽离为独立 SwiftUI .app 插件并上架官方源。源码在 "/Users/a1-6/AI Shared/repo/ClipboardPlus"（Git 仓库，cpufreestyle/ClipboardPlus）。Swift Package, macOS 13+。功能：剪贴板历史（100条，JSON 持久化）、格式转换、隐私过滤、置顶固定、菜单栏常驻。LumiPanelWriter 每 2s 写面板数据到 PluginPanels/<id>.json 供 L3 渲染。注册 lumi-clipboard-plus URL Scheme。构建打包：`bash build.sh --zip`。2026-08-16 性能优化已推送（commit a002ca0）：Timer .common mode、复制回环修复（syncChangeCount）、save 防抖 500ms、文本 10000 字符截断、正则预编译、修复身份证/银行卡检测顺序 bug、新增 JWT/API Key/PEM 检测。官方 feed 现有 3 插件：sample-plugin、JacobeAPI、clipboard-plus。

- [2026-08-16 18:09:27] Lumi 市场管线关键坑（2026-08-16 修复，commit 7a1ec90）：`ditto -c -k` 打包 .app 必须加 `--keepParent`，否则 zip 根是 Contents/，市场安装报「压缩包内无 .app」→ 卸载后无法重装。PluginArchive.locateOrWrapApp 已做坏包自愈（按清单 appName 补外壳）。官方 feed = GitHub main 的 Lumi/plugin-feed.json；Release 资产上传用 git credential fill 提取钥匙串 token + curl（本机无 gh CLI）。JacobeAPI 已上架官方源（v1.1.19 资产，id com.jacobe.skills）。
- [2026-08-16 18:27:52] JacobeAPI macOS HiDPI 坑（2026-08-16 修复）：QUICK_WIDTH/HEIGHT(420×700) 等常量按逻辑像素设计，但 set_size(PhysicalSize)/work_area 均为物理像素——Retina 2x 下面板实际只有设计值一半宽（内容挤压截断）。修复：place_quick_panel 加 scale 参数 + work_area_scale_factor 按 work area 匹配显示器取 scale_factor；悬浮球初始位置 position() 收逻辑坐标需除以 monitor_scale。Tauri 跨 Windows/macOS 时务必区分 PhysicalSize vs LogicalSize。
- [2026-08-27 23:45:41] 网络环境（2026-08-16）：本机走 Shadowrocket TUN 模式（fake-ip 198.18.x.x），GitHub 连接常出现 SSL_ERROR_SYSCALL 被掐断（baidu 正常、github/raw.githubusercontent 000）——代理节点或分流规则故障。推送 GitHub 失败时先 curl -s https://api.github.com/zen 判断是网络问题还是 token 问题；token 放 ~/.git-credentials（当前 token 有效，旧 ghp_lXCB... 已失效；凭据不入库，见 .gitignore 约定）。git push 遇 SSL 错误重试即可，或提醒用户检查 Shadowrocket 节点。
- [2026-08-27 23:46:15] Lumi 待推送状态（2026-08-16）：本地 main 领先 origin/main 8 个 commit（2c62682 恢复双击固定、9f45649 yt-dlp 路径、327f042 hover-only、4d25d88 并发修复、54dc48b 单测 10→41、c17db72 仓库卫生、f7f384a 拆分巨型文件、0549d64 下载临时文件修复），因 GitHub 网络故障未推送。网络恢复后执行：cd "/Users/a1-6/AI Shared/repo/Lumi" && git push origin main。注意 origin URL 是 git@github.com:...（SSH 无 key 会失败），需临时换 https+token 或修复 SSH。用户选择的优化方向已含在这些 commit 里（文件拆分、并发修复、测试补充）。

### Reference

