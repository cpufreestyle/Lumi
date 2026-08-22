import SwiftUI

// MARK: - 付费功能锁定遮罩
struct PremiumLockOverlay: View {
    let module: AppModule
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var state = AppState.shared

    var body: some View {
        ZStack {
            // 毛玻璃效果背景
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.6))

            VStack(spacing: 16) {
                // 锁图标
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(
                        LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )

                VStack(spacing: 6) {
                    Text("此功能需要激活")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)

                    if let feature = module.premiumFeature {
                        Text(feature.description)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                }

                VStack(spacing: 10) {
                    // 试用按钮
                    Button(action: {
                        license.startTrial()
                    }) {
                        Text("免费试用 7 天")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 180)
                            .padding(.vertical, 10)
                            .background(
                                LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(license.status != .unlicensed)

                    // 激活按钮
                    Button(action: {
                        state.showLicensePanel = true
                    }) {
                        Text("输入激活码")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 180)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }

                // 试用状态提示
                if case .trial(let days) = license.status {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text("试用剩余 \(days) 天")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }
        }
        .cornerRadius(22)
    }
}

// MARK: - 许可证管理面板
struct LicensePanelView: View {
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var state = AppState.shared
    @State private var activationKey: String = ""
    @FocusState private var isKeyFocused: Bool

    // 旧版激活码换发（自助迁移）
    @State private var showRedeem = false
    @State private var oldKeyInput: String = ""
    @State private var orderInput: String = ""
    @State private var endpointOverride: String = ""
    @State private var redeemLoading = false
    @State private var redeemError: String?
    @State private var redeemMessage: String?
    @State private var showDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            HStack {
                Text("激活 Lumi")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Button(action: { state.showLicensePanel = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .onAppear { license.refreshRevocations() }

            // 当前状态
            licenseStatusCard
                .padding(.horizontal, 16)

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 12)

            // 功能列表
            VStack(alignment: .leading, spacing: 8) {
                Text("付费功能")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 16)

                ForEach(PremiumFeature.allCases) { feature in
                    HStack(spacing: 10) {
                        Image(systemName: feature.icon)
                            .font(.system(size: 12))
                            .foregroundColor(license.isUnlocked(feature) ? .green : .white.opacity(0.35))
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.rawValue)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                            Text(feature.description)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                        }

                        Spacer()

                        if license.isUnlocked(feature) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.green)
                        } else {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 12)

            // 激活码输入
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    TextField("LUMI-XXXX-XXXX-XXXX-XXXX", text: $activationKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                        .focused($isKeyFocused)
                        .onChange(of: activationKey) { _, newVal in
                            // 自动格式化
                            let uppered = newVal.uppercased()
                            if uppered != newVal {
                                activationKey = uppered
                            }
                        }

                    if license.isActivating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 20, height: 20)
                    }
                }
                .padding(.horizontal, 16)

                if let error = license.activationError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.8))
                        .padding(.horizontal, 16)
                }

                Button(action: {
                    license.activate(with: activationKey)
                }) {
                    Text("验证激活码")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            activationKey.count >= 19
                                ? AnyShapeStyle(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing))
                                : AnyShapeStyle(Color.white.opacity(0.1))
                        )
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .disabled(activationKey.count < 19 || license.isActivating)
            }

            // 旧版激活码自助换发入口
            VStack(spacing: 8) {
                Button(action: { withAnimation { showRedeem.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                        Text(showRedeem ? "收起换发" : "我有旧版激活码？免费换发新码")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.pink.opacity(0.9))
                }
                .buttonStyle(.plain)

                if showRedeem {
                    VStack(spacing: 8) {
                        TextField("旧版激活码 LUMI-XXXX-XXXX-XXXX-XXXX", text: $oldKeyInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(8)
                            .onChange(of: oldKeyInput) { _, v in
                                let up = v.uppercased(); if up != v { oldKeyInput = up }
                            }
                        TextField("购买订单号（凭证）", text: $orderInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(8)
                        TextField("后端地址（可选，留空用默认）", text: $endpointOverride)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(8)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(8)

                        if let msg = redeemMessage {
                            Text(msg).font(.system(size: 10)).foregroundColor(.green.opacity(0.9))
                                .padding(.horizontal, 4)
                        }
                        if let err = redeemError {
                            Text(err).font(.system(size: 10)).foregroundColor(.red.opacity(0.85))
                                .padding(.horizontal, 4)
                        }

                        Button(action: performRedeem) {
                            HStack(spacing: 6) {
                                if redeemLoading {
                                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                                }
                                Text(redeemLoading ? "换发中…" : "换发并激活本机")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                canRedeem
                                ? AnyShapeStyle(LinearGradient(colors: [Color.pink, Color.purple], startPoint: .leading, endPoint: .trailing))
                                : AnyShapeStyle(Color.white.opacity(0.1))
                            )
                            .cornerRadius(9)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canRedeem || redeemLoading)

                        Text("换发后新码将绑定本机设备，不可转借他人。")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)

            // 试用按钮
            if case .unlicensed = license.status {
                Button(action: { license.startTrial() }) {
                    Text("开始 7 天免费试用")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.pink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.pink.opacity(0.1))
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            // 本地诊断数据（可观测性，仅本机 UserDefaults，不上报）
            DisclosureGroup("本地诊断数据", isExpanded: $showDiagnostics) {
                let snap = Telemetry.shared.snapshot()
                VStack(alignment: .leading, spacing: 4) {
                    Text("激活次数：\(snap.activations)（其中设备绑定 \(snap.deviceBoundActivations)）")
                        .font(.system(size: 10))
                    Text("换码尝试：\(snap.redeemAttempts)　成功：\(snap.redeemSuccesses)　失败：\(snap.redeemFailures)")
                        .font(.system(size: 10))
                    if !snap.failureBreakdown.isEmpty {
                        Text("失败原因分布：")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                        ForEach(snap.failureBreakdown.indices, id: \.self) { i in
                            let item = snap.failureBreakdown[i]
                            Text("  • \(item.reason)：\(item.count)")
                                .font(.system(size: 10))
                        }
                    }
                }
                .foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .padding(.bottom, 14)
        // 比展开面板(360)窄一圈，配合外层垂直 padding 使浮层四周留白均匀，
        // 不会顶到容器边缘产生"多余外框"观感
        .frame(width: 336)
    }

    private var canRedeem: Bool {
        !oldKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !orderInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func performRedeem() {
        let oldKey = oldKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let order = orderInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldKey.isEmpty, !order.isEmpty else {
            redeemError = "请填写旧激活码与订单号"
            return
        }
        redeemLoading = true
        redeemError = nil
        redeemMessage = nil
        Telemetry.shared.record(.redeemAttempt)

        let resolved: URL
        let override = endpointOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty, let u = URL(string: override), u.scheme != nil {
            resolved = u
        } else {
            resolved = RedemptionService().endpoint
        }

        // 调用后端换发：私钥仅在服务端，本机只收到已签名的 LUMI2- 新码
        RedemptionService(endpoint: resolved).redeem(oldKey: oldKey, order: order, deviceId: DeviceId.current) { result in
            DispatchQueue.main.async {
                self.redeemLoading = false
                switch result {
                case .success(let newCode):
                    Telemetry.shared.record(.redeemSuccess)
                    // 新码已绑定本机 DeviceId，直接激活
                    self.license.activate(with: newCode)
                    self.redeemMessage = "✅ 换发成功，已自动激活本机。"
                    self.oldKeyInput = ""
                    self.orderInput = ""
                case .failure(let err):
                    Telemetry.shared.recordRedeemFailure(reason: Self.redeemFailureReason(err))
                    self.redeemError = RedemptionService.errorMessage(err)
                }
            }
        }
    }

    private static func redeemFailureReason(_ err: RedemptionService.RedemptionError) -> String {
        switch err {
        case .network:
            return "网络错误"
        case .invalidResponse:
            return "响应异常"
        case .server(let code, _):
            switch code {
            case 400: return "业务拒绝"
            default:  return "服务端错误(\(code))"
            }
        }
    }

    @ViewBuilder
    var licenseStatusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 24))
                .foregroundColor(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(statusSubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()

            Button(action: { license.refreshRevocations() }) {
                Text("重新检查")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
    }

    var statusIcon: String {
        switch license.status {
        case .unlicensed: return "lock.shield"
        case .trial:      return "clock.badge.checkmark"
        case .licensed:   return "checkmark.shield"
        case .lifetime:   return "crown.fill"
        case .revoked:    return "xmark.shield.fill"
        }
    }

    private var isExpiringSoon: Bool {
        if case .licensed(let expiry) = license.status, let date = expiry {
            let remaining = date.timeIntervalSinceNow
            return remaining > 0 && remaining < 7 * 24 * 3600
        }
        return false
    }

    var statusColor: Color {
        switch license.status {
        case .unlicensed: return .orange
        case .trial:      return .blue
        case .licensed:   return isExpiringSoon ? .orange : .green
        case .lifetime:   return .yellow
        case .revoked:    return .red
        }
    }

    var statusTitle: String {
        switch license.status {
        case .unlicensed:                    return "未激活"
        case .trial:                         return "试用中"
        case .licensed:                      return "已激活"
        case .lifetime:                      return "永久许可"
        case .revoked:                       return "已吊销"
        }
    }

    var statusSubtitle: String {
        switch license.status {
        case .unlicensed:
            return "激活后解锁全部高级功能"
        case .trial(let days):
            return "试用剩余 \(days) 天，到期后需激活继续使用"
        case .licensed(let expiry):
            if let date = expiry {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                let base = "有效期至 \(f.string(from: date))"
                return isExpiringSoon ? base + "（即将到期，请尽快续费）" : base
            }
            return "已激活"
        case .lifetime:
            return "永久有效，畅享全部功能"
        case .revoked:
            return "激活码已被吊销，请重新激活或联系 support@lumi.app"
        }
    }
}
