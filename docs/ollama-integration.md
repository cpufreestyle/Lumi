# 划词 AI 快驾：一键启用本机 Ollama（零配置 / 免费 / 离线）

> 建立时间：2026-09-26 ｜ 关联模块：`Modules/AIAssist`
> 对应本轮目标：**学习和调用开源项目，增加项目实用性**

## 1. 为什么是「调用」而不是「重写」

Ollama 是把开源权重模型（Llama / Gemma / Qwen 等）跑在本机的运行时，自带 OpenAI 兼容
入口 `/v1`。让 Lumi 的「划词 AI 快驾」支持它是零成本的：

- 模型下载、量化、推理、并发全由 Ollama 负责，Lumi 不碰任何模型细节；
- 走 Ollama 自己暴露的 HTTP 接口（`/api/tags` 探测、`/v1/chat/completions` 推理），
  Lumi 只多一个「本机提供商（Provider）」抽象与一段本就打通的 OpenAI 兼容调用；
- 对用户：免费、离线、无 API Key、无额度焦虑，复制一段文字即可翻译 / 总结 / 解释 / 改写。

> 同 `docs/tv-remote-atv-integration.md` 的原则：**接口朝上复用，不在 Lumi 里复制上游实现**。

## 2. 依赖的 HTTP API（默认 127.0.0.1:11434）

| 方法 | 路径 | 用途 | 备注 |
| --- | --- | --- | --- |
| GET | `/api/tags` | 本机已安装模型清单 | 含 size / details / capabilities，信息最全，用于探测与推荐 |
| POST | `/v1/chat/completions` | OpenAI 兼容推理 | 与 Lumi 既有链路一致，stream=true |

`GET /api/tags` 关键字段（一条 model）：

    name                    模型名，如 llama3.2-vision:latest
    size                    权重体积（字节），如 7816589186
    details.parameter_size  参数量，如 10.7B / 137M
    details.family          家族，如 mllama
    capabilities            能力数组，如 [tools, completion, vision]

`/v1/models` 也存在，但只返回 id、无规格，故探测一律用 `/api/tags`。

## 3. 三个必须知道的坑

1. **`capabilities` 是区分「能不能对话」的唯一可靠字段。** 本机常同时装着 embedding 模型
   （如 `nomic-embed-text`，137M，只算向量、不能对话）。`OllamaProvider.Model.isChatCapable`
   有 `capabilities` 时看是否含 `completion`；缺失时按名字兜底排除 `embed` / `rerank`。
   否则「一键启用」可能选中 embedding 模型，对话只会报错。
2. **`size` 可能是浮点脏数据。** JSON 里理论是整数，容错按 `NSNumber.int64Value` 取整，
   否则 `as? Int` 遇到 `274302450.0` 会直接 nil。
3. **规模择优用参数量而非体积。** 默认推荐取「可对话里参数最多」者——`scale` 优先
   `parameter_size`（支持 B/M 后缀），回退体积/1e9。同机 4 模型里 `llama3.2-vision`(10.7B)
   会被选中，而非 `gemma4`(8.0B)。

## 4. Lumi 侧分层

| 文件 | 职责 |
| --- | --- |
| `Models/OllamaProvider.swift` | 纯逻辑：URL 常量、`Model`、`/api/tags` 与 `/v1/models` 解析、择优、格式化（Foundation only，可单测） |
| `Controllers/AIAssistController.swift` | `OllamaState`、`refreshOllamaModels()`（GET /api/tags）、`useOllama()`（写 endpoint+model、清 Key）、PollingCoordinator 低频探测 |
| `Views/AIAssistExpandedView.swift` | 「启用本机 Ollama」按钮 + 状态行；onAppear 触发探测 |

边界：不落盘、不引入 Ollama SDK、不改动既有 OpenAI 兼容链路；本机场景清空远端 API Key
（`AIAssistSettings.setAPIKey("")`）以免误用外网额度。

## 5. 验证方式

- 单测：`cd Lumi && swift test`——`OllamaProviderTests` 用真实 curl 响应做样本，覆盖两套
  接口解析、embedding 过滤、择优、容错、格式化（本轮 +13，累计 166 全绿）。
- 依赖探测：`curl -s http://127.0.0.1:11434/api/tags` 应返回 4 个模型。
- 真机：展开「助手」面板 → 出现「启用本机 Ollama」→ 点按 → 「检测连接」应显示
  `连接正常 · 模型回复：收到`；对剪贴板文本点「翻译」应有流式输出。

## 6. 未做 / 后续

- 模型选择目前用「推荐模型」一键填入；`ready` 时可在端点设置给模型名换成 Picker
  （`ollamaState.models`）做显式选择。
- 首次加载大模型略慢（冷启动），探测超时设 5s、推理超时 120s。
- 可选：状态行显示每个模型的 subtitle（参数量 · 体积 · 视觉）。
