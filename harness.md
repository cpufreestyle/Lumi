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
# 期望：Build complete（0 warning / 0 error）；621 tests / 0 failures

# 2. Node 后端
cd ..
npm test
# 期望：51 pass / 0 fail
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
- 支付宝后端链路（仅 curl，客户端无入口）：`POST /api/alipay/order` 无凭证时应返回
  `sandbox: true` 与本地 `/pay/sandbox/...` 支付页；模拟回调命中后 `GET /api/alipay/query`
  应返回 `paid` 并携带激活码。真实收款仍需公网 notify_url 与 `ALIPAY_PUBLIC_KEY` 验签。

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

完整 UI 交互与 NSIS 安装流程两个架构都未验证；编译与单测门禁已接 CI，见下方「CI」小节。

**校验 NSIS 安装包架构时不要读外层 PE 头。** 安装包外层是 NSIS 自带的引导 stub，
它本身就是 32 位（`machine=0x14c i386`），与包内 payload 架构无关——三个包
（`-win-x64` / `-win-arm64` / `-win`）读出来全都是 `i386`，这是标准行为，不是产物
搞错。真正的应用架构只有两处可验：`release/win-unpacked/Lumi.exe` 与
`release/win-arm64-unpacked/Lumi.exe` 的 PE 头（分别是 `x86_64` / `ARM64`），
或构建日志里的 `archs=x64, arm64`。payload 是 LZMA 压缩的，在 exe 里扫不到 PE 头。

判断是否真的出了某个架构的产物，看构建日志有没有 `packaging ... arch=<名字>` 与
`building target=nsis ... archs=<列表>` 两行，比看文件名可靠。曾经把 `ia32`
（32 位）误加进 `arch` 数组，产物、`APP_32` define、日志行全都正常出现，
只有逐行读日志才发现它确实参与了构建。

另外：`release/` 里同名 exe 的大小会差几个字节（NSIS 有时间戳字段），
不要用大小精确比对来判断构建是否变化。

应用图标已补齐：`windows/build-resources/icon.ico` 由
`Lumi/Resources/AppIcon.assets/AppIcon_1024.png` 缩放生成（16/24/32/48/64/128/256
七档，32bpp，与 macOS 端同源），已确认嵌入 `Lumi.exe` 与三个 NSIS 安装包的资源段
（2026-10-22 逐字节比对 ICO 内嵌 PNG 验证）。换图标时改 `Lumi/tools/make_icon.swift`
后重跑 `Lumi/tools/make_app_icon.sh`，再重新生成 ico。

## CI（自动化门禁）

`.github/workflows/ci.yml` 在 push 到 main、每个 PR（含 Dependabot PR）和手动触发时跑两个
job，对应上面的本地门禁第 2、3 步；第 1 步（Swift 全量）不在 CI 里，理由见下方「更正」：

| job | 内容 | 对应本地命令 | 基线（2026-11-04 本机实测） |
| --- | --- | --- | --- |
| `node-server` | `npm ci` + `npm test` | 第 2 步 | 51 pass / 0 fail |
| `windows-app` | `build:main`(tsc) + `build:renderer`(vite) | Windows 交叉打包的前半段 | tsc 无错、vite 26 modules |

### 更正（2026-11-07 首跑实测）：Swift job 已从 CI 移除

上一版 workflow 里有 `swift-macos`（`runs-on: macos-26`），假设本环境有可调度的 macOS runner。
首跑证明这个假设不成立，但**我随后写下的「换标签也没被调度」这条结论也错了**，一并更正：

- run `42255217688`（commit `03b01fb`，`macos-26`）：job 停在 `queued`，始终没拿到 runner，
  最终 `status=completed / conclusion=cancelled / steps=0` —— `macos-26` 这个标签确实没有 runner。
- 探针 run `42256803568`（commit `50c8184`，改 `runs-on: macos-latest`）：**这条其实被调度并跑完了**，
  7 个 step 都在：`解析 macOS 26.5 SDK` success、`swift build` success、`swift test` **failure**，
  日志汇总行 `Executed 621 tests, with 3 failures (0 unexpected)`。我之前看到 `jobs` 列表为空是
  API 抖动的空响应，据此下「换标签也没被调度」的判断是误判。
- 本机同一套用例（`swift test --sdk .../MacOSX26.5.sdk`）实测 621 tests / **0 failures**，
  同批 `node-server` / `windows-app`（`ubuntu-latest`）19s / 23s 全绿。

结论（修正版）：`macos-26` 无 runner；`macos-latest` 有 runner 且能编译，但那台镜像上有 3 个
环境相关用例失败（本机全绿）。差异在 runner 镜像与本机环境不同，不是 token 也不是网络。
在定位这 3 个用例之前，把它留在 CI 只会让 workflow 常红，所以 CI 先只保留跑得动的两条，
Swift 全量退回本机执行（本文件第 1 步），`scripts/ci/resolve-sdk.sh` 继续为本机命令解析 SDK 路径。

**待办（阻塞重新纳入 CI）**：拿到 `swift test` 失败用例名。目前 CI 日志端点持续
`EOF`/490 空响应，取不到；下一步换 `gh run view --log` 或在 job 页面上直接看 step 5。

要点：

- **SDK 不写死绝对路径**：由 `scripts/ci/resolve-sdk.sh` 解析。本机 26.5 SDK 在
  `/Library/Developer/CommandLineTools/SDKs/`，macos-26 镜像里在 Xcode 内部，两处路径不同。
  脚本找不到任何 macOS 26.x SDK 时以退出码 1 结束，**不回退到 27 SDK**——`spec.md` 记过
  27 SDK 下 SwiftUIMacros 解析失败，静默回退只会产出一堆看不懂的宏错误。
- **`runs-on: macos-26`**：镜像带 Xcode 26.5/26.6，两者都含 `MacOSX26.5.sdk`；macos-14 已于
  2026-11-02 停止支持。
- **Windows job 只编译不打包**：`ELECTRON_SKIP_BINARY_DOWNLOAD=1` 跳过 Electron 二进制，
  不跑 electron-builder/NSIS、不签名。这些仍需 Windows 实机，见上方「Windows 交叉打包」。
- **CI 绿 ≠ 可发布**：实机行为级自检、GUI 行为、NSIS 安装流程都不在 CI 内（见「已知测试
  盲区」），发布前仍要按 `spec.md` 的发布约束手动跑一遍。
- **required checks 不在本文件里生效**：job 名（`Node 后端（npm test）`、
  `Windows 端编译（tsc + vite）`）要在仓库 Settings → Branch protection 里勾成必过检查，
  才能真正让 bot PR「有人敢点 merge」；Swift 那条既然不进 CI，就不可能有对应 required check，
  改由发布流程在本机执行第 1 步兜底。

## 已知测试盲区

- AppKit/SwiftUI 层（IslandWindowController / 桌面浮窗的行为）由「实机行为级自检」覆盖；
  单测只覆盖纯逻辑，GUI 行为没有 E2E 自动化 —— 新增依赖 GUI 行为的功能要手动验
- 多屏镜像的运行时三场景依赖真实外接屏（已在本机验证过，未自动化）
- AppleScript 播控链路依赖 Music 运行态，未在 harness 里自动化
