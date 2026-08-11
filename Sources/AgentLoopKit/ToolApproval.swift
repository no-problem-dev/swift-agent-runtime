import Foundation
import LLMTool

/// Marks a tool the user must approve before it runs.
///
/// A step that requests one of these stops before executing anything — including the tools in the
/// same batch that need no approval, so no partial work happens. The loop returns the transcript
/// with those calls still unresolved; collect the user's verdicts and call `run` again with the
/// same transcript and `pendingToolDecisions`.
public protocol ApprovalRequiringTool: Tool {
    /// Returns what to show the user, or `nil` to run immediately without asking.
    ///
    /// Deciding per call means a tool can require approval only for the destructive arguments.
    /// Async so the summary can resolve identifiers into names; it must not perform the action.
    func approvalRequest(from argumentsData: Data) async -> ToolApprovalRequest?
}

/// What the user is shown before a tool runs.
public struct ToolApprovalRequest: Sendable, Equatable {
    /// One line stating what will happen if approved.
    public var summary: String
    /// The individual items the action will touch, listed under the summary.
    public var details: [String]

    public init(summary: String, details: [String] = []) {
        self.summary = summary
        self.details = details
    }
}

/// The user's verdict on a tool call that is waiting for approval.
public enum ToolApprovalDecision: Sendable, Equatable {
    case approved
    case denied
}

extension ToolApprovalDecision {
    /// The tool result fed back for a denied call. Sent as a success, not an error, because an
    /// error reads to the model as something to retry.
    static let deniedResultPayload = #"{"declined":true,"message":"The user declined to run this tool. Do not retry; acknowledge and continue."}"#
}
