import Foundation
import Testing
@testable import MailStore

private func raw(_ text: String) -> Data {
    Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
}

@Suite struct MessageBodyBuilderTests {
    private let id = MessageID("m1")

    @Test func plainTextMessage() throws {
        let body = try MessageBodyBuilder.body(id: id, raw: raw("""
        From: 山田 <y@example.com>
        To: 自分 <me@example.com>, other@example.com
        Cc: =?UTF-8?B?5L2Q6Jek?= <sato@example.com>
        Subject: hi
        Content-Type: text/plain; charset=utf-8

        お疲れさまです。
        資料を送ります。
        """))
        #expect(body.messageID == id)
        #expect(body.text == "お疲れさまです。\n資料を送ります。")
        #expect(body.html == nil)
        #expect(body.to == [Contact(name: "自分", address: "me@example.com"), Contact(name: "", address: "other@example.com")])
        #expect(body.cc == [Contact(name: "佐藤", address: "sato@example.com")])
        #expect(body.attachments.isEmpty)
    }

    @Test func htmlOnlyMessageGetsTextFromTheHTML() throws {
        let body = try MessageBodyBuilder.body(id: id, raw: raw("""
        Subject: news
        Content-Type: text/html; charset=utf-8

        <html><body><p>今週の<b>お知らせ</b></p></body></html>
        """))
        #expect(body.text == "今週のお知らせ")
        #expect(body.html?.contains("<b>お知らせ</b>") == true)
    }

    private let mixed = raw("""
    Subject: mixed
    Content-Type: multipart/mixed; boundary="outer"

    --outer
    Content-Type: multipart/related; boundary="rel"

    --rel
    Content-Type: text/html; charset=utf-8

    <p>ロゴ: <img src="cid:logo@x"></p>
    --rel
    Content-Type: image/png
    Content-ID: <logo@x>
    Content-Disposition: inline
    Content-Transfer-Encoding: base64

    iVBORw0K
    --rel
    Content-Type: image/gif
    Content-ID: <unused@x>
    Content-Disposition: inline
    Content-Transfer-Encoding: base64

    R0lGOD
    --rel--
    --outer
    Content-Type: application/pdf; name="report.pdf"
    Content-Disposition: attachment; filename="report.pdf"
    Content-Transfer-Encoding: base64

    JVBERi0=
    --outer--
    """)

    @Test func inlineImagesUsedByTheHTMLAreEmbeddedAndHiddenFromAttachments() throws {
        let body = try MessageBodyBuilder.body(id: id, raw: mixed)
        let html = try #require(body.html)
        #expect(html.contains("src=\"data:image/png;base64,iVBORw0K\""))
        #expect(!html.contains("cid:"))
        // 本文で使われていない埋め込み画像は、添付ファイルとして見せる
        #expect(body.attachments.map(\.filename) == ["attachment", "report.pdf"])
        #expect(body.attachments.map(\.mimeType) == ["image/gif", "application/pdf"])
        #expect(body.attachments.map(\.index) == [1, 2])
        #expect(body.attachments.last?.byteCount == 5)
    }

    @Test func attachmentBytesAreReturnedByIndex() throws {
        #expect(try MessageBodyBuilder.attachmentData(raw: mixed, index: 2) == Data("%PDF-".utf8))
        #expect(throws: MailRepositoryError.attachmentNotFound) {
            _ = try MessageBodyBuilder.attachmentData(raw: mixed, index: 9)
        }
    }

    @Test func previewIsOneShortLine() {
        let body = MessageBody(messageID: id, to: [], text: "  一行目\n\n  二行目 \t です  " + String(repeating: "あ", count: 300))
        let preview = MessageBodyBuilder.preview(of: body)
        #expect(preview.hasPrefix("一行目 二行目 です あ"))
        #expect(preview.count == 140)
    }
}
