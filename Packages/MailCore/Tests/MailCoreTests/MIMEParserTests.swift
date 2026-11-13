import Foundation
import Testing
@testable import MailCore

private func fixture(_ name: String) throws -> ParsedMessage {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "eml", subdirectory: "Fixtures"))
    return try MIMEParser.parse(Data(contentsOf: url))
}

private func date(_ string: String) -> Date? {
    ISO8601DateFormatter().date(from: string)
}

@Suite struct MIMEParserTests {
    @Test func utf8PlainText() throws {
        let message = try fixture("plain-utf8")
        #expect(message.subject == "企画のご提案について")
        #expect(message.from == [EmailAddress(name: "山田 さくら", address: "s.yamada@example.com")])
        #expect(message.to == [EmailAddress(name: "", address: "me@example.com")])
        #expect(message.messageID == "proposal-1@example.com")
        #expect(message.date == date("2026-11-12T07:24:00Z"))
        #expect(message.textBody == "お疲れさまです。\n先日の打ち合わせをもとに、企画書を作成しました。\n")
        #expect(message.htmlBody == nil)
        #expect(message.attachments.isEmpty)
    }

    @Test func iso2022jpSubjectSplitAcrossFoldedEncodedWordsAndBody() throws {
        let message = try fixture("iso2022jp")
        #expect(message.subject == "打ち合わせの日程調整")
        #expect(message.from.first?.name == "田中 健一")
        #expect(message.date == date("2026-11-12T05:05:00Z"))
        #expect(message.textBody == "来週のミーティングについて、\n候補日をお送りします。\n")
    }

    @Test func shiftJISQuotedPrintableBodyAndQEncodedSubject() throws {
        let message = try fixture("shiftjis-qp")
        #expect(message.subject == "ご注文の確認")
        #expect(message.textBody == "ご注文ありがとうございます。\n注文番号: 12345\n")
    }

    @Test func multipartAlternativeHasBothBodies() throws {
        let message = try fixture("alternative")
        #expect(message.textBody == "今週の進捗レポートを共有します。")
        #expect(message.htmlBody == "<html><body><p>今週の<b>進捗レポート</b>を共有します。</p></body></html>")
        #expect(message.attachments.isEmpty)
    }

    @Test func mixedWithRFC2231JapaneseFilename() throws {
        let message = try fixture("mixed-attachment")
        #expect(message.textBody == "本文です。")
        #expect(message.htmlBody == "<p>本文です。</p>")
        let attachment = try #require(message.attachments.first)
        #expect(message.attachments.count == 1)
        #expect(attachment.filename == "企画書（Ver.2）.pdf")
        #expect(attachment.mimeType == "application/pdf")
        #expect(attachment.data == Data("%PDF-1.4 fake pdf bytes ".utf8) + Data([0, 1, 2]))
        #expect(!attachment.isInline)
    }

    @Test func attachmentNameAsEncodedWord() throws {
        let message = try fixture("attachment-encoded-word-name")
        #expect(message.textBody == "請求書を添付します。")
        #expect(message.attachments.map(\.filename) == ["請求書_11月.xlsx"])
    }

    @Test func htmlOnly() throws {
        let message = try fixture("html-only")
        #expect(message.textBody == nil)
        #expect(message.htmlBody == "<h1>Hello</h1>\n")
    }

    @Test func missingContentTypeDefaultsToPlainText() throws {
        let message = try fixture("no-content-type")
        #expect(message.textBody == "Hello there.\n")
        #expect(message.date == date("2026-01-01T00:00:00Z"))
    }

    @Test func addressListsAndThreadingHeaders() throws {
        let message = try fixture("addresses")
        #expect(message.from == [EmailAddress(name: "佐藤 美咲", address: "m.sato@example.com")])
        #expect(message.to == [
            EmailAddress(name: "Tanaka, Kenichi", address: "k.tanaka@example.com"),
            EmailAddress(name: "", address: "plain@example.com"),
            EmailAddress(name: "鈴木", address: "d.suzuki@example.com"),
        ])
        #expect(message.cc == [EmailAddress(name: "", address: "bare@example.com")])
        #expect(message.replyTo == [EmailAddress(name: "", address: "replies@example.com")])
        #expect(message.inReplyTo == "parent@example.com")
        #expect(message.references == ["root@example.com", "parent@example.com"])
    }

    @Test func inlineImageInMultipartRelated() throws {
        let message = try fixture("inline-image")
        #expect(message.htmlBody == "<img src=\"cid:logo@example\">")
        let image = try #require(message.attachments.first)
        #expect(image.mimeType == "image/png")
        #expect(image.contentID == "logo@example")
        #expect(image.isInline)
    }

    @Test func latin1QuotedPrintable() throws {
        let message = try fixture("latin1-qp")
        #expect(message.subject == "café crème")
        #expect(message.from.first?.name == "René")
        #expect(message.textBody == "Café crème ? déjà vu")
    }

    @Test func lfLineEndingsAndCaseInsensitiveHeaders() throws {
        let message = try fixture("lf-line-endings")
        #expect(message.subject == "lower and upper case headers")
        #expect(message.to.first?.address == "me@example.com")
        #expect(message.textBody == "LF only body.\n")
    }
}

@Suite struct EncodedWordTests {
    @Test func plainTextPassesThrough() {
        #expect(EncodedWord.decode("Hello world") == "Hello world")
    }

    @Test func whitespaceBetweenEncodedWordsIsDropped() {
        #expect(EncodedWord.decode("=?UTF-8?B?44GC?= =?UTF-8?B?44GE?=") == "あい")
    }

    @Test func whitespaceBetweenTextAndEncodedWordIsKept() {
        #expect(EncodedWord.decode("Re: =?UTF-8?B?44GC?= end") == "Re: あ end")
    }

    @Test func qEncodingUnderscoreIsSpace() {
        #expect(EncodedWord.decode("=?UTF-8?Q?a_b=3Dc?=") == "a b=c")
    }

    @Test func unknownCharsetFallsBackWithoutCrashing() {
        #expect(EncodedWord.decode("=?x-unknown?B?SGk=?=") == "Hi")
    }
}
