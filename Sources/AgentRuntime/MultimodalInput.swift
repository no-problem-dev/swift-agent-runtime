import A2ACore
import ACPCore
import LLMClient
import Foundation

/// Converts a user prompt's attachments into a message the model can actually see.
///
/// Images from either protocol become image content, and PDF or text attachments become document
/// content. A text-only prompt produces exactly the message a plain string would have, so adding
/// this layer changed nothing for existing callers.
///
/// Anything that cannot be carried through throws instead of being dropped — an unusable
/// attachment must not turn into a prompt that silently omits it. Audio and unrecognised block
/// kinds are the exception: they are skipped without error.
enum MultimodalInput {

    /// Maps a MIME type to the model's image type, throwing for anything the model cannot read.
    static func imageMediaType(for mimeType: String) throws -> ImageMediaType {
        switch mimeType.lowercased() {
        case "image/jpeg": return .jpeg
        case "image/png": return .png
        case "image/gif": return .gif
        case "image/webp": return .webp
        default: throw AgentRuntimeError.unsupportedImageMediaType(mimeType)
        }
    }

    /// Takes the filename off a URI to label a document. `nil` when there is nothing to show.
    private static func title(fromURI uri: String) -> String? {
        let trimmed = URL(string: uri)?.lastPathComponent ?? (uri as NSString).lastPathComponent
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Builds a user message from an ACP prompt.
    ///
    /// Text blocks are joined with no separator, matching what the ACP path did before
    /// attachments existed. Audio and unknown blocks are skipped silently; everything else that
    /// cannot be carried throws.
    static func userMessage(from blocks: [ContentBlock]) throws -> LLMMessage {
        var contents: [LLMMessage.MessageContent] = []
        for block in blocks {
            switch block {
            case let .text(content):
                contents.append(.text(content.text))
            case let .image(image):
                guard let data = Data(base64Encoded: image.data) else {
                    throw AgentRuntimeError.invalidImageData
                }
                contents.append(.image(ImageContent(source: .base64(data), mediaType: try imageMediaType(for: image.mimeType))))
            case let .resource(resource):
                contents.append(try documentContent(from: resource.resource))
            case let .resourceLink(link):
                throw AgentRuntimeError.unsupportedResource("resource_link (\(link.uri))")
            case .audio, .unknown:
                break
            }
        }
        return collapse(contents, textSeparator: "")
    }

    /// Turns an embedded resource into document content.
    ///
    /// Text resources are already extracted and pass through as plain text. Raw bytes are only
    /// accepted as PDF — any other binary type throws rather than reaching the model as garbage.
    private static func documentContent(from resource: EmbeddedResourceResource) throws -> LLMMessage.MessageContent {
        switch resource {
        case let .text(text):
            return .document(DocumentContent(
                source: .base64(Data(text.text.utf8)),
                mediaType: .plainText,
                title: title(fromURI: text.uri)
            ))
        case let .blob(blob):
            guard blob.mimeType == "application/pdf" else {
                throw AgentRuntimeError.unsupportedResource("blob mimeType \(blob.mimeType ?? "(none)") (\(blob.uri))")
            }
            guard let data = Data(base64Encoded: blob.blob) else {
                throw AgentRuntimeError.unsupportedResource("invalid base64 blob (\(blob.uri))")
            }
            return .document(DocumentContent(
                source: .base64(data),
                mediaType: .pdf,
                title: title(fromURI: blob.uri)
            ))
        }
    }

    /// Builds a user message from A2A parts, joining text with newlines.
    static func userMessage(from parts: [Part]) throws -> LLMMessage {
        collapse(try contents(from: parts))
    }

    /// Converts parts to message content without deciding a role.
    ///
    /// Text passes through verbatim and structured data is serialised to JSON per part. Byte
    /// parts are only accepted as images; anything else throws. A data part that fails to encode
    /// is dropped without error, so it reaches the model as an absence rather than a failure.
    static func contents(from parts: [Part]) throws -> [LLMMessage.MessageContent] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var contents: [LLMMessage.MessageContent] = []
        for part in parts {
            switch part.content {
            case let .text(text):
                contents.append(.text(text))
            case .data:
                if let json = (try? encoder.encode(part)).flatMap({ String(data: $0, encoding: .utf8) }) {
                    contents.append(.text(json))
                }
            case let .bytes(data):
                guard let mediaType = part.mediaType, mediaType.hasPrefix("image/") else {
                    throw AgentRuntimeError.unsupportedImageMediaType(part.mediaType ?? "(none)")
                }
                contents.append(.image(ImageContent(source: .base64(data), mediaType: try imageMediaType(for: mediaType))))
            case let .uri(uri):
                contents.append(.text(uri))
            }
        }
        return contents
    }

    /// Folds text-only content back into the single-string form, byte for byte what a plain
    /// string message produces. Only a prompt with real attachments becomes multi-part.
    private static func collapse(_ contents: [LLMMessage.MessageContent], textSeparator: String = "\n") -> LLMMessage {
        let hasMedia = contents.contains {
            if case .text = $0 { return false }
            return true
        }
        if !hasMedia {
            let text = contents.compactMap { content -> String? in
                if case let .text(value) = content { return value }
                return nil
            }.joined(separator: textSeparator)
            return .user(text)
        }
        return .user(contents: contents)
    }
}
