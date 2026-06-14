import Foundation

public enum AgentRuntimeError: Error, Sendable, Equatable, LocalizedError {
    case unknownAgent(String)
    /// ルーター型ホストで転送先を決定できなかった（transfer_to_agent 呼び出し欠落・引数不正）。
    case routingFailed(String)
    /// LLM が受け付けない画像 mimeType（jpeg/png/gif/webp 以外）。silent drop しない。
    case unsupportedImageMediaType(String)
    /// 画像 base64 のデコードに失敗した。
    case invalidImageData
    /// LLM へ貫通できないリソース（未対応 blob mimeType・resource_link・破損 base64 等）。silent drop しない。
    case unsupportedResource(String)

    public var errorDescription: String? {
        switch self {
        case .unknownAgent(let name): "Unknown agent: \(name)"
        case .routingFailed(let reason): "Routing failed: \(reason)"
        case .unsupportedImageMediaType(let mime): "Unsupported image media type: \(mime)"
        case .invalidImageData: "Invalid image data (base64 decode failed)"
        case .unsupportedResource(let detail): "Unsupported resource: \(detail)"
        }
    }
}
