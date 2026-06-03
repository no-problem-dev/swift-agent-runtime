import Foundation
import A2ACore
import StructuredDataCore
import LLMClient

/// ワーカー（サブエージェント）の LLM トークン使用量を A2A メタデータに載せて運ぶための変換。
///
/// A2A の `StreamResponse` には usage 専用イベントが無いため、委譲結果の artifact metadata に
/// `TokenUsage` を JSON 文字列として格納し、`delegate(...)` 側で取り出してコスト集計に合算する。
/// in-process でも remote でも同じ経路で運べる（トランスポート非依存）。
enum UsageMetadata {
    static let key = "llm.usage"

    static func encode(_ usage: TokenUsage) -> A2AMetadata? {
        guard let data = try? JSONEncoder().encode(usage),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return [key: .string(json)]
    }

    static func decode(_ metadata: A2AMetadata?) -> TokenUsage? {
        guard let metadata, case .string(let json)? = metadata[key],
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TokenUsage.self, from: data)
    }
}
