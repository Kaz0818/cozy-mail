import Foundation
import MailStore
import Testing
import UniformTypeIdentifiers
@testable import CozyMail

/// HTML メールを安全に表示するための文書づくり (SPEC 7: スクリプトを動かさない、外部画像は押すまで読み込まない)。
@Suite struct SafeHTMLTests {
    @Test func detectsRemoteImagesAndStyles() {
        #expect(SafeHTML.hasRemoteContent("<img src=\"https://tracker.example/p.gif\">"))
        #expect(SafeHTML.hasRemoteContent("<IMG SRC='http://x.example/a.png'>"))
        #expect(SafeHTML.hasRemoteContent("<td background=\"https://x.example/bg.png\">"))
        #expect(SafeHTML.hasRemoteContent("<div style=\"background: url( 'https://x.example/a.png' )\">"))
        #expect(SafeHTML.hasRemoteContent("<link rel=stylesheet href=\"https://x.example/a.css\">"))
    }

    @Test func linksAndEmbeddedImagesAreNotRemoteContent() {
        #expect(!SafeHTML.hasRemoteContent("<a href=\"https://example.com\">リンク</a>"))
        #expect(!SafeHTML.hasRemoteContent("<img src=\"data:image/png;base64,AAAA\">"))
    }

    @Test func blockingPolicyAllowsOnlyEmbeddedContentAndNoScripts() {
        let document = SafeHTML.document(for: "<p>本文</p>", allowsRemoteContent: false)
        #expect(document.contains("Content-Security-Policy"))
        #expect(document.contains("default-src 'none'"))
        #expect(document.contains("img-src data:;"))
        #expect(!document.contains("script-src"))
        #expect(document.contains("<p>本文</p>"))
    }

    @Test func allowingRemoteContentStillBlocksScripts() {
        let document = SafeHTML.document(for: "<p>本文</p>", allowsRemoteContent: true)
        #expect(document.contains("default-src 'none'"))
        #expect(document.contains("img-src data: https: http:"))
        #expect(!document.contains("script-src"))
    }

    @Test func policyComesFirstSoItAppliesToTheWholeMessage() throws {
        let document = SafeHTML.document(for: "<html><head><img src=x></head></html>", allowsRemoteContent: false)
        let policy = try #require(document.range(of: "Content-Security-Policy"))
        let message = try #require(document.range(of: "<img src=x>"))
        #expect(policy.lowerBound < message.lowerBound)
    }

    @Test func attachmentFileNamesCannotEscapeTheFolder() {
        #expect(SafeHTML.safeFileName("../../etc/passwd") == "_.._etc_passwd")
        #expect(SafeHTML.safeFileName("a:b/c.pdf") == "a_b_c.pdf")
        #expect(SafeHTML.safeFileName("") == "attachment")
    }
}

@MainActor @Suite struct InboxModelBodyTests {
    /// 本文の取得に失敗するリポジトリ。
    private struct FailingRepository: MailRepository {
        let base = PreviewMailRepository()
        func accounts() async throws -> [Account] { try await base.accounts() }
        func messages(in selection: MailboxSelection, filter: MessageFilter) async throws -> [MessageSummary] {
            try await base.messages(in: selection, filter: filter)
        }
        func unreadCount(in selection: MailboxSelection) async throws -> Int { try await base.unreadCount(in: selection) }
        func body(for id: MessageID) async throws -> MessageBody { throw MailRepositoryError.bodyUnavailable }
        func attachmentData(for id: MessageID, index: Int) async throws -> Data { throw MailRepositoryError.attachmentNotFound }
        func perform(_ action: MessageAction, on id: MessageID) async throws { throw MailRepositoryError.actionUnavailable }
    }

    @Test func bodyFailureIsShownInsteadOfSpinningForever() async {
        let model = InboxModel(repository: FailingRepository())
        await model.load()
        #expect(model.selectedMessage != nil)
        #expect(model.selectedBody == nil)
        #expect(model.bodyError != nil)
    }

    @Test func attachmentDataComesFromTheRepository() async throws {
        let model = InboxModel(repository: PreviewMailRepository())
        await model.load()
        let attachment = try #require(model.selectedBody?.attachments.first)
        let data = try await model.attachmentData(attachment)
        #expect(String(decoding: data, as: UTF8.self).contains("企画書"))
    }
}

@Suite struct AttachmentFileTests {
    @Test func fileTypeComesFromTheExtensionThenTheMIMEType() {
        let pdf = AttachmentFile(attachment: Attachment(filename: "企画書.pdf", mimeType: "application/octet-stream", byteCount: 3), data: Data("abc".utf8))
        #expect(pdf.contentType == .pdf)
        #expect(pdf.filename == "企画書.pdf")

        let png = AttachmentFile(attachment: Attachment(filename: "logo", mimeType: "image/png", byteCount: 1), data: Data([1]))
        #expect(png.contentType == .png)

        let unknown = AttachmentFile(attachment: Attachment(filename: "blob", mimeType: "x-unknown/thing", byteCount: 1), data: Data([1]))
        #expect(unknown.contentType == .data)
    }

    @Test func savedNameCannotEscapeTheChosenFolder() {
        let file = AttachmentFile(attachment: Attachment(filename: "../secret.txt", mimeType: "text/plain", byteCount: 1), data: Data())
        #expect(file.filename == "_secret.txt")
    }
}
