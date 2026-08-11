import React, { useEffect, useState } from "react";

/**
 * 桌面歌词悬浮窗(对齐 Mac 版 CollapsedView 的双语双色显示)。
 * 原文(上,红) + 译文(下,青),与 Mac 版一致。
 * Phase 0:内置示例歌词,验证翻译后端一行双语跑通。
 */

// 示例原文(后续由主进程 SMTC+lrclib 注入)
const SAMPLE_ORIGINAL = "我怀念的 在彼此眼中找勇气";

export function LyricOverlay() {
  const [original, setOriginal] = useState(SAMPLE_ORIGINAL);
  const [translation, setTranslation] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    let cancelled = false;
    async function run() {
      setLoading(true);
      try {
        const tr = await (window as any).lumi.translateLine(original, "zh");
        if (!cancelled) setTranslation(tr || "（翻译中）");
      } catch {
        if (!cancelled) setTranslation("（翻译失败）");
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    run();
    return () => {
      cancelled = true;
    };
  }, [original]);

  return (
    <div
      style={{
        height: "100vh",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontFamily: "system-ui, -apple-system, sans-serif",
      }}
    >
      {/* 黑色胶囊(对齐 Mac 版黑岛) */}
      <div
        style={{
          background: "rgba(0,0,0,0.92)",
          borderRadius: 18,
          padding: "10px 18px",
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          gap: 2,
          boxShadow: "0 8px 30px rgba(0,0,0,0.5)",
          cursor: "move",
          userSelect: "none",
          maxWidth: 380,
        }}
      >
        {/* 原文(红) */}
        <div
          style={{
            color: "#ff3b30",
            fontSize: 22,
            fontWeight: 600,
            textShadow: "0 1px 3px rgba(0,0,0,0.7)",
            whiteSpace: "nowrap",
            overflow: "hidden",
            textOverflow: "ellipsis",
            maxWidth: 340,
          }}
        >
          {original}
        </div>
        {/* 译文(青) */}
        <div
          style={{
            color: "#32d4ff",
            fontSize: 16,
            fontWeight: 400,
            textShadow: "0 1px 3px rgba(0,0,0,0.7)",
            whiteSpace: "nowrap",
            overflow: "hidden",
            textOverflow: "ellipsis",
            maxWidth: 340,
            opacity: loading ? 0.6 : 1,
          }}
        >
          {translation ?? "（翻译中…）"}
        </div>
      </div>
    </div>
  );
}
