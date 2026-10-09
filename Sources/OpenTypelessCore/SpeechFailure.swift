import Foundation

/// Only classified, local messages are persisted. Upstream bodies may contain private data.
public struct SpeechFailure: Error, LocalizedError, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case noText, temporary, account, request, invalidResponse }
    public let kind: Kind
    public let status: Int?
    public let cost: Double?

    public init(_ kind: Kind, status: Int? = nil, cost: Double? = nil) {
        self.kind = kind; self.status = status; self.cost = cost
    }

    public var permitsRecovery: Bool { kind == .noText || kind == .temporary || kind == .invalidResponse }
    public var errorDescription: String? {
        switch kind {
        case .noText: return "模型没有识别出文字。录音和已有原稿已保留，可检查后重试。"
        case .account:
            return status == 402 ? "OpenRouter 余额不足，请补充额度后重试。" : "API Key 无效或账户没有访问权限，请检查 OpenRouter 设置。"
        case .request: return "模型或请求格式不受支持，请检查模型设置后重试。"
        case .temporary:
            return status == 429 ? "模型请求过于频繁，请稍后重试。" : "网络或模型服务暂时不可用，录音和已有原稿已保留。"
        case .invalidResponse: return "无法读取模型返回的结果，录音和已有原稿已保留。"
        }
    }

    public static func classify(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        if error is DecodingError { return Self(.invalidResponse) }
        return Self(.temporary)
    }
}
