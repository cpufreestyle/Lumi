/**
 * 翻译后端 —— 对齐 Mac 版 MusicController.swift 的翻译逻辑。
 *
 * 默认后端:Google 公开接口(无需 key、无每日硬限额)。
 * 可选增强:阿里通义千问 qwen-plus(配置 LUMI_TRANSLATE_API_KEY + LUMI_FORCE_LLM=1 时优先)。
 * 任一通道失败互相回退。
 *
 * 配置来源:只认 translate.env 文件(绝对路径),不回退进程环境变量,
 * 避免 launchctl setenv 等残留污染(对齐 Mac 版 envValue 行为)。
 */

import * as fs from "fs";
import * as path from "path";
import * as os from "os";

// ---------- 配置读取(对齐 Mac 版 envValue) ----------

function translateEnvPath(): string {
  // Mac: ~/Library/Application Support/Lumi/translate.env
  // Win: %APPDATA%/Lumi/translate.env
  const base =
    process.platform === "win32"
      ? process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming")
      : path.join(os.homedir(), "Library", "Application Support");
  return path.join(base, "Lumi", "translate.env");
}

function readEnvFile(): Record<string, string> {
  const p = translateEnvPath();
  const out: Record<string, string> = {};
  try {
    const txt = fs.readFileSync(p, "utf8");
    for (const line of txt.split("\n")) {
      const m = line.match(/^\s*([\w.]+)\s*=\s*(.*)\s*$/);
      if (m) out[m[1]] = m[2].replace(/^['"]|['"]$/g, "");
    }
  } catch {
    // 文件不存在则用默认值,不回退进程环境变量
  }
  return out;
}

export interface TranslateConfig {
  apiKey: string;
  baseUrl: string;
  model: string;
  forceLLM: boolean;
}

export function loadTranslateConfig(): TranslateConfig {
  const env = readEnvFile();
  return {
    apiKey: env["LUMI_TRANSLATE_API_KEY"] || "",
    baseUrl: env["LUMI_TRANSLATE_BASE_URL"] || "https://dashscope.aliyuncs.com/compatible-mode/v1",
    model: env["LUMI_TRANSLATE_MODEL"] || "qwen-plus",
    forceLLM: (env["LUMI_FORCE_LLM"] || "0") === "1",
  };
}

// ---------- 通用 fetch 封装 ----------

async function httpGetJson(url: string): Promise<any> {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

async function httpPostJson(url: string, headers: Record<string, string>, body: any): Promise<any> {
  const r = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

// ---------- Google 公开翻译(默认后端) ----------

async function translateViaGoogle(text: string, target: string): Promise<string> {
  const q = encodeURIComponent(text);
  const url = `https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=${target}&dt=t&q=${q}`;
  const data = await httpGetJson(url);
  // 响应: [[[chunk, src, ...], ...], lang, ...]
  const translated = (data[0] as any[]).map((seg) => seg[0]).join("");
  return translated;
}

// ---------- 阿里通义千问(可选增强) ----------

async function translateViaLLM(text: string, target: string, cfg: TranslateConfig): Promise<string> {
  if (!cfg.apiKey) throw new Error("no LLM key");
  const prompt =
    target === "zh"
      ? `请将下面的歌词翻译成简体中文,只输出译文,不要解释:\n${text}`
      : `Translate the following lyrics into ${target}, output only the translation:\n${text}`;
  const data = await httpPostJson(
    `${cfg.baseUrl}/chat/completions`,
    { Authorization: `Bearer ${cfg.apiKey}` },
    {
      model: cfg.model,
      messages: [{ role: "user", content: prompt }],
      temperature: 0.3,
    }
  );
  return data.choices?.[0]?.message?.content?.trim() || "";
}

// ---------- 对外 API ----------

export type TargetLang = "zh" | "en";

/**
 * 翻译单行,带重试(对齐 Mac 版 translateWithRetry:最多 2 次)。
 * 默认优先 Google;若 forceLLM 且 key 有效则优先 LLM,失败回退 Google。
 */
export async function translateLine(
  text: string,
  target: TargetLang,
  attempt = 0
): Promise<string | null> {
  if (!text.trim()) return "";
  const cfg = loadTranslateConfig();
  const maxAttempt = 2;

  const tryGoogle = () => translateViaGoogle(text, target).catch(() => null);
  const tryLLM = () =>
    cfg.forceLLM && cfg.apiKey
      ? translateViaLLM(text, target, cfg).catch(() => null)
      : Promise.resolve(null);

  // 优先顺序:forceLLM ? LLM→Google : Google→LLM
  let result: string | null = null;
  if (cfg.forceLLM && cfg.apiKey) {
    result = (await tryLLM()) || (await tryGoogle());
  } else {
    result = (await tryGoogle()) || (await tryLLM());
  }

  if (result) return result;
  if (attempt < maxAttempt) {
    await new Promise((r) => setTimeout(r, 300));
    return translateLine(text, target, attempt + 1);
  }
  return null;
}

/**
 * 批量翻译(行级对齐),串行节流(对齐 Mac 版:批次间隔 ~0.3s)。
 * 失败行返回 null(调用方保留"翻译中",下轮补译)。
 */
export async function translateBatch(
  lines: string[],
  target: TargetLang,
  onProgress?: (i: number, result: string | null) => void
): Promise<(string | null)[]> {
  const out: (string | null)[] = new Array(lines.length).fill(null);
  for (let i = 0; i < lines.length; i++) {
    const r = await translateLine(lines[i], target);
    out[i] = r;
    onProgress?.(i, r);
    if (i < lines.length - 1) await new Promise((res) => setTimeout(res, 300));
  }
  return out;
}
