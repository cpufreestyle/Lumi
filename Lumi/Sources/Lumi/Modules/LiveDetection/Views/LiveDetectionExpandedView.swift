import AppKit
import CoreBluetooth
import IOBluetooth
import SwiftUI

struct LiveDetectionExpandedView: View {
    @ObservedObject private var detector = LiveDetectionController.shared

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题 + 手动设置按钮
            HStack {
                Text("环境检测")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(PanelInk.text(0.75))
                Spacer()
                Button(action: { detector.showManualSettings.toggle() }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13))
                        .foregroundColor(PanelInk.text(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(detector.categories, id: \.rawValue) { category in
                        categorySection(category)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .sheet(isPresented: $detector.showManualSettings) {
            LiveManualSettingsView()
        }
    }

    func categorySection(_ category: LiveDetectionController.DetectionItem.Category) -> some View {
        VStack(spacing: 0) {
            Text(category.rawValue)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(PanelInk.text(0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)

            ForEach(detector.items(for: category)) { item in
                detectionRow(item)
            }
        }
        .padding(.bottom, 8)
    }

    func detectionRow(_ item: LiveDetectionController.DetectionItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 13))
                .foregroundColor(item.active ? .pink : .white.opacity(0.5))
                .frame(width: 20)

            Text(item.label)
                .font(.system(size: 12))
                .foregroundColor(PanelInk.text(0.8))

            if item.manual {
                Image(systemName: "hand.draw")
                    .font(.system(size: 9))
                    .foregroundColor(PanelInk.orange)
            }

            Spacer()

            Text(item.value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(item.active ? .pink.opacity(0.9) : .white.opacity(0.5))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(item.manual ? Color.orange.opacity(0.06) : PanelInk.chip(0.02))
        .cornerRadius(6)
        .padding(.bottom, 2)
    }
}
