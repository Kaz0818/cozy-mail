import Foundation
import Testing
@testable import MailStore
#if canImport(SwiftData)
@testable import MailStoreSwiftData
#endif

/// 一覧と未読数の絞り込みを、保存先の中 (SwiftData ならデータベース) で行う (T10「何年分たまっても、画面がもたつかない」)。
/// どの保存先でも、画面の決まり (`MailboxSelection.contains`・`MessageFilter.matches`) と同じ結果になること。
@Suite struct MessageQueryTests {
    private static let first = AccountID("first")
    private static let second = AccountID("second")
    /// 削除したアカウント (保存先に残っていても出さない)。
    private static let removed = AccountID("removed")
    private static let registered: Set<AccountID> = [first, second]

    /// アカウント・フォルダ・既読・スターのすべての組み合わせ (3 × 6 × 2 × 2 = 72 通)。日付は入れた順と関係なくばらばら。
    private static func everyKindOfMessage() -> [StoredMessage] {
        var messages: [StoredMessage] = []
        var number: UInt32 = 0
        for account in [first, second, removed] {
            for role in [MailboxRole.inbox, .sent, .drafts, .archive, .junk, .trash] {
                for isRead in [false, true] {
                    for isStarred in [false, true] {
                        number += 1
                        messages.append(StoredMessage(
                            summary: MessageSummary(
                                id: MessageID("\(account.rawValue)/\(number)"),
                                accountID: account,
                                mailbox: role,
                                sender: Contact(name: "", address: "s@example.com"),
                                subject: "\(number)",
                                preview: "",
                                // 919 と 1000 は互いに素なので、72 通の日付はすべて違う
                                date: Date(timeIntervalSince1970: 1_794_000_000 + Double(number * 919 % 1000) * 60),
                                isRead: isRead,
                                isStarred: isStarred,
                                isFlagged: isStarred
                            ),
                            mailbox: role.rawValue,
                            uid: number
                        ))
                    }
                }
            }
        }
        return messages
    }

    private static var everySelection: [MailboxSelection] {
        MailboxRole.allCases.flatMap { role in
            [.unified(role), .account(first, role), .account(second, role), .account(removed, role)]
        }
    }

    /// すべてのフォルダ × すべての絞り込みで、一覧 (新しい順) と未読数が、画面の決まりで数えたものと同じ。
    private func checkMatchesTheScreenRules(_ store: any MessageStore) async throws {
        let messages = Self.everyKindOfMessage()
        try await store.upsert(messages)

        for selection in Self.everySelection {
            for filter in MessageFilter.allCases {
                let query = MessageQuery(accounts: Self.registered, selection: selection, filter: filter)
                let expected = messages.map(\.summary)
                    .filter { Self.registered.contains($0.accountID) && selection.contains($0) && filter.matches($0) }
                    .sorted { $0.date > $1.date }

                #expect(try await store.summaries(matching: query) == expected, "\(selection) \(filter)")
                #expect(try await store.unreadCount(matching: query) == expected.count { !$0.isRead }, "\(selection) \(filter)")
            }
        }

        // 念のため、いくつかは数で確かめる (上の比べ方が空どうしで通っていないこと)
        #expect(try await store.summaries(matching: MessageQuery(accounts: Self.registered, selection: .unified(.inbox))).count == 8)
        #expect(try await store.unreadCount(matching: MessageQuery(accounts: Self.registered, selection: .unified(.inbox))) == 4)
        // スター付きは、迷惑メールとゴミ箱を除く 4 フォルダ × 既読・未読 × 2 アカウント
        #expect(try await store.summaries(matching: MessageQuery(accounts: Self.registered, selection: .unified(.starred))).count == 16)
        #expect(try await store.summaries(matching: MessageQuery(accounts: Self.registered, selection: .account(Self.removed, .inbox))).isEmpty)

        // 登録中のアカウントが 1 つもなければ、何も出さない (削除したアカウントのメールが残っていても)
        let nobody = MessageQuery(accounts: [], selection: .unified(.inbox))
        #expect(try await store.summaries(matching: nobody).isEmpty)
        #expect(try await store.unreadCount(matching: nobody) == 0)
    }

    @Test func inMemoryStoreFollowsTheScreenRules() async throws {
        try await checkMatchesTheScreenRules(InMemoryMessageStore())
    }

    #if canImport(SwiftData)
    @Test func swiftDataStoreFollowsTheScreenRules() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageQueryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await checkMatchesTheScreenRules(SwiftDataMessageStore(directory: directory))
    }
    #endif
}
