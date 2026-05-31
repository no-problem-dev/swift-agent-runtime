import Foundation

public enum AgentRuntimeError: Error, Sendable, Equatable, LocalizedError {
    case unknownAgent(String)

    public var errorDescription: String? {
        switch self {
        case .unknownAgent(let name): "Unknown agent: \(name)"
        }
    }
}
