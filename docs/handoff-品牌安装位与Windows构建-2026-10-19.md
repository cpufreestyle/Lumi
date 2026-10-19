# Lumi 交接：品牌标识 · 安装位收尾 · Windows 构建（2026-10-19）

> 生成时间：2026-10-19 18:05 · 交接人：Codex
> 适用对象：下一会话 / 下一位接手者
> 仓库：`git@github.com:cpufreestyle/Lumi.git`，`main` 与 `origin/main` 同步，工作树干净，无 stash。
> 本轮全部改动已提交并推送，**无未提交内容**。

---

## 1. 当前状态快照

| 面 | 状态 |
|---|---|
| macOS App | v1.2.0（权威源 `Lumi/Resources/Info.plist`）。Music 模块 v1.2.0 已收尾，**发布尚未执行**，步骤见 `docs/handoff-v1.2.0-发布准备-2026-10-03.md` |
| 运行实例 | `Lumi/.build/Lumi.app`（`pgrep -x Lumi` 可见，交接时 pid 5034）。`/Applications/Lumi.app` 已按用户要求删除 |
| 桌面启动器 | `~/Desktop/Lumi.app`，由 `Lumi/tools/make_desktop_shortcut.sh` 生成的壳：优先 `/Applications`、回退 `.build`；已在跑时只唤醒不重启 |
| Windows | `lumi-win` 0.1.0，产物 `windows/release/Lumi-0.1.0-win-arm64.exe`（96,288,448 B，PE32 NSIS），**未实机验证** |
| 依赖告警 | Dependabot open **17 条**：0 critical / 7 high / 6 medium / 4 low，逐条归因见 `docs/依赖安全台账.md` |
| harness | Swift **586 passed / 0 failed**；Node **41 pass / 0 fail**（Node 于本交接撰写时复跑确认，Swift 基线见 §3） |

## 2. 本轮完成的工作

### 2.1 品牌标识「michaelqiu 出品」（`28c4de7`）

- `Lumi/Resources/Info.plist` 增加 `NSHumanReadableCopyright = michaelqiu 出品`。
  选这个字段而非自定义 key：它是 macOS 标准位，Finder「显示简介」、崩溃报告、
  `NSBundle` API 都能读到，且随构建持久生效（改源头，而不是给已打包的 `.app`
  打补丁——那样下次构建就丢）。
- `README.md` 两处：顶部加「michaelqiu 出品」行；版本号 v1.1.21 → v1.2.0
  （Info.plist 早已是 1.2.0，README 漂移了）。

### 2.2 「有两个 Lumi」清理 + `run.sh install` 子命令（`3e565ef`）

**背景**：用户反馈「有两个 Lumi」。查明本机共三份、各有用途：

| 位置 | 用途 |
|---|---|
| `~/Desktop/Lumi.app` | 桌面启动器壳（638B），优先 `/Applications`、回退 `.build` |
| `/Applications/Lumi.app` | 安装位镜像，只为「双击打开」存在 |
| `Lumi/.build/Lumi.app` | 构建产物，**实际运行的一直是这个** |

用户要求删掉安装位那份。原逻辑的问题：同步代码埋在 `tcc()` 里，与「写授权」
耦在一起；且一旦删掉 `/Applications`，下次 `launch` 又会重建，删除无法延续。

**改动**（`Lumi/run.sh`，+32/-11）：
- 抽出顶层 `install_to_applications()`，「授权」与「安装」解耦；
- 新增 `./run.sh install` 显式子命令（头部用法注释同步补行）；
- `tcc()` 尾部默认不同步，并打印一行提示告知开关位置，不再静默跳过；
- 保留 `LUMI_INSTALL_TO_APPLICATIONS=1` 兼容旧用法。

注释里完整保留了两方面理由，避免后人又把它加回去：
- **为什么需要同步**：TCC 的 csreq 按本机 cdhash 逐位钉死，双击打开 / 桌面快捷方式
  走 `/Applications/Lumi.app`；不同步则授权只对 `.build` 生效，正式安装位持续弹系统授权框。
- **为什么默认不做**：实际运行的永远是 `.build`（`launch` 里 `open "$APP"`），
  `/Applications` 只是镜像，平时反而像两个 App；桌面启动器本身有 `.build` 回退，
  删掉安装位不影响任何启动路径。

**实测**：`./run.sh launch` 打提示且 `/Applications` 不被重建；`./run.sh install`
同步成功；`bash -n` 通过。Swift 586 passed / Node 41 pass。

### 2.3 依赖安全加固（`3197046` → `9745aa6` → `7661eff`）

| 提交 | 内容 |
|---|---|
| `3197046` | `proxy-addr` critical 修复（根生产依赖树，2.0.7 → 2.0.8），本轮起点 |
| `9745aa6` | windows 增加 `source-map-js ^1.2.2` override，修 high 级事件循环 DoS |
| `7661eff` | `docs/依赖安全台账.md` 按 GitHub API 真实数据定稿 17 条，补 SSH 代理绕过方法 |

`windows/package.json` 现有 overrides：`@xmldom/xmldom ^0.8.15` / `fast-uri ^3.1.6` /
`js-yaml ^4.3.2` / `source-map-js ^1.2.2`。根 `package.json` overrides：
`qs ^6.16.0` / `proxy-addr ^2.0.8`。

### 2.4 Wine CLI + Windows 打包修复（`cdb712a`、`ffef13e`）

**结论先行，细节不在此重复**，完整交接（含「已走过的弯路」表）见
`docs/handoff-wine-cli-windows构建修复-2026-10-19.md`：

- Wine CLI 装好可用：`wine-11.16`，`WINEPREFIX=~/.wine wineboot --init` exit 0。
  （`getaddrinfo Failed to resolve your host name` 是无害告警。）
- electron 下载卡死的真因**不是缺 Wine**（NSIS 目标不需要 Wine）。
- `cd windows && npm run build:win` 成功（`.npmrc` 已含 mirror，无需手写 export）。
- asar 已含 `dist/main.js` 等全部入口，根因是 app 产物目录与 electron-builder
  输出目录同为 `dist/`（`cdb712a` 分离之）。
- 净关 Dependabot 4 条（21 → 17）。

## 3. 验证状态（交接时可复跑）

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd Lumi
swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk   # 0 warning / 0 error
swift test  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk   # 586 passed / 0 failed
cd .. && npm test                                                            # 41 pass / 0 fail
```

- **Node 41/41**：本交接撰写时（10-19 18:0x）实际复跑确认。
- **Swift 586**：最后一次实跑在 `3e565ef`（10-17 21:05）。此后 `3e565ef..HEAD`
  的改动只有 `docs/`、`package.json`、`package-lock.json`、`windows/`
  （`git diff --name-only 3e565ef..HEAD` 可证），**无 Swift 源码变更**，基线仍成立；
  如不放心可重跑上面两条。
- spec/harness 未因本轮改动更新：本轮不触及 `spec.md` 的行为契约
  （品牌字段、run.sh 子命令、windows 构建配置均不在契约清单内）。
  仅在 `harness.md` 补了「macOS 打包/安装」与「Windows 交叉打包」两节命令。

## 4. 环境事实（省得重复踩坑）

- `/Applications/Lumi.app` **不存在**（已删）。需要时 `cd Lumi && ./run.sh install` 显式同步。
- 实际运行实例永远是 `.build/Lumi.app`；调试时若看到「两个胶囊」，先 `pgrep -x Lumi` 排双实例。
- SSH 推送走 `~/.ssh/config` 的小火箭代理；无代理时的绕过方法记在 `docs/依赖安全台账.md`。
- 构建日志在 `/tmp/lumibuild/*.log`（含并发构建互删文件的全过程）、验证日志 `/tmp/lumiverify/`。
- 误删的 359MB 残留产物在 `~/.Trash/lumi-win-arm64-unpacked-stale-*`，半成品在
  `~/.Trash/lumi-unpacked-partial-*`。

## 5. 遗留与下一步（按优先级）

1. **Windows 侧未实机验证**：本机是 macOS，asar 完整性与 exe 格式已校验，但
   「装上去能否启动」仍缺证据。需要一台 Windows on Arm 机器，或至少用 Wine 跑
   `win-arm64-unpacked/Lumi.exe` 看能否起到主进程。
2. **没有应用图标**：构建日志有 `default Electron icon is used reason=application icon is not set`。
   `windows/build-resources/` 已建好占位，放 `icon.ico` 即可，缺设计稿。
3. **17 条依赖告警待评估**：electron 43.4.0→43.4.1/43.5.0（4 high）；
   undici 6.28.0→6.28.1/7.29.1（7 条）；vite 5.4.21→6.4.x（3 条，**主版本升级，
   必须单独跑 `npm run build:win` 验证**）；esbuild 0.21.5→0.25.0（1 medium，主版本）；
   http-cache-semantics 4.2.0、sprintf-js 1.1.3（暂无修复版，只能记录）。
4. **只构建了 arm64**：`win.target` 显式 `nsis / arm64`，要出 x64 需改数组，
   且 Apple Silicon 上交叉打包 x64 需额外验证。
5. **`npm run build:win` 未接 CI**：CI 机器仍需自备 Node 与 macOS。
6. **v1.2.0 发布尚未执行**（见 §1 指向的发布准备交接）。
7. **歌词时序技术债**：用户近期反馈过歌词延迟 / 与演唱不同步 / 来回跳动，
   相关记录在 `docs/music-lyrics-troubleshooting.md` 与
   `docs/tech-debt-swift6-concurrency.md`（MusicController 歌词翻译重试的 Swift 6 并发），
   下一轮若碰 Music 模块建议先读这两份。

## 6. 本轮提交记录

```
ffef13e docs: 新增 Wine CLI 安装与 Windows 打包修复交接
7661eff docs: 台账按 GitHub API 复核结果定稿 17 条，补 SSH 代理绕过方法
b685bc9 docs: 台账记录 brace-expansion / source-map-js 修复与 Windows 构建环境
9745aa6 fix(deps): windows 增加 source-map-js ^1.2.2 override，修 high 级事件循环 DoS
cdb712a fix(windows): 恢复 scripts/devDependencies，分离 electron-builder 输出目录与 app 产物目录
3197046 安全：修复 proxy-addr critical（根生产依赖树，2.0.7 → 2.0.8）
3e565ef 重构 run.sh：/Applications 同步改为显式 install 子命令，默认不同步
28c4de7 chore: 打上 michaelqiu 出品品牌标识
```

全部已推送到 `origin/main`，`main` 与 `origin/main` 同步，工作树干净。
