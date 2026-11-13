import Foundation
import Testing
@testable import MailStore

/// 返信・全員に返信・転送の宛先、件名、引用 (T18)。
@Suite struct ComposerTests {
    private let work = AccountID("work")
    private let me = Contact(name: "自分", address: "me@example.com")
    private let tanaka = Contact(name: "田中 健一", address: "k.tanaka@example.com")
    private let sato = Contact(name: "佐藤", address: "sato@example.org")
    private let suzuki = Contact(name: "", address: "suzuki@example.net")
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    /// 2026-11-13 (金) 14:05 (日本時間)
    private let date = Date(timeIntervalSince1970: 1_794_546_300)

    private func source(
        from: [Contact]? = nil, replyTo: [Contact] = [], to: [Contact]? = nil, cc: [Contact] = [],
        subject: String = "打ち合わせの日程調整", messageID: String? = "orig@example.com", references: [String] = ["root@example.com"]
    ) -> ReplySource {
        ReplySource(
            accountID: work, from: from ?? [tanaka], replyTo: replyTo, to: to ?? [me, sato], cc: cc,
            subject: subject, date: date, messageID: messageID, references: references,
            text: "来週のミーティングについて、\n候補日をお送りします。\n\n田中",
            attachments: [DraftAttachment(filename: "候補日.pdf", mimeType: "application/pdf", data: Data([1, 2]))]
        )
    }

    private func draft(_ kind: ComposeKind, _ source: ReplySource) -> Draft {
        Composer.draft(kind, replyingTo: source, myAddresses: ["ME@example.com", "other@gmail.com"], defaultAccount: nil, timeZone: tokyo)
    }

    @Test func newMessageStartsEmptyFromTheDefaultAccount() {
        let draft = Composer.draft(.new, replyingTo: nil, myAddresses: [], defaultAccount: work)
        #expect(draft == Draft(accountID: work))
    }

    @Test func replyGoesToTheSenderFromTheReceivingAccount() {
        let draft = draft(.reply, source())
        #expect(draft.accountID == work)
        #expect(draft.to == [tanaka])
        #expect(draft.cc.isEmpty)
        #expect(draft.subject == "Re: 打ち合わせの日程調整")
        #expect(draft.inReplyTo == "orig@example.com")
        #expect(draft.references == ["root@example.com", "orig@example.com"])
        #expect(draft.attachments.isEmpty)
    }

    @Test func replyUsesReplyToWhenPresent() {
        let list = Contact(name: "", address: "list@example.com")
        #expect(draft(.reply, source(replyTo: [list])).to == [list])
    }

    /// 全員に返信: 差出人に返し、ほかの宛先と Cc は Cc に入れる。自分 (どのアカウントのアドレスも) は除く。
    @Test func replyAllCopiesEveryoneExceptMe() {
        let draft = draft(.replyAll, source(to: [me, sato, Contact(name: "", address: "Other@Gmail.com")], cc: [suzuki, tanaka]))
        #expect(draft.to == [tanaka])
        #expect(draft.cc == [sato, suzuki])
    }

    /// 自分が送ったメールに返信するときは、元の宛先に送る (自分宛てにならない)。
    @Test func replyingToMyOwnMessageGoesToTheOriginalRecipients() {
        let mine = source(from: [me], to: [sato], cc: [suzuki])
        #expect(draft(.reply, mine).to == [sato])
        let all = draft(.replyAll, mine)
        #expect(all.to == [sato])
        #expect(all.cc == [suzuki])
    }

    @Test func replyQuotesTheOriginalWithAHeader() {
        let body = draft(.reply, source()).body
        #expect(body == """


        2026年11月13日(金) 14:05 田中 健一 <k.tanaka@example.com>:
        > 来週のミーティングについて、
        > 候補日をお送りします。
        >
        > 田中
        """)
    }

    @Test func forwardKeepsAttachmentsAndHasNoRecipientsOrThreading() {
        let draft = draft(.forward, source(cc: [suzuki]))
        #expect(draft.to.isEmpty)
        #expect(draft.subject == "Fwd: 打ち合わせの日程調整")
        #expect(draft.attachments.map(\.filename) == ["候補日.pdf"])
        #expect(draft.inReplyTo == nil)
        #expect(draft.body.contains("---------- 転送されたメッセージ ----------\n差出人: 田中 健一 <k.tanaka@example.com>\n日付: 2026年11月13日(金) 14:05\n件名: 打ち合わせの日程調整\n宛先: 自分 <me@example.com>, 佐藤 <sato@example.org>\nCc: suzuki@example.net\n\n来週のミーティングについて、"))
    }

    @Test func messageWithoutMessageIDStillGetsAReply() {
        let draft = draft(.reply, source(messageID: nil))
        #expect(draft.inReplyTo == nil)
        #expect(draft.references.isEmpty)
        #expect(draft.to == [tanaka])
    }

    @Test func subjectPrefixesAreNotRepeated() {
        #expect(Composer.replySubject("Re: 件名") == "Re: 件名")
        #expect(Composer.replySubject("RE: 件名") == "RE: 件名")
        #expect(Composer.replySubject("Re：件名") == "Re：件名")
        #expect(Composer.replySubject("Fwd: 件名") == "Re: Fwd: 件名")
        #expect(Composer.replySubject("") == "Re: ")
        #expect(Composer.forwardSubject("FW: 件名") == "FW: 件名")
        #expect(Composer.forwardSubject("転送: 件名") == "転送: 件名")
        #expect(Composer.forwardSubject("Re: 件名") == "Fwd: Re: 件名")
    }

    @Test func recipientsAreParsedFromWhatTheUserTyped() {
        let parsed = Composer.parseRecipients("田中 健一 <k.tanaka@example.com>, sato@example.org; \"Suzuki, Ichiro\" <suzuki@example.net>\nK.TANAKA@example.com、 bad-address, ")
        #expect(parsed.contacts == [
            tanaka,
            Contact(name: "", address: "sato@example.org"),
            Contact(name: "Suzuki, Ichiro", address: "suzuki@example.net"),
        ])
        #expect(parsed.invalid == ["bad-address"])
    }

    @Test func addressValidation() {
        for good in ["a@b.co", "taro.yamada+news@example.co.jp"] {
            #expect(Composer.isValidAddress(good), "\(good)")
        }
        for bad in ["", "a", "a@b", "@b.com", "a@.com", "a@b.com.", "a b@c.com", "a@b.com\r\nRCPT", "<a@b.com>"] {
            #expect(!Composer.isValidAddress(bad), "\(bad)")
        }
    }

    @Test func problemsAreFoundBeforeSending() {
        #expect(Composer.problem(in: Draft(to: [tanaka])) == .noAccount)
        #expect(Composer.problem(in: Draft(accountID: work)) == .noRecipients)
        #expect(Composer.problem(in: Draft(accountID: work, bcc: [Contact(name: "", address: "x")])) == .invalidAddress("x"))
        let big = DraftAttachment(filename: "big.bin", mimeType: "application/octet-stream", data: Data(count: Composer.maxAttachmentBytes + 1))
        #expect(Composer.problem(in: Draft(accountID: work, to: [tanaka], attachments: [big])) == .attachmentsTooLarge(bytes: Composer.maxAttachmentBytes + 1))
        #expect(Composer.problem(in: Draft(accountID: work, to: [tanaka])) == nil)
    }
}
