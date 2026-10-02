import Foundation

/// URL 查询参数的严格编码（纯逻辑，Foundation only，可进 LumiTests）。
///
/// 为什么不用 `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`：
/// 该字符集**不编码** `+` `&` `=` 等字符，而它们在查询串里有特殊语义。
/// 实测确认三类真实失败：
/// - `A+B` 保持 `A+B`，服务端解码成 `A B` → 搜不到「A+B」这首歌
/// - `a&b=c` 保持原样，`&` 与 `=` 会**破坏查询参数结构** → 畸形请求
/// - `AC/DC` 的 `/` 虽多被容忍，但同样不该出现在查询值里
///
/// 这里改用「白名单」：只放行无条件安全的字符，其余一律编码。
enum QueryEncoding {

    /// 编码一个查询参数的值。
    static func encode(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if isUnreserved(scalar) {
                out.append(scalar)
            } else {
                // UTF-8 逐字节 %XX
                for byte in Array(String(scalar).utf8) {
                    out.append("%")
                    out.append(hexDigit(byte >> 4))
                    out.append(hexDigit(byte & 0x0F))
                }
            }
        }
        return String(out)
    }

    /// RFC 3986 的 unreserved 集合：字母、数字、`-` `.` `_` `~`。
    /// 这些字符在查询值里无歧义，放行；其余（含空格、`+`、`&`、`#` 等）一律编码。
    private static func isUnreserved(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if (0x30...0x39).contains(v) { return true }   // 0-9
        if (0x41...0x5A).contains(v) { return true }   // A-Z
        if (0x61...0x7A).contains(v) { return true }   // a-z
        return v == 0x2D || v == 0x2E || v == 0x5F || v == 0x7E // - . _ ~
    }

    private static func hexDigit(_ v: UInt8) -> Unicode.Scalar {
        // ASCII 十六进制位：直接由码点构造，不经过 String 中转
        let code = v < 10 ? (0x30 + v) : (0x41 + v - 10)
        return Unicode.Scalar(UInt32(code))!
    }
}
