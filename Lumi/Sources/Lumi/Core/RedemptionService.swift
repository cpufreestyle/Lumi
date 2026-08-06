import Foundation

/// 客户端「旧码换发」网络封装（对应 PRD 阶段一）。
/// 真实后端需部署 `POST /v1/redeem`（校验旧码 + 订单号，用私钥签发绑定设备的新码）。
/// 本结构体只负责请求与解析，不含任何私钥。
struct RedemptionService {
    enum RedemptionError: Error {
        case invalidResponse
        case server(Int, String)
        case network(Error)
    }

    let endpoint: URL

    /// 默认生产端点；若设置了 UserDefaults `lumi_redeem_endpoint`（本地/测试用）则优先使用。
    init(endpoint: URL? = nil) {
        if let endpoint {
            self.endpoint = endpoint
        } else if let override = UserDefaults.standard.string(forKey: "lumi_redeem_endpoint"),
                  let u = URL(string: override.trimmingCharacters(in: .whitespacesAndNewlines)),
                  u.scheme != nil {
            self.endpoint = u
        } else {
            self.endpoint = URL(string: "https://api.lumi.app/v1/redeem")!
        }
    }

    /// 将后端错误转换为用户友好提示
    static func errorMessage(_ err: RedemptionError) -> String {
        switch err {
        case .invalidResponse:
            return "服务器响应异常，请稍后重试或联系 support@lumi.app。"
        case .server(let code, let msg):
            return "换发失败（\(code)）：\(msg)"
        case .network:
            return "无法连接换发服务。可填入本地测试地址，或联系 support@lumi.app 人工换发。"
        }
    }

    /// 请求换发新激活码
    /// - Parameters:
    ///   - oldKey: 用户持有的旧版 `LUMI-XXXX-...` 激活码
    ///   - order: 购买订单号（凭证）
    ///   - deviceId: 本机设备标识（见 `DeviceId`），由服务端写入新码 `dev` 字段
    func redeem(oldKey: String, order: String, deviceId: String,
                completion: @escaping (Result<String, RedemptionError>) -> Void) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "oldKey": oldKey,
            "order": order,
            "device": deviceId,
            "nonce": UUID().uuidString
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(.network(err))); return }
            guard let http = resp as? HTTPURLResponse else {
                completion(.failure(.invalidResponse)); return
            }
            guard let data, let message = String(data: data, encoding: .utf8) else {
                completion(.failure(.invalidResponse)); return
            }
            if (200..<300).contains(http.statusCode) {
                completion(.success(message.trimmingCharacters(in: .whitespacesAndNewlines)))
            } else {
                completion(.failure(.server(http.statusCode, message)))
            }
        }.resume()
    }
}
