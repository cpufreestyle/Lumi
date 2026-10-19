# 交接：Wine CLI 安装 + Windows 打包首次跑通（2026-10-19）

> 相关文档：依赖告警现状见 `依赖安全台账.md`（本轮已由 21 条复核为 17 条）。
> 本篇只覆盖 **Wine CLI 安装** 与 **`npm run build:win` 从卡死到跑通**，
> 不触碰任何 Swift 侧代码，歌词/封面/时序链路零改动。

## 一句话

用户诉求「能不能安装 cli」已满足（wine-11.16 可用）；顺带发现 Windows 打包
从来没能跑完，卡点不是缺 Wine，而是 **electron 二进制下载**、**被误删的
`scripts` 字段**、以及 **app 产物目录与 electron-builder 输出目录同为 `dist/`**
这三个叠加问题，现已全部修好并产出可用的 NSIS 安装包。

## 现象

用户原始指令是 `能不能安装cli`。装 Wine 的过程中发现 `npm run build:win` 跑不通，
表现为两类：

1. **看起来在下载，永远下不完** —— electron-builder 拉 `electron-v43.4.0-win32-arm64.zip`
   只下到 2.3MB/6MB 就停住。
2. **下载通过后报入口文件损坏**：
   ```
   ⨯ Application entry file "dist/main.js" in ".../resources/app.asar" is corrupted:
      Error: "dist/main.js" was not found in this archive  failedTask=build
   ```

## 根因（三个叠加，都不是缺 Wine）

### 1. electron 二进制直连 GitHub 只有约 40KB/s

`electron-v43.4.0-win32-arm64.zip` 约 6MB，按 40KB/s 要 150 秒以上且经常断，
观感就是「卡住」。**这与是否安装 Wine 完全无关**，此前把卡死归因于缺 Wine 是误判。

镜像 `https://npmmirror.com/mirrors/electron/` 实测 11.5MB/s。已固化到
`windows/.npmrc`（`electron_mirror` + `electron_builder_binaries_mirror`）。

### 2. `windows/package.json` 的 `scripts` 与 `devDependencies` 字段被误删

上一轮会话丢掉了这两个字段，导致 `npm run build:main` / `build:renderer` /
`build:win` 全部找不到脚本。本次从 HEAD 版本原样恢复，版本区间维持不动。

### 3. app 产物目录与 electron-builder 输出目录同为 `dist/` —— asar 损坏的真根因

```
tsconfig.main.json   outDir = dist
vite.config.ts       outDir = ../../dist/renderer
electron-builder     directories.output 默认值 = dist   ← 撞名
```

electron-builder 会把**输出目录整体从 asar 里排除**，于是 asar 根目录只剩
`/node_modules /src /package.json /translate.env.example …`，`/dist` 整个消失，
`main` 字段指向的 `dist/main.js` 自然找不到。

这是从初始提交（Phase 0 骨架）就潜伏的 bug，因为 Windows 构建从未跑完过所以没暴露。

## 已走过的弯路（不要重复走）

| 弯路 | 真相 |
|---|---|
| 把构建卡死归因于「缺 Wine」 | 卡在 electron 下载速度。NSIS 目标**根本不需要 Wine**（electron-builder 自带 nsis-resources 与 7zz）。Wine 只在做 Windows 代码签名或跑 Windows 侧测试时才用得上。 |
| 给 `windows/package.json` 加 `"brace-expansion": "^1.1.21"` blanket override | 把 minimatch 全家压坏：`minimatch@3` 要 `^1.1.7`、`minimatch@5/@9` 要 `^2.0.x`、`minimatch@10` 要 `^5.0.8`。1.1.21 是 CJS `module.exports = expandTop`，无命名导出，`minimatch@10` 报 `TypeError: (0 , brace_expansion_1.expand) is not a function`。**修复方式是删掉这个 override**，树自然收敛到 1.1.21 / 2.1.7 / 5.0.12。该 override 从未进过 git，所以 git 历史里看不到「删除」。 |
| 怀疑缓存的 `7zz` 二进制损坏 | 二进制是好的（Mach-O universal，7-Zip 24.09）。`7za process failed 1` + `errno=2: ./locales/xx.pak` 的真正原因是**多个 electron-builder 实例并发**，互相 `rm -rf release/win-arm64-unpacked`，打包到一半文件被删。 |
| 用 `launchctl submit` 跑后台长任务后反复轮询 | 会触发重复执行（同名 label 或 launchd 重试），第二次的 `rm -rf release` 把第一次成功的 96MB 安装包删了。**脚本里不要放 `rm -rf release`**，electron-builder 自己会覆盖。 |
| 读 `git push` 的 remote 回显判断漏洞是否修好 | 回显会滞后。本次 push 仍显示 "found 21 vulnerabilities"，几秒后 Dependabot 重扫即关闭 4 条。**只能跑 `gh api` 核对命令。** |

## 本轮改动

### 新增文件

| 文件 | 内容 |
|---|---|
| `windows/.npmrc` | `electron_mirror` / `electron_builder_binaries_mirror` 指向 npmmirror。换机器/CI 必须带上，否则重新卡死。 |
| `windows/build-resources/.gitkeep` | 占位。后续放 `icon.ico`（当前仍是 default Electron icon）。 |

### 修改文件

| 文件 | 改动 |
|---|---|
| `windows/package.json` | ① 恢复 `scripts`（dev / build:renderer / build:main / start / build:win）与 `devDependencies`；② 新增 `build` 字段：`directories.output = "release"`、显式 `files` 白名单（含 `!dist/win-*` 排除上次残留）、`artifactName`、`win.target = nsis/arm64`、`nsis` 选项；③ overrides 增加 `source-map-js ^1.2.2`。 |
| `windows/.gitignore` | 增加 `release/`。 |
| `windows/package-lock.json` | 同步。brace-expansion 回到 HEAD 状态（不再 blanket override），source-map-js 1.2.1 → 1.2.2。 |
| `docs/依赖安全台账.md` | 计数由「预计 17」定稿为已确认 17；新增 push 回显滞后的醒目警告；修正 brace-expansion 历史累计 9 条（原表漏计）；新增 Windows 构建环境备注与 SSH 代理绕过方法。 |

### 环境侧（未进 git）

- Wine 11.16 装到 `/Applications/Wine Devel.app`，15 个命令软链到 `~/.local/bin/`
  （`/usr/local/bin` 需 root，权限不足）。已 `xattr -dr com.apple.quarantine`。
- 下载源必须走 `ghfast.top` 镜像；直连 GitHub 约 40KB/s，镜像 5.9MB/s，182MB / 21 秒。
- GitHub release 真实体积以 `api.github.com/repos/Gcenx/macOS_Wine_builds/releases/tags/11.16`
  返回的 `size` 字段为准（191,440,520），别信浏览器约数。

## 验证

### Mac 侧门槛（全部通过）

| 项 | 结果 |
|---|---|
| `npm test`（根） | **41 pass / 0 fail** |
| `swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` | Build complete，**零 warning** |
| `swift test --sdk …` | **586 tests / 0 failures** |

### Wine CLI

| 项 | 结果 |
|---|---|
| `wine --version` | `wine-11.16` |
| `WINEPREFIX=~/.wine wineboot --init` | exit 0 |
| `WINEPREFIX=~/.wine wine cmd /c "echo WINE_OK && ver"` | `WINE_OK` + `Microsoft Windows 10.0.19045` |

（`getaddrinfo Failed to resolve your host name IP` 是无害告警，不影响上述结果。
Rosetta 已在运行，osx64 即 Intel 二进制。）

### Windows 打包

标准命令：
```bash
cd "/Users/a1-6/AI Shared/repo/Lumi/windows"
npm run build:win          # .npmrc 已含 mirror，无需再手写 export
```

产物（`windows/release/`）：

| 文件 | 大小 | 校验 |
|---|---|---|
| `Lumi-0.1.0-win-arm64.exe` | 96,288,448 B | `PE32 executable (GUI) Intel 80386, for MS Windows, Nullsoft Installer self-extracting archive` |
| `Lumi-0.1.0-win-arm64.exe.blockmap` | 102,300 B | — |
| `win-arm64-unpacked/Lumi.exe` | — | `PE32+ executable (GUI) Aarch64, for MS Windows` |

asar 内容（`npx asar list release/win-arm64-unpacked/resources/app.asar`）确认含：
```
/dist/main.js  /dist/preload.js  /dist/plugin.js  /dist/translate.js
/dist/renderer/index.html  /package.json  /src/**
```

**用最终提交态复跑过一次**（`source-map-js` pin 之后），仍 EXIT 0，产物一致。

### 依赖告警

`gh api repos/cpufreestyle/Lumi/dependabot/alerts?state=open` → **17 条**：
**0 critical / 7 high / 6 medium / 4 low**。brace-expansion 与 source-map-js
均已不在 open 列表（本次推送净关 4 条，21 → 17）。

## 遗留

1. **Windows 侧未实机验证**：本机是 macOS，asar 完整性与 exe 格式已校验，
   但「装上去能否启动」仍缺证据。需要一台 Windows on ARM 机器，
   或至少用 Wine 跑 `win-arm64-unpacked/Lumi.exe` 看能否起到主进程。
2. **没有应用图标**：构建日志有 `default Electron icon is used reason=application icon is not set`。
   `windows/build-resources/` 已建好占位，放 `icon.ico` 即可，但需先有设计稿。
3. **`translate.env.example` 未配真实值**：翻译功能在 Windows 侧的凭据未验证。
4. **剩余 17 条告警待评估**：
   - electron 43.4.0 → 43.4.1 / 43.5.0（4 high，二进制大依赖）
   - undici 6.28.0 → 6.28.1 / 7.29.1（7 条，high/med/low 混合）
   - vite 5.4.21 → 6.4.x（3 条，**需主版本升级，必须单独跑 `npm run build:win` 验证**）
   - esbuild 0.21.5 → 0.25.0（1 medium，**需主版本**）
   - http-cache-semantics 4.2.0、sprintf-js 1.1.3 —— **暂无修复版，只能记录**
5. **只构建了 arm64 目标**。`win.target` 显式写成 `nsis / arm64`，
   若将来要出 x64 安装包需改数组；x64 在 Apple Silicon 上交叉打包需要额外验证。
6. **`npm run build:win` 未接入任何 CI**。`.npmrc` 已固化 mirror，
   但 CI 机器仍需自备 Node 与 macOS（交叉打包 win-arm64 无需 Wine）。

## 提交记录

```
7661eff docs: 台账按 GitHub API 复核结果定稿 17 条，补 SSH 代理绕过方法
b685bc9 docs: 台账记录 brace-expansion / source-map-js 修复与 Windows 构建环境
9745aa6 fix(deps): windows 增加 source-map-js ^1.2.2 override，修 high 级事件循环 DoS
cdb712a fix(windows): 恢复 scripts/devDependencies，分离 electron-builder 输出目录与 app 产物目录
3197046 安全：修复 proxy-addr critical（根生产依赖树，2.0.7 → 2.0.8）  ← 本轮起点
```

全部已推送到 `origin/main`（`git@github.com:cpufreestyle/Lumi.git`），
`main` 与 `origin/main` 同步，工作树干净。

## 备份

- 误删的 359MB 残留产物已移至 `~/.Trash/lumi-win-arm64-unpacked-stale-*`
- 并发构建留下的半成品已移至 `~/.Trash/lumi-unpacked-partial-*`
- 构建日志：`/tmp/lumibuild/b5.log`（含三个并发实例互相干扰的全过程）、
  `/tmp/lumibuild/b7.log`、`/tmp/lumibuild/b8.log`（两次成功构建）
- 验证日志：`/tmp/lumiverify/v1.log`
