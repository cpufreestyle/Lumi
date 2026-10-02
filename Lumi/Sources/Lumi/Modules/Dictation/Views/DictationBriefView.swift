import SwiftUI

/// 收缩态副标题：一眼看出「麦克风占用状态 + 模型是否就绪」。
/// 录音/转写操作全部交给展开态——胶囊空间极小，不放任何按钮。
struct DictationBriefView: View {
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                .font(.system(size: 12))
                .foregroundColor(statusColor)
            Text(briefText)
                .font(.system(size: 12))
                .foregroundColor(PanelInk.text(0.7))
                .lineLimit(1)
        }
    }

    private var statusColor: Color {
        if dictation.isRecording { return .red }
        if dictation.isTranscribing { return .orange }
        if dictation.errorMessage != nil { return .orange }
        return dictation.isReady ? .green : .white.opacity(0.5)
    }

    private var briefText: String {
        if dictation.isRecording { return "录音中 \(dictation.recordSeconds)s · 再点一次停止" }
        if dictation.isTranscribing { return "转写中…" }
        if let error = dictation.errorMessage { return error }
        guard dictation.isReady else { return "语音听写 · 模型未就绪" }
        return "语音听写 · 就绪"
    }
}
