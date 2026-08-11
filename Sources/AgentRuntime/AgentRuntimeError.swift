import Foundation

/// Failures raised by delegation, routing and prompt conversion.
public enum AgentRuntimeError: Error, Sendable, Equatable, LocalizedError {
    /// No worker is registered under this name. Also raised for a task id with no owning worker.
    case unknownAgent(String)
    /// The router could not decide where to send a message: the model produced no transfer call,
    /// or its arguments would not decode. Nothing was forwarded.
    case routingFailed(String)
    /// An image the model cannot accept — anything other than JPEG, PNG, GIF or WebP.
    /// Thrown rather than dropped, so a prompt never silently loses an attachment.
    case unsupportedImageMediaType(String)
    /// The image's base64 payload would not decode.
    case invalidImageData
    /// An attachment that cannot be inlined into the prompt: an unsupported blob type, a link to
    /// a resource rather than its contents, or corrupt base64. Thrown rather than dropped.
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
