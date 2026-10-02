import AppKit
import CoreBluetooth
import IOBluetooth
import SwiftUI

struct ManualRow: View {
    @ObservedObject private var detector = LiveDetectionController.shared
    let item: LiveDetectionController.DetectionItem
    /// 输入框文本以 controller 中的手动值为单一数据源。
    /// 不要用 @State 镜像 item.value：2 秒轮询刷新会重建该行并把用户
    /// 正在输入的内容重置回自动检测值。
    @State private var editingValue: String = ""
    @State private var didLoad = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .foregroundColor(item.active ? .pink : .white.opacity(0.5))
                    .frame(width: 20)

                Text(item.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(PanelInk.text(0.85))

                Spacer()

                // 状态开关
                Toggle("", isOn: Binding(
                    get: { item.active },
                    set: { detector.setManualActive(item.label, $0) }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: .pink))
                .scaleEffect(0.7)
            }

            // 手动数值输入
            HStack(spacing: 6) {
                TextField("显示文本（手动）", text: $editingValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(PanelInk.primary)
                    .padding(7)
                    .background(PanelInk.chip(0.08))
                    .cornerRadius(6)
                    .onSubmit { detector.setManualValue(item.label, editingValue) }

                Button(action: { detector.setManualValue(item.label, editingValue) }) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11))
                        .foregroundColor(PanelInk.text(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(PanelInk.chip(0.03))
        .cornerRadius(10)
        .onAppear {
            // 只在首次出现时填充初值，后续轮询刷新不覆盖用户输入
            guard !didLoad else { return }
            didLoad = true
            editingValue = detector.storedManualValue(item.label) ?? item.value
        }
    }
}
