import Foundation
import Testing
@testable import MailCore

/// 送るメールの組み立て。組み立てたものを T8 の解析器で読むと、元に戻ることを確かめる。
@Suite struct MIMEBuilderTests {
    private let me = EmailAddress(name: "山田 太郎", address: "taro@example.com")
    private let date = Date(timeIntervalSince1970: 1_794_600_000)

    private func message(
        subject: String = "企画書の件",
        body: String = "お世話になっております。\n資料をお送りします。\n",
        attachments: [OutgoingAttachment] = []
    ) -> OutgoingMessage {
        OutgoingMessage(
            from: me,
            to: [EmailAddress(name: "Hanako Sato", address: "hanako@example.org"), EmailAddress(name: "", address: "b@example.net")],
            cc: [EmailAddress(name: "経理部", address: "keiri@example.com")],
            bcc: [EmailAddress(name: "", address: "secret@example.com")],
            subject: subject,
            textBody: body,
            attachments: attachments,
            inReplyTo: "orig-1@example.org",
            references: ["root@example.org", "orig-1@example.org"],
            date: date,
            messageID: "new-1@example.com"
        )
    }

    @Test func roundTripsThroughTheParser() throws {
        let data = try MIMEBuilder.build(message())
        let parsed = try MIMEParser.parse(data)

        #expect(parsed.subject == "企画書の件")
        #expect(parsed.from == [me])
        #expect(parsed.to == [EmailAddress(name: "Hanako Sato", address: "hanako@example.org"), EmailAddress(name: "", address: "b@example.net")])
        #expect(parsed.cc == [EmailAddress(name: "経理部", address: "keiri@example.com")])
        #expect(parsed.textBody == "お世話になっております。\n資料をお送りします。\n")
        #expect(parsed.messageID == "new-1@example.com")
        #expect(parsed.inReplyTo == "orig-1@example.org")
        #expect(parsed.references == ["root@example.org", "orig-1@example.org"])
        #expect(parsed.date == date)
        #expect(parsed.attachments.isEmpty)
    }

    @Test func bccIsNotWrittenButIsARecipient() throws {
        let built = message()
        let text = String(decoding: try MIMEBuilder.build(built), as: UTF8.self)
        #expect(!text.contains("secret@example.com"))
        #expect(!text.lowercased().contains("bcc:"))
        #expect(built.envelopeRecipients == ["hanako@example.org", "b@example.net", "keiri@example.com", "secret@example.com"])
    }

    @Test func recipientsAreNotDuplicated() {
        var built = message()
        built.cc = [EmailAddress(name: "", address: "HANAKO@example.org")]
        built.bcc = []
        #expect(built.envelopeRecipients == ["hanako@example.org", "b@example.net"])
    }

    @Test func outputIsSevenBitWithCRLFAndShortLines() throws {
        let long = String(repeating: "とても長い件名です。", count: 12)
        let data = try MIMEBuilder.build(message(subject: long, body: String(repeating: "本文", count: 500)))
        #expect(data.allSatisfy { $0 < 0x80 })
        let text = String(decoding: data, as: UTF8.self)
        // 改行はすべて CRLF
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\r"))
        // 1 行は 78 文字まで (RFC 5322 の推奨)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines.allSatisfy { $0.utf8.count <= 78 }, "長すぎる行: \(lines.filter { $0.utf8.count > 78 })")
        #expect(try MIMEParser.parse(data).subject == long)
    }

    @Test func encodedWordsNeverSplitACharacter() {
        // 絵文字 (4 バイト) や結合文字を含んでも、1 語ずつ UTF-8 として読める
        let text = "👨‍👩‍👧‍👦家族の写真📷を送ります。" + String(repeating: "あ", count: 30)
        let words = MIMEBuilder.encodedWords(text)
        #expect(words.count > 1)
        #expect(words.allSatisfy { $0.utf8.count <= 75 })
        let decoded = words.map { word -> String in
            let base64 = word.dropFirst("=?UTF-8?B?".count).dropLast(2)
            return String(data: Data(base64Encoded: String(base64))!, encoding: .utf8) ?? "<読めない>"
        }
        #expect(!decoded.contains("<読めない>"))
        #expect(decoded.joined() == text)
    }

    @Test func attachmentsRoundTripWithJapaneseFileNames() throws {
        let pdf = Data((0..<3000).map { UInt8($0 % 256) })
        let attachments = [
            OutgoingAttachment(filename: "企画書 2026年版.pdf", mimeType: "application/pdf", data: pdf),
            OutgoingAttachment(filename: "notes.txt", mimeType: "text/plain", data: Data("memo\n".utf8)),
        ]
        let data = try MIMEBuilder.build(message(attachments: attachments), boundary: "BOUNDARY-1")
        let parsed = try MIMEParser.parse(data)

        #expect(parsed.textBody == "お世話になっております。\n資料をお送りします。\n")
        #expect(parsed.attachments.count == 2)
        #expect(parsed.attachments[0].filename == "企画書 2026年版.pdf")
        #expect(parsed.attachments[0].mimeType == "application/pdf")
        #expect(parsed.attachments[0].data == pdf)
        #expect(parsed.attachments[1].filename == "notes.txt")
        #expect(parsed.attachments[1].data == Data("memo\n".utf8))
        #expect(parsed.attachments.allSatisfy { !$0.isInline })
    }

    /// とても長い日本語のファイル名でも、1 行は 78 文字までで、名前は元に戻る。
    @Test func longFileNamesAreFoldedAndRoundTrip() throws {
        let name = String(repeating: "令和八年度の事業計画書と予算の見積もり", count: 4) + ".xlsx"
        let built = message(attachments: [OutgoingAttachment(filename: name, mimeType: "application/vnd.ms-excel", data: Data([1, 2, 3]))])
        let data = try MIMEBuilder.build(built)
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        #expect(lines.allSatisfy { $0.utf8.count <= 78 }, "長すぎる行: \(lines.filter { $0.utf8.count > 78 })")
        let parsed = try MIMEParser.parse(data)
        #expect(parsed.attachments.first?.filename == name)
        #expect(parsed.attachments.first?.data == Data([1, 2, 3]))
    }

    /// 件名や名前に改行を入れて、ヘッダーを増やすことはできない。
    @Test func newlinesCannotInjectHeaders() throws {
        var built = message(subject: "こんにちは\r\nBcc: victim@example.com")
        built.from = EmailAddress(name: "Evil\r\nX-Injected: yes", address: "taro@example.com")
        let text = String(decoding: try MIMEBuilder.build(built), as: UTF8.self)
        let headerLines = text.components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\r\n")
        #expect(!headerLines.contains { $0.lowercased().hasPrefix("bcc:") })
        #expect(!headerLines.contains { $0.hasPrefix("X-Injected") })
    }

    @Test func invalidAddressesAreRejected() {
        for bad in ["", "no-at-sign", "a@", "@b", "a b@example.com", "a@example.com\r\nRCPT TO:<x@y>", "<a@b>"] {
            var built = message()
            built.to = [EmailAddress(name: "", address: bad)]
            #expect(throws: MIMEBuildError.invalidAddress(bad)) { try MIMEBuilder.build(built) }
        }
    }

    @Test func messageWithoutRecipientsIsRejected() {
        var built = message()
        built.to = []
        built.cc = []
        built.bcc = []
        #expect(throws: MIMEBuildError.noRecipients) { try MIMEBuilder.build(built) }
    }

    @Test func plainASCIISubjectIsLeftReadable() throws {
        let text = String(decoding: try MIMEBuilder.build(message(subject: "Meeting notes")), as: UTF8.self)
        #expect(text.contains("\r\nSubject: Meeting notes\r\n"))
    }

    @Test func dateUsesTheRFC5322Format() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(MIMEBuilder.formatDate(Date(timeIntervalSince1970: 0), timeZone: tokyo) == "Thu, 01 Jan 1970 09:00:00 +0900")
    }

    @Test func messageIDUsesTheSenderDomain() {
        let id = MIMEBuilder.makeMessageID(for: me)
        #expect(id.hasSuffix("@example.com"))
        #expect(id != MIMEBuilder.makeMessageID(for: me))
    }
}
