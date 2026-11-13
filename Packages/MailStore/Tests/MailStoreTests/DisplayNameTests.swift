import Foundation
import Testing
@testable import MailStore

/// 一覧に出す名前と、差出人の名前の設定 (送信済みのアイコンが「?」になる問題、2026-11-13)。
@Suite struct DisplayNameTests {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)
    private let tanaka = Contact(name: "田中 健一", address: "k.tanaka@example.com")

    private func summary(mailbox: MailboxRole, sender: Contact, recipients: [Contact] = []) -> MessageSummary {
        MessageSummary(
            id: MessageID("m"), accountID: AccountID("a"), mailbox: mailbox, sender: sender, recipients: recipients,
            subject: "件名", preview: "", date: now
        )
    }

    @Test func nameFallsBackToTheAddress() {
        #expect(tanaka.displayName == "田中 健一")
        #expect(Contact(name: "", address: "me@gmail.com").displayName == "me@gmail.com")
        #expect(Contact(name: "  ", address: "me@gmail.com").displayName == "me@gmail.com")
    }

    @Test func receivedMailShowsTheSender() {
        let message = summary(mailbox: .inbox, sender: tanaka, recipients: [Contact(name: "", address: "me@gmail.com")])
        #expect(message.listTitle == "田中 健一")
        #expect(message.listContacts == [tanaka])
    }

    /// 送信済み・下書きは、差出人 (自分) ではなく宛先を出す。
    @Test func sentMailShowsTheRecipients() {
        let me = Contact(name: "", address: "me@gmail.com")
        let sato = Contact(name: "", address: "sato@example.org")
        let sent = summary(mailbox: .sent, sender: me, recipients: [tanaka, sato])
        #expect(sent.listTitle == "宛先: 田中 健一、sato@example.org")
        #expect(sent.listContacts.first == tanaka)
        #expect(summary(mailbox: .drafts, sender: me, recipients: [tanaka]).listTitle == "宛先: 田中 健一")
        // 宛先がまだない下書きは、差出人 (自分) のアドレス
        #expect(summary(mailbox: .drafts, sender: me).listTitle == "me@gmail.com")
    }

    @Test func syncReadsToAndCcAsRecipients() async throws {
        let account = Account(id: AccountID("y"), provider: .yahoo, emailAddress: "me@yahoo.example", displayName: "Yahoo!")
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("Sent", specialUse: .sent)
        await server.add(.init(uid: 5, date: now.addingTimeInterval(-3600), subject: "s", from: "me@yahoo.example",
                               flags: ["\\Seen"], to: "田中 健一 <k.tanaka@example.com>, sato@example.org"), to: "Sent")
        let store = InMemoryMessageStore()
        let now = now
        _ = try await SyncEngine(store: store, now: { now }).sync(account: account, session: server)

        let sent = try #require(try await store.messages(account: account.id, mailbox: "Sent").first).summary
        #expect(sent.recipients == [tanaka, Contact(name: "", address: "sato@example.org")])
        #expect(sent.listTitle == "宛先: 田中 健一、sato@example.org")
    }

    // MARK: - 差出人の名前

    @Test func oldSavedAccountsWithoutASenderNameStillLoad() throws {
        // 前の版の形: いまの形で書き出して、senderName の項目だけを消す
        let current = Account(id: AccountID("a"), provider: .gmail, emailAddress: "me@gmail.com", displayName: "Gmail (仕事)")
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        #expect(object.removeValue(forKey: "senderName") != nil)
        let old = try JSONSerialization.data(withJSONObject: object)
        let account = try JSONDecoder().decode(Account.self, from: old)
        #expect(account.senderName == "")
        #expect(account.displayName == "Gmail (仕事)")
        let again = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(Account(
            id: AccountID("a"), provider: .gmail, emailAddress: "me@gmail.com", displayName: "Gmail", senderName: "山田 太郎"
        )))
        #expect(again.senderName == "山田 太郎")
    }

    @Test func senderNameIsCleanedOfNewlines() {
        #expect(AccountDirectory.cleanSenderName("  山田\r\n太郎 ") == "山田  太郎")
    }
}
