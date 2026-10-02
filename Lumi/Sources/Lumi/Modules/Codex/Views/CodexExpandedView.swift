import SwiftUI

struct CodexExpandedView: View {
    @ObservedObject private var codex = CodexController.shared
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            HStack {
                Text("Codex")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(PanelInk.text(0.7))
                Spacer()
                Button(action: { codex.showSettings.toggle() }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(PanelInk.text(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // API Key 设置
            if codex.showSettings {
                VStack(spacing: 8) {
                    Text("OpenAI API Key")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(PanelInk.text(0.6))
                    HStack {
                        SecureField("sk-...", text: $codex.apiKey)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(PanelInk.primary)
                            .padding(8)
                            .background(PanelInk.chip(0.08))
                            .cornerRadius(6)
                        Button("保存") {
                            codex.saveAPIKey(codex.apiKey)
                            codex.showSettings = false
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(PanelInk.pink)
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(PanelInk.chip(0.04))
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            // 操作选择
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(CodexController.CodexAction.allCases) { action in
                        Button(action: { codex.selectedAction = action }) {
                            HStack(spacing: 4) {
                                Image(systemName: action.icon)
                                    .font(.system(size: 9))
                                Text(action.rawValue)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(codex.selectedAction == action ? .white : .white.opacity(0.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                codex.selectedAction == action
                                    ? AnyShapeStyle(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(PanelInk.chip(0.08))
                            )
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 8)

            // 输入区域
            VStack(alignment: .leading, spacing: 4) {
                Text("输入代码")
                    .font(.system(size: 10))
                    .foregroundColor(PanelInk.text(0.4))
                    .padding(.horizontal, 2)
                TextEditor(text: $codex.inputCode)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(PanelInk.primary)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 100)
                    .background(PanelInk.chip(0.06))
                    .cornerRadius(8)
                    .focused($isInputFocused)
            }
            .padding(.horizontal, 16)

            // 执行按钮
            Button(action: { codex.executeAction() }) {
                HStack {
                    if codex.isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    }
                    Text(codex.isLoading ? "处理中..." : codex.selectedAction.rawValue)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [Color.pink, Color.purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .disabled(codex.inputCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || codex.isLoading)

            // 输出区域
            if !codex.outputCode.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("结果")
                        .font(.system(size: 10))
                        .foregroundColor(PanelInk.text(0.4))
                        .padding(.horizontal, 2)
                    ScrollView {
                        Text(codex.outputCode)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(PanelInk.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(PanelInk.chip(0.06))
                    .cornerRadius(8)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            Spacer(minLength: 0)
        }
    }
}
