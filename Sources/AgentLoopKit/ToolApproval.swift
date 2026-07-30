import Foundation
import LLMTool

/// 実行前にユーザー承認を要するツールのマーカー。
///
/// `AgentLoop` は該当ツールの呼び出しを含むステップで**実行せずに中断**し、
/// `.toolApprovalRequired` を発してトランスクリプトを返す(`InteractiveRuntimeTool`
/// と同じ中断モデル)。ホストはユーザーの裁定を集め、同じトランスクリプトと
/// `pendingToolDecisions` で `run` を再開する。
public protocol ApprovalRequiringTool: Tool {
    /// この呼び出しに承認が必要なら、ユーザーへ提示する承認要求を返す。
    /// `nil` は「この引数では承認不要」(即実行)。
    /// 表示情報の解決(ID → 名前等)のため async。
    func approvalRequest(from argumentsData: Data) async -> ToolApprovalRequest?
}

/// ユーザーへ提示する承認要求(表示用)。
public struct ToolApprovalRequest: Sendable, Equatable {
    /// 何をするかの 1 行要約(例: 「3 店舗をフォローします」)。
    public var summary: String
    /// 明細(例: 店舗名の一覧)。
    public var details: [String]

    public init(summary: String, details: [String] = []) {
        self.summary = summary
        self.details = details
    }
}

/// 保留中ツール呼び出しへのユーザー裁定。
public enum ToolApprovalDecision: Sendable, Equatable {
    case approved
    case denied
}

extension ToolApprovalDecision {
    /// 拒否時にモデルへ返すツール結果。エラーではなく通常の結果として返す
    /// (エラー扱いにするとモデルが再試行しうるため)。
    static let deniedResultPayload = #"{"declined":true,"message":"The user declined to run this tool. Do not retry; acknowledge and continue."}"#
}
