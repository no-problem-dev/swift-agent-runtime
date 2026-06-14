import A2ACore
import ACPCore
import LLMClient
import Foundation

/// ユーザープロンプトのマルチモーダルコンテンツ（テキスト + 画像）を `LLMMessage` まで貫通させる変換層。
///
/// ACP `ContentBlock` / A2A `Part` の画像（base64 data + mimeType / bytes + mediaType）を LLM の
/// `MessageContent.image` に射影する。テキストのみの入力は従来どおり `.user(text)` と同一の出力を返す
/// （回帰防止）。非対応の画像 mimeType は黙って捨てず `unsupportedImageMediaType` を throw する。
enum MultimodalInput {

    static func imageMediaType(for mimeType: String) throws -> ImageMediaType {
        switch mimeType.lowercased() {
        case "image/jpeg": return .jpeg
        case "image/png": return .png
        case "image/gif": return .gif
        case "image/webp": return .webp
        default: throw AgentRuntimeError.unsupportedImageMediaType(mimeType)
        }
    }

    /// ACP プロンプト（`[ContentBlock]`）→ ユーザー `LLMMessage`。
    /// 画像は base64 をデコードして `.image` に、テキストは `.text` に射影する。
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
                if case let .text(text) = resource.resource { contents.append(.text(text.text)) }
            case .audio, .resourceLink, .unknown:
                break
            }
        }
        return collapse(contents, textSeparator: "")
    }

    /// A2A `[Part]` → ユーザー `LLMMessage`。
    /// テキストは逐語、構造化データ（`.data`）はパートごと JSON 化（既存 historyText と同等）、
    /// 画像バイト（`.bytes` + image/* mediaType）は `.image` に射影する。
    static func userMessage(from parts: [Part]) throws -> LLMMessage {
        collapse(try contents(from: parts))
    }

    /// `[Part]` を `[MessageContent]` へ。`role` を呼び出し側で決められるよう contents だけ返す。
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

    /// 画像を含まなければテキストを結合して `.user(text)` と同一出力に畳む（回帰防止）。
    /// 画像が混在する場合のみ複合コンテンツの `LLMMessage` を構築する。
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
