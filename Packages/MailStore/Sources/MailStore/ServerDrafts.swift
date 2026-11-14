import Foundation
import MailCore

/// Mac に保存した下書きを、サーバーの下書きフォルダにも置く (T23b、US-14)。Gmail の Web 版などから続きが書けるように。
///
/// **このアプリが入れた下書き以外は、決して消さない。** そのために:
/// 1. 入れる下書きには、下書きごとに決まった Message-ID (`cozy-draft.<番号>@<ドメイン>`) を付ける。
/// 2. 消す前に、その Message-ID で探し (`SEARCH HEADER`)、見つかったメールの見出しを取って、Message-ID が**ちょうど同じ**か確かめる
///    (`SEARCH` は「含む」で当たるので、似たメールも見つかるため)。
/// 3. 消すのは、確かめたメールだけ (`UID EXPUNGE`)。UIDPLUS がないサーバーには、入れも消しもしない
///    (ただの `EXPUNGE` はほかのメールまで消すので使えず、消せないと書き直すたびに下書きが増えるため)。
///
/// 書き直したときは、古いものを消してから入れ直す (入れるのに失敗しても、Mac の下書きは残っている)。
public struct ServerDrafts: Sendable {
    public typealias SessionOpener = @Sendable (AccountID) async throws -> any MailServerSession

    private let store: any MessageStore
    private let accounts: @Sendable () async throws -> [Account]
    private let openSession: SessionOpener

    public init(
        store: any MessageStore,
        accounts: @escaping @Sendable () async throws -> [Account],
        openSession: @escaping SessionOpener
    ) {
        self.store = store
        self.accounts = accounts
        self.openSession = openSession
    }

    /// 探すときの言葉 (Message-ID の @ の前)。
    public static func marker(for id: UUID) -> String {
        "cozy-draft.\(id.uuidString.lowercased())"
    }

    /// この下書きのサーバーでの Message-ID (`<>` なし)。
    public static func messageID(for id: UUID, account: Account) -> String {
        let domain = account.emailAddress.split(separator: "@").last.map(String.init) ?? "cozymail.local"
        return "\(marker(for: id))@\(domain)"
    }

    /// 下書きをサーバーに置く (前に置いたものは消して入れ直す)。差出人のアカウントがない下書きは何もしない。
    public func upload(_ saved: SavedDraft) async throws {
        guard let accountID = saved.content.accountID else { return }
        let (account, folder) = try await destination(accountID)
        let data = try Self.build(saved, account: account)
        let session = try await openSession(account.id)
        do {
            guard try await session.supportsUIDPlus() else { throw IMAPError.unsupported("UIDPLUS") }
            try await removeCopies(of: saved.id, account: account, folder: folder, session: session)
            try await session.append(data, to: folder, flags: ["\\Draft", "\\Seen"])
        } catch {
            await session.close()
            throw error
        }
        await session.close()
    }

    /// サーバーに置いた下書きを消す (送ったとき・捨てたとき)。
    public func remove(id: UUID, accountID: AccountID) async throws {
        let (account, folder) = try await destination(accountID)
        let session = try await openSession(account.id)
        do {
            guard try await session.supportsUIDPlus() else { throw IMAPError.unsupported("UIDPLUS") }
            try await removeCopies(of: id, account: account, folder: folder, session: session)
        } catch {
            await session.close()
            throw error
        }
        await session.close()
    }

    /// 下書きフォルダから、この下書きの写し (Message-ID がちょうど同じもの) だけを消す。
    private func removeCopies(of id: UUID, account: Account, folder: String, session: any MailServerSession) async throws {
        let found = try await session.searchUIDs(in: folder, header: "Message-ID", containing: Self.marker(for: id))
        guard !found.isEmpty else { return }
        let expected = Self.messageID(for: id, account: account)
        let headers = try await session.fetchHeaders(in: folder, uids: found, includeGmailAttributes: false)
        let ours = headers.filter { header in
            guard let parsed = try? MIMEParser.parse(header.headerData) else { return false }
            return parsed.messageID == expected
        }.map(\.uid)
        guard !ours.isEmpty else { return }
        try await session.deleteMessages(uids: ours, in: folder)
    }

    private func destination(_ accountID: AccountID) async throws -> (Account, String) {
        guard let account = try await accounts().first(where: { $0.id == accountID }) else {
            throw DraftProblem.noAccount
        }
        guard let folder = try await store.mailboxName(for: .drafts, account: account.id) else {
            throw MailRepositoryError.noFolder(.drafts)
        }
        return (account, folder)
    }

    /// サーバーに置くメールの形。日付は Mac に保存した時刻。
    static func build(_ saved: SavedDraft, account: Account) throws -> Data {
        let draft = saved.content.draft
        let address = { (contacts: [Contact]) in contacts.map { EmailAddress(name: $0.name, address: $0.address) } }
        let message = OutgoingMessage(
            from: EmailAddress(name: account.senderName, address: account.emailAddress),
            to: address(draft.to),
            cc: address(draft.cc),
            bcc: address(draft.bcc),
            subject: draft.subject,
            textBody: draft.body,
            attachments: draft.attachments.map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) },
            inReplyTo: draft.inReplyTo,
            references: draft.references,
            date: saved.savedAt,
            messageID: messageID(for: saved.id, account: account)
        )
        return try MIMEBuilder.build(message)
    }
}
