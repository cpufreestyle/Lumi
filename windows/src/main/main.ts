import { app, BrowserWindow, Tray, Menu, nativeImage, ipcMain } from "electron";
import * as path from "path";
import { translateLine, loadTranslateConfig, TargetLang } from "./translate";

// 单实例(对齐用户"只留一个"的偏好)
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
  process.exit(0);
}

let overlayWin: BrowserWindow | null = null;
let tray: Tray | null = null;

const isDev = !app.isPackaged;

function createOverlayWindow() {
  overlayWin = new BrowserWindow({
    width: 420,
    height: 90,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    resizable: true,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, "preload.js"),
    },
  });

  if (isDev) {
    overlayWin.loadURL("http://localhost:5173");
  } else {
    overlayWin.loadFile(path.join(__dirname, "../renderer/index.html"));
  }

  // 桌面歌词悬浮窗:鼠标穿透(点击穿透到下方窗口),拖拽由渲染进程内部 handle 处理
  overlayWin.setIgnoreMouseEvents(true, { forward: true });
}

function createTray() {
  // 托盘图标:用纯色占位(实际项目应放 app.ico/png)
  const img = nativeImage.createFromBuffer(Buffer.from([]));
  tray = new Tray(img.isEmpty() ? nativeImage.createEmpty() : img);
  const contextMenu = Menu.buildFromTemplate([
    { label: "显示/隐藏歌词", click: () => overlayWin?.show() },
    { label: "退出 Lumi", click: () => app.quit() },
  ]);
  tray.setToolTip("Lumi for Windows");
  tray.setContextMenu(contextMenu);
}

// ---------- IPC:翻译桥接(渲染进程调用主进程翻译后端) ----------

ipcMain.handle("translate:line", async (_e, text: string, target: TargetLang) => {
  return translateLine(text, target);
});

ipcMain.handle("translate:config", async () => {
  return loadTranslateConfig();
});

app.whenReady().then(() => {
  createOverlayWindow();
  createTray();

  app.on("second-instance", () => {
    overlayWin?.show();
  });
});

app.on("window-all-closed", () => {
  // 托盘常驻,不退出
});
