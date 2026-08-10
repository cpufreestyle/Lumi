# Lumi 插件开发指南（SDK）

> 目标：任何第三方 macOS 应用，无需签名授权文件、无需编译进 Lumi，都能接入灵动岛面板。
> 约定的全部逻辑都在 `Lumi/Sources/Lumi/Core/Plugin/` 下（`PluginManifest` / `PluginDiscovery` / `PluginPanelBridge`）。

---

## 0. 三句话看懂

1. 在 app 包的 `Contents/Resources/lumi-plugin.json` 写一个声明文件，Lumi 启动即自动发现。
2. 想让面板显示内容，就往 `~/Library/Application Support/Lumi/PluginPanels/<id>.json` **周期性写文件**（L3）。
3. 想上架市场，把 app 打个 zip 放到可访问地址，并在某个 feed 里加一条记录。

---

## 1. 接入层级

| 层级 | 能力 | 必须做的 |
| --- | --- | --- |
| **L1 极简** | 点击即按 URL Scheme 唤起你的 app | 写 `lumi-plugin.json` + 声明 `urlScheme` |
| **L2 清单** | 统一图标 + 安装前权限透明告知 + 上架市场 | 在 L1 基础上补 `permissions` / `category` / `summary` |
| **L3 深度** | 把结构化面板内嵌进灵动岛（像原生模块） | 在 manifest 声明 `"panel": true` + 周期写 `PluginPanels/<id>.json` |

> L3 不依赖 L1：纯面板型插件可以不注册 URL Scheme。

---

## 2. 清单文件：`lumi-plugin.json`

放在 `<你的app>.app/Contents/Resources/lumi-plugin.json`。

### 字段

| 字段 | 类型 | 说明 | 必填 |
| --- | --- | --- | --- |
| `id` | String | 唯一标识，建议反向域名，如 `com.example.weather` | ✅ |
| `name` | String | 展示名 | ✅ |
| `iconName` | String | SF Symbol 名（如 `cloud.sun`）；缺省回退 `puzzlepiece` | ⭕ |
| `urlScheme` | String | 不含 `://`，如 `myapp`；点击即 `open("myapp://")` | L1 必填 |
| `appName` | String | 独立 .app 名（如 `MyApp.app`），用于本地发现/回退 open | ⭕ |
| `permissions` | [Permission] | 权限声明，用于安装前透明告知 | ⭕ |
| `panelHint` | String | 面板提示语 | ⭕ |
| `minHostVersion` | String | 最低宿主版本（语义化） | ⭕ |
| `panel` | Bool | `true` 启用 L3 深度集成 | L3 必填 |
| `version` | String | 语义化版本（如 `1.0.0`），用于市场「可更新」判断**与本地已安装列表展示** | **建议必填**（上架必填） |
| `category` | String | 市场分类：`工具`/`效率`/`娱乐`/`其它` | 上架必填 |
| `summary` | String | 一句话简介 | 上架必填 |
| `downloadURL` | URL | 市场下载地址（仅来自 feed，本地 manifest 一般不含） | 上架必填 |

`Permission` 结构：`{ "type": "network", "reason": "获取天气数据" }`。
`type` 可选：`accessibility` / `calendar` / `contacts` / `network` / `screenRecord` / `none`。

### L1 最小示例

```json
{
  "id": "com.example.bartender",
  "name": "Bartender",
  "iconName": "menubar.dock.rectangle",
  "urlScheme": "bartender",
  "appName": "Bartender.app",
  "version": "1.0.0"
}
```

### L3 示例

```json
{
  "id": "com.example.weather",
  "name": "我的天气",
  "iconName": "cloud.sun",
  "urlScheme": "myweather",
  "panel": true,
  "version": "1.0.0",
  "category": "效率",
  "summary": "在灵动岛显示实时天气",
  "permissions": [{ "type": "network", "reason": "获取天气数据" }]
}
```

---

## 3. L3 面板数据：`PluginPanels/<id>.json`

Lumi 每 **1 秒**轮询 `~/Library/Application Support/Lumi/PluginPanels/`，发现带 `panel: true` 的插件后自动在标签栏追加其面板。

> 你的插件 **只需写文件**，无需调用 Lumi 任何 API、无需 XPC/App Group。

### 文件结构（`PluginPanelData`）

```json
{
  "id": "com.example.weather",
  "title": "我的天气",
  "iconName": "cloud.sun",
  "subtitle": "上海 · 实时",
  "updatedAt": 1700000000,
  "lines": [
    { "kind": "kv",      "key": "现在",   "value": "晴 24°C" },
    { "kind": "progress",              "p": 0.5 },
    { "kind": "button",  "title": "刷新天气" },
    { "kind": "text",                 "value": "今晚转多云" }
  ]
}
```

- `id`：与 manifest 一致，同时用作文件名去重键。
- `updatedAt`：Unix 秒。**超过 30 秒未更新，Lumi 会提示「插件可能已退出」**，务必周期性重写（含最新时间戳）。
- `lines` 支持四种 `kind`：
  - `text`：纯文本行（`value`）
  - `kv`：键值对（`key` + `value`）
  - `progress`：进度条（`p` 取 0~1）
  - `button`：按钮（`title`）

### 按钮回调

用户点面板里的 `button` 时，Lumi 会向你的 `urlScheme` 发：

```text
myweather://action?name=<按钮标题>
```

你的 app 实现 URL Scheme 处理（macOS `NSAppleEventManager` / SwiftUI `.onOpenURL`）即可响应。

### 写文件最佳实践

- 用 `atomic` 写法（先写临时文件再 rename），避免 Lumi 读到半截 JSON。
- 时间戳用 `Date().timeIntervalSince1970`（Swift）或 `date +%s`（shell）。
- 数据陈旧即停止更新；退出时**删除**该 JSON，让面板自然消失。

---

## 4. 本地发现目录

Lumi 启动时扫描以下位置，读取每个 `.app` 内的 `lumi-plugin.json`：

- `/Applications`
- `~/Applications`
- `~/Library/Application Support/Lumi/Plugins`（**市场下载目录，推荐放这里**）

把自己打包好的 `.app` 丢进上述任一目录，重启 Lumi 即可看到插件。

---

## 5. 上架插件市场

让用户的 Lumi 在市场列表里看到并一键安装你的插件：

1. 把你的 app 打包成 `YourPlugin.app.zip`。
2. 在一个可公开访问的 feed（`plugin-feed.json` 同结构）里加一条：

   ```json
   {
     "id": "com.example.weather",
     "name": "我的天气",
     "version": "1.0.0",
     "category": "效率",
     "summary": "在灵动岛显示实时天气",
     "downloadURL": "https://your-cdn.com/YourPlugin.app.zip",
     "permissions": [{ "type": "network", "reason": "获取天气数据" }]
   }
   ```

3. 用户在自己 Lumi 的「市场源」设置里添加你的 feed 地址即可（官方源恒开，社区源/自定义源用户可控）。
   - 也可以把条目提交给官方 feed（仓库 `Lumi/plugin-feed.json`），经审核后进入官方源。

> 安装流程：用户点「安装」→ Lumi 下载 zip → 解压 → `xattr -d` 去隔离 → 放入 `Plugins/` → 重新扫描 → 出现在标签栏。

---

## 6. 端到端示例：30 秒跑通一个 L3 面板

仓库内提供零编译的 shell 演示（不依赖 Swift 工具链）：

```bash
bash Lumi/demo_panel.sh start    # 每 3 秒写一次面板 JSON
bash Lumi/demo_panel.sh stop     # 停止并清理面板 JSON
```

启动后**重启 Lumi**，展开面板标签栏会出现「Demo 面板」标签，点开即看到实时刷新的卡片（含进度条与按钮）。按钮点击会向 `lumidemo://action?name=...` 回传——你可以用任意能处理 URL Scheme 的程序接收。

真实可编译的 Swift 示例插件见 `Lumi/make_sample_plugin.sh`（生成带可执行二进制的 `LumiSamplePlugin.app`）。

---

## 7. 常见问题

- **每个插件都要写版本号吗？** 强烈建议。在 `lumi-plugin.json` 里声明 `version`（如 `"1.0.0"`），Lumi 会在「已安装」列表显示 `v版本号`，市场也会据此判断「可更新」。没写版本号的插件在列表里只显示名称，且无法被更新检测识别。
- **面板不出现？** 确认 manifest 里 `panel` 为 `true` 且 `id` 与 JSON 文件名一致；重启 Lumi 让它重新扫描。
- **面板显示「可能已退出」？** 你的进程停止写 JSON 超过 30 秒了，恢复写入即可。
- **图标是灰色拼图？** `iconName` 填的不是有效 SF Symbol 名，回退到了默认图标。
- **不想被自动发现？** 不写 `lumi-plugin.json` 即可；仅通过市场源分发则只在用户安装后出现。

---

## 8. 设计取舍

当前采用**共享目录文件桥接**而非 XPC：

- ✅ 任意第三方 app（含 ad-hoc / 免费账号签名）都能零阻力接入。
- ✅ 无需 App Group、无需签名授权文件、无反向调用压力（1s 轮询足够轻）。
- ⏳ XPC 双向通信（v2 计划）延迟更低、支持反向调用，但需要签名授权文件，对免费账号不友好；文件方案可在后续平滑升级。
