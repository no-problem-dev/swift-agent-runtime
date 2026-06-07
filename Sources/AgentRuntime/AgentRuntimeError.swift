import Foundation

public enum AgentRuntimeError: Error, Sendable, Equatable, LocalizedError {
    case unknownAgent(String)
    /// ルーター型ホストで転送先を決定できなかった（transfer_to_agent 呼び出し欠落・引数不正）。
    case routingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownAgent(let name): "Unknown agent: \(name)"
        case .routingFailed(let reason): "Routing failed: \(reason)"
        }
    }
}
