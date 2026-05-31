import Foundation

/// AgentRuntime のエラー。
public enum AgentRuntimeError: Error, Sendable, Equatable, LocalizedError {
    /// 未登録のワーカー名が指定された。
    case unknownAgent(String)

    public var errorDescription: String? {
        switch self {
        case .unknownAgent(let name): "Unknown agent: \(name)"
        }
    }
}
