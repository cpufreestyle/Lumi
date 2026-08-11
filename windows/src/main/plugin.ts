/**
 * 插件市场桥接 —— 对齐 Mac 版 PluginMarketplace / PluginPanelBridge。
 *
 * - feed 格式完全复用 Mac 版 plugin-feed.json(PluginManifest 字段对齐)。
 * - 文件桥接:%APPDATA%/Lumi/PluginPanels/<id>.json(主进程每 1s 轮询),
 *   渲染进程用 iframe 加载插件面板(等价 Mac 的 PluginPanelBridge)。
 *
 * Phase 0:实现 feed 拉取 + 版本比较;桥接轮询在 Phase 2 接入渲染面板。
 */

import * as fs from "fs";
import * as path from "path";
import * as os from "os";

export interface PluginPermission {
  type: string;
  reason: string;
}

export interface PluginManifest {
  id: string;
  name: string;
  iconName?: string;
  urlScheme?: string;
  appName?: string;
  panelHint?: string;
  minHostVersion?: string;
  downloadURL?: string;
  permissions?: PluginPermission[];
}

export interface PluginFeed {
  schemaVersion: number;
  plugins: PluginManifest[];
}

const DEFAULT_FEED_URL =
  "https://raw.githubusercontent.com/cpufreestyle/Lumi/main/Lumi/plugin-feed.json";

function panelDir(): string {
  const base =
    process.platform === "win32"
      ? process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming")
      : path.join(os.homedir(), "Library", "Application Support");
  return path.join(base, "Lumi", "PluginPanels");
}

export function isVersion(actual: string, newerThan: string): boolean {
  const a = actual.split(".").map((n) => parseInt(n, 10) || 0);
  const b = newerThan.split(".").map((n) => parseInt(n, 10) || 0);
  const len = Math.max(a.length, b.length);
  for (let i = 0; i < len; i++) {
    const x = a[i] || 0;
    const y = b[i] || 0;
    if (x > y) return true;
    if (x < y) return false;
  }
  return false; // 相等
}

export async function fetchFeed(url = DEFAULT_FEED_URL): Promise<PluginFeed> {
  try {
    const r = await fetch(url);
    if (r.ok) return (await r.json()) as PluginFeed;
  } catch {
    // 网络失败回退本地
  }
  // 离线回退:从打包资源读(若存在)
  return { schemaVersion: 1, plugins: [] };
}

/**
 * 读取某插件已桥接的面板 JSON(对齐 Mac PluginPanelBridge)。
 * 返回 null 表示该插件暂无面板数据(渲染进程应显示占位)。
 */
export function readPanel(id: string): any | null {
  const p = path.join(panelDir(), `${id}.json`);
  try {
    const txt = fs.readFileSync(p, "utf8");
    return JSON.parse(txt);
  } catch {
    return null;
  }
}

/**
 * 轮询所有已安装插件的面板数据(主进程 1s 一次)。
 * 对齐 Mac:PluginPanelBridge 每 1s 轮询文件桥接。
 */
export function pollPanels(ids: string[]): Record<string, any> {
  const out: Record<string, any> = {};
  for (const id of ids) {
    const data = readPanel(id);
    if (data) out[id] = data;
  }
  return out;
}
