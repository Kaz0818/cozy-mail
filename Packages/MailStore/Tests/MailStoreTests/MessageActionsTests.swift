import Foundation
import MailCore
import Testing
@testable import MailStore

/// 既読・スター・アーカイブ・削除・迷惑メール (T15)。画面にはすぐ反映し、サーバーが断ったら元に戻す。
@Suite struct MessageActionsTests {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)
    private let yahoo = Account(id: AccountID("yahoo"), provider: .yahoo, emailAddress: "me@yahoo.example", displayName: "Yahoo!")
    private let gmail = Account(id: AccountID("gmail"), provider: .gmail, emailAddress: "me@gmail.com", displayName: "Gmail")

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86400)
    }

    /// サーバーを同期した保存先と、それを使うリポジトリ。
    private func setUp(
        account: Account, server: FakeMailServer
    ) async throws -> (LiveMailRepository, InMemoryMessageStore) {
        let store = InMemoryMessageStore()
        let now = now
        _ = try await SyncEngine(store: store, now: { now }).sync(account: account, session: server)
        let accounts = [account]
        let repository = LiveMailRepository(
            store: store, accounts: { accounts }, openSession: { _ in server }
        )
        return (repository, store)
    }

    private func yahooServer(withArchive: Bool = true) async -> FakeMailServer {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("Trash", specialUse: .trash)
        await server.addFolder("Bulk Mail")
        if withArchive { await server.addFolder("Archive", specialUse: .archive) }
        await server.add(.init(uid: 11, date: daysAgo(1), subject: "unread", from: "a@example.com"), to: "INBOX")
        await server.add(.init(uid: 12, date: daysAgo(1), subject: "read", from: "b@example.com", flags: ["\\Seen"]), to: "INBOX")
        return server
    }

    private func message(_ store: InMemoryMessageStore, account: Account, mailbox: String, uid: UInt32) async throws -> StoredMessage {
        try #require(try await store.messages(account: account.id, mailbox: mailbox).first { $0.uid == uid })
    }

    // MARK: - フラグ

    @Test func markingReadUpdatesTheScreenTheServerAndTheUnreadCount() async throws {
        let server = await yahooServer()
        let (repository, store) = try await setUp(account: yahoo, server: server)
        #expect(try await store.inboxUnreadCount(account: yahoo.id) == 1)
        let target = try await message(store, account: yahoo, mailbox: "INBOX", uid: 11)

        try await repository.perform(.markRead, on: target.summary.id)

        #expect(try await message(store, account: yahoo, mailbox: "INBOX", uid: 11).summary.isRead)
        #expect(await server.calls.contains("STORE INBOX +\\Seen [11]"))
        #expect(try await store.inboxUnreadCount(account: yahoo.id) == 0)
        #expect(try await repository.unreadCount(in: .unified(.inbox)) == 0)
    }

    @Test func markingUnreadAndStarring() async throws {
        let server = await yahooServer()
        let (repository, store) = try await setUp(account: yahoo, server: server)
        let read = try await message(store, account: yahoo, mailbox: "INBOX", uid: 12)

        try await repository.perform(.markUnread, on: read.summary.id)
        try await repository.perform(.star, on: read.summary.id)

        let updated = try await message(store, account: yahoo, mailbox: "INBOX", uid: 12).summary
        #expect(!updated.isRead && updated.isStarred)
        let calls = await server.calls
        #expect(calls.contains("STORE INBOX -\\Seen [12]"))
        #expect(calls.contains("STORE INBOX +\\Flagged [12]"))
        #expect(try await store.inboxUnreadCount(account: yahoo.id) == 2)
    }

    @Test func doingNothingNewSendsNothing() async throws {
        let server = await yahooServer()
        let (repository, store) = try await setUp(account: yahoo, server: server)
        let read = try await message(store, account: yahoo, mailbox: "INBOX", uid: 12)
        await server.clearCalls()

        try await repository.perform(.markRead, on: read.summary.id)

        #expect(await server.calls.isEmpty)
    }

    // MARK: - 移動 (Gmail 以外)

    @Test func archiveMovesToTheArchiveFolder() async throws {
        let server = await yahooServer()
        let (repository, store) = try await setUp(account: yahoo, server: server)
        let target = try await message(store, account: yahoo, mailbox: "INBOX", uid: 11)

        try await repository.perform(.archive, on: target.summary.id)

        #expect(await server.calls.contains("MOVE INBOX -> Archive [11]"))
        #expect(try await repository.messages(in: .unified(.inbox), filter: .all).map(\.subject) == ["read"])
        #expect(try await repository.messages(in: .unified(.archive), filter: .all).map(\.subject) == ["unread"])
        // 未読のまま受信トレイから出たので、未読数も減る
        #expect(try await store.inboxUnreadCount(account: yahoo.id) == 0)
    }

    @Test func trashAndJunkMoveToTheirFolders() async throws {
        let server = await yahooServer()
        let (repository, store) = try await setUp(account: yahoo, server: server)
        let first = try await message(store, account: yahoo, mailbox: "INBOX", uid: 11)
        let second = try await message(store, account: yahoo, mailbox: "INBOX", uid: 12)

        try await repository.perform(.moveToTrash, on: first.summary.id)
        try await repository.perform(.markAsJunk, on: second.summary.id)

        let calls = await server.calls
        #expect(calls.contains("MOVE INBOX -> Trash [11]"))
        #expect(calls.contains("MOVE INBOX -> Bulk Mail [12]"))
        #expect(try await repository.messages(in: .unified(.trash), filter: .all).count == 1)
        #expect(try await repository.messages(in: .unified(.junk), filter: .all).count == 1)
    }

    @Test func movedMessagesSettleAfterTheNextSync() async throws {
        let server = await yahooServer()
        let (repository, store) = try await setUp(account: yahoo, server: server)
        let target = try await message(store, account: yahoo, mailbox: "INBOX", uid: 11)
        try await repository.perform(.moveToTrash, on: target.summary.id)

        let now = now
        _ = try await SyncEngine(store: store, now: { now }).sync(account: yahoo, session: server)

        #expect(try await repository.messages(in: .unified(.trash), filter: .all).map(\.subject) == ["unread"])
        #expect(try await store.messages(account: yahoo.id, mailbox: "INBOX").map(\.uid) == [12])
    }

    @Test func missingArchiveFolderChangesNothing() async throws {
        let server = await yahooServer(withArchive: false)
        let (repository, store) = try await setUp(account: yahoo, server: server)
        let target = try await message(store, account: yahoo, mailbox: "INBOX", uid: 11)
        await server.clearCalls()

        await #expect(throws: MailRepositoryError.noFolder(.archive)) {
            try await repository.perform(.archive, on: target.summary.id)
        }
        #expect(await server.calls.isEmpty)
        #expect(try await message(store, account: yahoo, mailbox: "INBOX", uid: 11) == target)
    }

    @Test func actionsThatDoNotApplyAreRefused() async throws {
        let server = await yahooServer()
        let (repository, store) = try await setUp(account: yahoo, server: server)
        let target = try await message(store, account: yahoo, mailbox: "INBOX", uid: 11)
        try await repository.perform(.moveToTrash, on: target.summary.id)

        await #expect(throws: MailRepositoryError.actionNotApplicable) {
            try await repository.perform(.moveToTrash, on: target.summary.id)
        }
        await #expect(throws: MailRepositoryError.actionNotApplicable) {
            try await repository.perform(.archive, on: target.summary.id)
        }
    }

    // MARK: - サーバーが断ったとき

    @Test func serverFailureRestoresTheMessageAndTheUnreadCount() async throws {
        let server = await yahooServer()
        let (repository, store) = try await setUp(account: yahoo, server: server)
        let target = try await message(store, account: yahoo, mailbox: "INBOX", uid: 11)
        await server.setFailNextWrite(true)

        await #expect(throws: FakeServerError.writeRejected) {
            try await repository.perform(.archive, on: target.summary.id)
        }
        #expect(try await message(store, account: yahoo, mailbox: "INBOX", uid: 11) == target)
        #expect(try await store.inboxUnreadCount(account: yahoo.id) == 1)
    }

    // MARK: - Gmail

    private func gmailServer() async -> FakeMailServer {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("[Gmail]/All Mail", specialUse: .all)
        await server.addFolder("[Gmail]/Spam", specialUse: .junk)
        await server.addFolder("[Gmail]/Trash", specialUse: .trash)
        await server.add(.init(uid: 1, date: daysAgo(1), subject: "hello", from: "a@example.com",
                               gmailMessageID: 101, labels: ["\\Inbox", "\\Important"]), to: "[Gmail]/All Mail")
        return server
    }

    @Test func gmailArchiveRemovesTheInboxLabelAndStaysArchived() async throws {
        let server = await gmailServer()
        let (repository, store) = try await setUp(account: gmail, server: server)
        let target = try await message(store, account: gmail, mailbox: "[Gmail]/All Mail", uid: 1)

        try await repository.perform(.archive, on: target.summary.id)

        #expect(await server.calls.contains("LABELS [Gmail]/All Mail -\\Inbox [1]"))
        let archived = try await message(store, account: gmail, mailbox: "[Gmail]/All Mail", uid: 1)
        #expect(archived.summary.mailbox == .archive)
        #expect(archived.labels == ["\\Important"])

        let now = now
        _ = try await SyncEngine(store: store, now: { now }).sync(account: gmail, session: server)
        #expect(try await message(store, account: gmail, mailbox: "[Gmail]/All Mail", uid: 1).summary.mailbox == .archive)
    }

    @Test func gmailTrashMovesToTheGmailTrashFolder() async throws {
        let server = await gmailServer()
        let (repository, store) = try await setUp(account: gmail, server: server)
        let target = try await message(store, account: gmail, mailbox: "[Gmail]/All Mail", uid: 1)

        try await repository.perform(.moveToTrash, on: target.summary.id)

        #expect(await server.calls.contains("MOVE [Gmail]/All Mail -> [Gmail]/Trash [1]"))
        #expect(try await repository.messages(in: .unified(.trash), filter: .all).count == 1)
    }

    @Test func samplesCannotBeChanged() async throws {
        await #expect(throws: MailRepositoryError.actionUnavailable) {
            try await PreviewMailRepository().perform(.markRead, on: MessageID("preview-1"))
        }
    }
}
