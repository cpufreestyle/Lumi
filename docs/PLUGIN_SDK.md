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
- `updatedAt`：Unix 秒。**超过 30 秒未更新，Lumi 会标记该插件为「stale」**并提示「插件可能已退出」，务必周期性重写（含最新时间戳）。
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

解析时用 `URLComponents.queryItems` 取 `name`，不要自己切字符串：按钮标题可能含
`&`、`?`、`#`、`%` 等字符，宿主已按规范编码，只有 `queryItems` 能拿到完整原文。

### 写文件最佳实践

- 用 `atomic` 写法（先写临时文件再 rename），避免 Lumi 读到半截 JSON。
- 时间戳用 `Date().timeIntervalSince1970`（Swift）或 `date +%s`（shell）。
- 数据陈旧即停止更新；退出时**删除**该 JSON，让面板自然消失。

---

## 3.1 卸载行为（宿主权限边界）

卸载只能删掉 **Lumi 通过市场装进 `~/Library/Application Support/Lumi/Plugins/` 的副本**。

如果你是把 `.app` 手动丢进 `/Applications` 或 `~/Applications` 被发现的，
Lumi 不会删它——那是你自己的文件，宿主无权处理。此时点「卸载」会看到
类似「该插件位于 /Applications/Foo.app，非 Lumi 安装目录，请手动删除」的提示。

判断依据是发现插件时记录的 `bundlePath` 是否位于 `Plugins/` **之下**
（按路径分量比较，不是字符串前缀，`Plugins-evil/` 这类近似路径会被正确拒绝）。

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

## 6.1 面板健康状态（宿主侧诊断）

Lumi 会持续跟踪每个面板型插件的状态，并在「已安装」列表行尾用徽标显示，
点开面板也能在底部看到对应提示：

| 状态 | 列表徽标 | 含义 | 你该做什么 |
| --- | --- | --- | --- |
| live | 绿色实心圆点 | 面板数据正常且未陈旧 | 无需处理 |
| stale | 橙色时钟感叹号 | 数据超过 30 秒未更新 | 恢复周期性写入；若插件已退出则属预期 |
| malformed | 红色警告三角 | 面板文件存在但 JSON 解码失败 | 检查写入的 JSON 是否符合 `PluginPanelData` 结构 |
| noData | 灰色虚线圆 | manifest 声明了 `panel: true` 但从未写出文件 | 开始写 `PluginPanels/<id>.json` |

malformed 是本次新增的隔离：过去单个插件写坏 JSON 会让面板静默消失，
用户会误以为是 Lumi 的问题。现在宿主保留该插件的其它功能（点击唤起等），
只把它的面板标记为异常并说明原因。

## 6.2 诊断日志

宿主把插件子系统的关键事件写入 `~/Library/Logs/Lumi/plugin.log`
（与 `music.log` 同目录，单文件滚动，超过 512KB 截断重写）。

在 Lumi 插件面板顶栏点「诊断日志」可直接打开该文件。
用户反馈问题时，请把这份日志一起提供——它记录了扫描结果、
面板监听注册、以及每个面板的健康状态变化。

诊断入口常驻（9pt 低调文字按钮），不按「有异常才显示」——无异常时用户同样需要
知道入口在哪。但在有插件面板异常（stale / malformed / noData）时，入口旁会多出
一行橙色摘要（如「2 个插件面板异常」），点击即可打开日志定位到具体是哪个插件。

## 7. 常见问题

- **每个插件都要写版本号吗？** 强烈建议。在 `lumi-plugin.json` 里声明 `version`（如 `"1.0.0"`），Lumi 会在「已安装」列表显示 `v版本号`，市场也会据此判断「可更新」。没写版本号的插件在列表里只显示名称，且无法被更新检测识别。
- **面板不出现？** 确认 manifest 里 `panel` 为 `true` 且 `id` 与 JSON 文件名一致；重启 Lumi 让它重新扫描。
  仍不行就看 `~/Library/Logs/Lumi/plugin.log`，里面有扫描到的插件清单与注册的面板监听数。
- **面板显示「可能已退出」？** 你的进程停止写 JSON 超过 30 秒了，恢复写入即可。
- **面板显示「JSON 解码失败」？** 你写出的文件不符合 `PluginPanelData` 结构，
  先用 `bash Lumi/demo_panel.sh once` 生成一份正确样例对照。
- **图标是灰色拼图？** `iconName` 填的不是有效 SF Symbol 名，回退到了默认图标。
- **不想被自动发现？** 不写 `lumi-plugin.json` 即可；仅通过市场源分发则只在用户安装后出现。

---

## 8. 设计取舍

当前采用**共享目录文件桥接**而非 XPC：

- ✅ 任意第三方 app（含 ad-hoc / 免费账号签名）都能零阻力接入。
- ✅ 无需 App Group、无需签名授权文件、无反向调用压力（1s 轮询足够轻）。
- ⏳ XPC 双向通信（v2 计划）延迟更低、支持反向调用，但需要签名授权文件，对免费账号不友好；文件方案可在后续平滑升级。
