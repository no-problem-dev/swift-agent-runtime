import Foundation
import A2ACore
import StructuredDataCore
import LLMClient

/// Carries a worker's token usage back to its caller inside artifact metadata.
///
/// A2A has no event for usage, so the numbers ride along as a JSON string on the artifact the
/// worker produces and are read back out when the delegation finishes. The same path works
/// in-process and over the wire. Encoding and decoding both fail to `nil`: a worker whose usage
/// does not round-trip simply reports none, which shows up as a gap in the cost total.
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
