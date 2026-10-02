import AppKit
import CoreBluetooth
import IOBluetooth
import SwiftUI

struct LiveDetectionBriefContent: View {
    @ObservedObject private var detector = LiveDetectionController.shared

    var body: some View {
        let activeCount = detector.detections.filter { $0.active }.count
        return Text("🟢 \(activeCount) 项活跃")
            .font(.system(size: 12))
            .foregroundColor(PanelInk.text(0.7))
    }
}
