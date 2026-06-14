import Foundation
import Testing
import ACPCore
@testable import AgentRuntime

@Suite("MultimodalInput (画像貫通)")
struct MultimodalInputTests {

    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
    private var pngBase64: String { pngBytes.base64EncodedString() }

    /// テキストのみメッセージが `.user(String)` と同形（contents == [.text]）であることを確認しつつ本文を返す。
    private func soleText(of message: LLMMessage) -> String? {
        guard message.contents.count == 1, case let .text(value) = message.contents.first else { return nil }
        return value
    }

    // MARK: - ACP ContentBlock → LLMMessage

    @Test("ACP: テキスト + 画像 → contents に .text と .image(base64) が含まれる")
    func acpTextPlusImage() throws {
        let blocks: [ContentBlock] = [
            .text(TextContent(text: "この画像は？")),
            .image(ImageContent(data: pngBase64, mimeType: "image/png")),
        ]
        let message = try MultimodalInput.userMessage(from: blocks)

        #expect(message.role == .user)
        let images = message.images
        #expect(images.count == 1)
        #expect(images.first?.mediaType == .png)
        if case let .base64(data) = images.first?.source {
            #expect(data == pngBytes)
        } else {
            Issue.record("expected base64 source")
        }
        let texts = message.contents.compactMap { content -> String? in
            if case let .text(value) = content { return value }
            return nil
        }
        #expect(texts == ["この画像は？"])
    }

    @Test("ACP: テキストのみ → .user(String) と同一（回帰なし）")
    func acpTextOnlyMatchesLegacy() throws {
        let blocks: [ContentBlock] = [
            .text(TextContent(text: "hello ")),
            .text(TextContent(text: "world")),
        ]
        let message = try MultimodalInput.userMessage(from: blocks)
        // 旧 HostACPAgent は区切りなしで join していた。
        #expect(message.images.isEmpty)
        #expect(soleText(of: message) == "hello world")
    }

    @Test("ACP: 未対応 mimeType は silent drop せず throw する")
    func acpUnsupportedMimeThrows() {
        let blocks: [ContentBlock] = [.image(ImageContent(data: pngBase64, mimeType: "image/bmp"))]
        #expect(throws: AgentRuntimeError.unsupportedImageMediaType("image/bmp")) {
            _ = try MultimodalInput.userMessage(from: blocks)
        }
    }

    @Test("ACP: 不正な base64 は throw する")
    func acpInvalidBase64Throws() {
        let blocks: [ContentBlock] = [.image(ImageContent(data: "!!!not-base64!!!", mimeType: "image/png"))]
        #expect(throws: AgentRuntimeError.invalidImageData) {
            _ = try MultimodalInput.userMessage(from: blocks)
        }
    }

    // MARK: - mimeType マッピング

    @Test("mimeType → ImageMediaType: jpeg/png/gif/webp")
    func mediaTypeMapping() throws {
        #expect(try MultimodalInput.imageMediaType(for: "image/jpeg") == .jpeg)
        #expect(try MultimodalInput.imageMediaType(for: "image/png") == .png)
        #expect(try MultimodalInput.imageMediaType(for: "image/gif") == .gif)
        #expect(try MultimodalInput.imageMediaType(for: "image/webp") == .webp)
    }

    // MARK: - A2A Part → LLMMessage

    @Test("A2A: テキスト + 画像バイト → .text と .image が含まれる")
    func a2aTextPlusImageBytes() throws {
        let parts: [Part] = [
            .text("describe"),
            .file(bytes: pngBytes, mediaType: "image/png"),
        ]
        let message = try MultimodalInput.userMessage(from: parts)
        #expect(message.images.count == 1)
        #expect(message.images.first?.mediaType == .png)
        let texts = message.contents.compactMap { content -> String? in
            if case let .text(value) = content { return value }
            return nil
        }
        #expect(texts == ["describe"])
    }

    @Test("A2A: テキストのみ → .user(String) と同一（\\n 区切り、回帰なし）")
    func a2aTextOnlyMatchesLegacy() throws {
        let parts: [Part] = [.text("a"), .text("b")]
        let message = try MultimodalInput.userMessage(from: parts)
        #expect(message.images.isEmpty)
        #expect(soleText(of: message) == "a\nb")
    }

    @Test("A2A: 非画像バイト（image/* 以外）は silent drop せず throw する")
    func a2aNonImageBytesThrows() {
        let parts: [Part] = [.file(bytes: pngBytes, mediaType: "application/pdf")]
        #expect(throws: AgentRuntimeError.unsupportedImageMediaType("application/pdf")) {
            _ = try MultimodalInput.userMessage(from: parts)
        }
    }
}
