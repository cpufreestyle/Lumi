import { contextBridge, ipcRenderer } from "electron";
import { TargetLang } from "./translate";

contextBridge.exposeInMainWorld("lumi", {
  translateLine: (text: string, target: TargetLang) =>
    ipcRenderer.invoke("translate:line", text, target) as Promise<string | null>,
  getConfig: () => ipcRenderer.invoke("translate:config"),
});
