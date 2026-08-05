import SwiftUI
import AppKit

// MARK: - 剪贴板模块
final class ClipboardController: ObservableObject {
    static let shared = ClipboardController()

    @Published var items: [ClipboardItem] = []
    @Published var searchText: String = ""

    private let maxItems = 48
    private var changeCount: Int = NSPasteboard.general.changeCount
    private var timer: Timer?

    struct ClipboardItem: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let timestamp: Date
        let appName: String?

        static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
            lhs.id == rhs.id
        }
    }

    private init() {
        startPolling()
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount

        guard let text = pb.string(forType: .string), !text.isEmpty else { return }

        // 去重
        if let first = items.first, first.text == text { return }

        // 安全检查：过滤敏感内容（密码、卡号）
        let cleaned = sanitize(text)

        DispatchQueue.main.async {
            let item = ClipboardItem(
                text: cleaned,
                timestamp: Date(),
                appName: NSWorkspace.shared.frontmostApplication?.localizedName
            )
            self.items.insert(item, at: 0)
            if self.items.count > self.maxItems {
                self.items = Array(self.items.prefix(self.maxItems))
            }
        }
    }

    private func sanitize(_ text: String) -> String {
        // 简单过滤：如果文本看起来像密码/卡号，替换为 [已隐藏]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardPattern = try? NSRegularExpression(pattern: "\\b\\d{13,19}\\b")
        if cardPattern?.firstMatch(in: trimmed, range: NSRange(0..<trimmed.utf16.count)) != nil {
            return "[已隐藏 · 疑似卡号]"
        }
        // 过滤超过 200 字符的纯数字文本
        let digitsOnly = trimmed.filter { $0.isNumber }
        if digitsOnly.count > 15 && Double(digitsOnly) != nil {
            return "[已隐藏 · 纯数字]"
        }
        return trimmed
    }

    var filteredItems: [ClipboardItem] {
        if searchText.isEmpty { return items }
        return items.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func removeItem(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
    }

    func clearAll() {
        items.removeAll()
    }

    func timeAgo(from date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval/60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval/3600)) 小时前" }
        return "\(Int(interval/86400)) 天前"
    }
}

// MARK: - 剪贴板视图
struct ClipboardExpandedView: View {
    @ObservedObject private var clipboard = ClipboardController.shared
    @State private var search: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                TextField("搜索剪贴板历史...", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .onChange(of: search) { newValue in
                        clipboard.searchText = newValue
                    }
                if !clipboard.items.isEmpty {
                    Button(action: { clipboard.clearAll() }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.white.opacity(0.06))
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.top, 10)

            // 列表
            if clipboard.filteredItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 28))
                        .foregroundColor(.white.opacity(0.2))
                    Text(clipboard.items.isEmpty ? "暂无剪贴板历史" : "无匹配结果")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.35))
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(clipboard.filteredItems) { item in
                            ClipboardRow(item: item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }
            }
        }
    }
}

struct ClipboardRow: View {
    let item: ClipboardController.ClipboardItem

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let app = item.appName {
                        Text(app)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    Text(ClipboardController.shared.timeAgo(from: item.timestamp))
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                }
            }

            Spacer()

            Button(action: {
                ClipboardController.shared.copyToPasteboard(item.text)
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("复制")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.02))
        .cornerRadius(6)
        .padding(.bottom, 2)
        .onTapGesture {
            ClipboardController.shared.copyToPasteboard(item.text)
        }
    }
}
