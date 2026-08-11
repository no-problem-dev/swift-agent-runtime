import LLMClient
import Foundation

/// Keeps a worker's conversation in the model's own message types, one conversation per context.
///
/// Rebuilding a conversation from the A2A task history instead loses type information: past tool
/// calls come back as plain assistant text, and a model shown that pattern imitates it — it
/// answers in prose where it should have called a tool. Holding the native transcript, tool calls
/// and results included, is what prevents that.
///
/// Conform to swap where history lives; the built-in store keeps it in memory only.
public protocol AgentHistoryStore: Sendable {
    /// Returns the stored conversation, or an empty array for a context never seen before.
    func history(for contextId: String) async -> [LLMMessage]
    /// Replaces the stored conversation wholesale. Called once per completed turn.
    func save(_ history: [LLMMessage], for contextId: String) async
}

/// The default store. Conversations live in memory and are lost when the process exits; it also
/// grows without bound, since nothing evicts a context once it has been seen.
public actor InMemoryAgentHistoryStore: AgentHistoryStore {
    private var histories: [String: [LLMMessage]] = [:]

    public init() {}

    public func history(for contextId: String) -> [LLMMessage] {
        histories[contextId] ?? []
    }

    public func save(_ history: [LLMMessage], for contextId: String) {
        histories[contextId] = history
    }
}
