import AppKit
import CoreBluetooth
import IOBluetooth
import SwiftUI

struct LiveManualSettingsView: View {
    @ObservedObject private var detector = LiveDetectionController.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("手动设置环境状态")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(PanelInk.text(0.8))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(PanelInk.text(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Text("自动检测不准时，可手动覆盖每一项的状态与显示文本。")
                .font(.system(size: 10))
                .foregroundColor(PanelInk.text(0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(detector.detections) { item in
                        ManualRow(item: item)
                    }
                }
                .padding(.horizontal, 16)
            }

            Button(action: {
                // 清除全部手动设置
                for item in detector.detections { detector.clearManual(item.label) }
            }) {
                Text("清除全部手动设置")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(PanelInk.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 340, height: 460)
        .glassPanel(cornerRadius: 16, scrim: 0, stroke: 0.12)
    }
}
