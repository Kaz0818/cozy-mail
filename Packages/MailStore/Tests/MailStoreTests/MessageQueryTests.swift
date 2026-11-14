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

    /// Gmail のラベルの付き方 (メールごとに順に使う)。「仕事」と、その下の「仕事/経理」は別のラベル。
    private static let labelPatterns: [[String]] = [["仕事"], ["仕事/経理"], ["\\Important", "仕事", "趣味"], []]

    /// 差出人 (メールごとに順に使う)。検索で、名前・アドレス・大文字小文字を確かめる。
    private static let senders = [
        Contact(name: "田中 健一", address: "k.tanaka@example.com"),
        Contact(name: "Tanaka Ken", address: "ken@tanaka.example"),
        Contact(name: "山田", address: "yamada@example.jp"),
        Contact(name: "", address: "noreply@shop.example"),
        Contact(name: "佐藤", address: "sato@example.com"),
    ]

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
                                sender: senders[Int(number) % senders.count],
                                subject: number.isMultiple(of: 3) ? "来週の会議について \(number)" : "件名 \(number)",
                                preview: number.isMultiple(of: 4) ? "資料を送ります。ご確認ください" : "",
                                // 919 と 1000 は互いに素なので、72 通の日付はすべて違う
                                date: Date(timeIntervalSince1970: 1_794_000_000 + Double(number * 919 % 1000) * 60),
                                isRead: isRead,
                                isStarred: isStarred,
                                isFlagged: isStarred
                            ),
                            mailbox: role.rawValue,
                            uid: number,
                            labels: labelPatterns[Int(number) % labelPatterns.count]
                        ))
                    }
                }
            }
        }
        return messages
    }

    private static var everySelection: [MailboxSelection] {
        let folders: [MailboxSelection] = MailboxRole.allCases.flatMap { role in
            [.unified(role), .account(first, role), .account(second, role), .account(removed, role)]
        }
        let labels: [MailboxSelection] = ["仕事", "仕事/経理", "趣味", "ない"].flatMap { label in
            [.label(first, label), .label(second, label), .label(removed, label)]
        }
        return folders + labels
    }

    /// すべてのフォルダ × すべての絞り込みで、一覧 (新しい順) と未読数が、画面の決まりで数えたものと同じ。
    private func checkMatchesTheScreenRules(_ store: any MessageStore) async throws {
        let messages = Self.everyKindOfMessage()
        try await store.upsert(messages)

        for selection in Self.everySelection {
            for filter in MessageFilter.allCases {
                let query = MessageQuery(accounts: Self.registered, selection: selection, filter: filter)
                let expected = messages
                    .filter { Self.registered.contains($0.summary.accountID) && selection.contains($0.summary, labels: $0.labels) && filter.matches($0.summary) }
                    .map(\.summary)
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
        // ラベル「仕事」: 1 つのアカウントの 24 通のうち、パターン 0 と 2 の 12 通から、迷惑メールとゴミ箱の 4 通を除いた 8 通
        // (「仕事/経理」だけのメールは入らない)
        let work = try await store.summaries(matching: MessageQuery(accounts: Self.registered, selection: .label(Self.first, "仕事")))
        #expect(work.count == 8)
        #expect(work.allSatisfy { $0.accountID == Self.first && $0.mailbox != .junk && $0.mailbox != .trash })

        // 検索: すべてのフォルダ (迷惑メールとゴミ箱を除く) から探す
        try await checkSearch(store, messages: messages)

        // 登録中のアカウントが 1 つもなければ、何も出さない (削除したアカウントのメールが残っていても)
        let nobody = MessageQuery(accounts: [], selection: .unified(.inbox))
        #expect(try await store.summaries(matching: nobody).isEmpty)
        #expect(try await store.unreadCount(matching: nobody) == 0)
    }

    /// 検索 (T19)。差出人の名前・アドレス・件名・本文の書き出しのどれかに含まれれば当たる。大文字・小文字は区別しない。
    /// 空白で区切った言葉は、すべてを含むものだけ (「田中 会議」)。
    private func checkSearch(_ store: any MessageStore, messages: [StoredMessage]) async throws {
        func expected(_ text: String, selection: MailboxSelection?, filter: MessageFilter) -> [MessageSummary] {
            let words = text.split(separator: " ").map { $0.lowercased() }
            return messages
                .filter { message in
                    let summary = message.summary
                    let inPlace = selection.map { $0.contains(summary, labels: message.labels) }
                        ?? (summary.mailbox != .junk && summary.mailbox != .trash)
                    let fields = [summary.sender.name, summary.sender.address, summary.subject, summary.preview].map { $0.lowercased() }
                    return Self.registered.contains(summary.accountID) && inPlace && filter.matches(summary)
                        && words.allSatisfy { word in fields.contains { $0.contains(word) } }
                }
                .map(\.summary)
                .sorted { $0.date > $1.date }
        }

        let searches = ["田中", "tanaka", "TANAKA", "example.com", "会議", "資料", "ご確認", "ください", "田中 会議", "会議 資料 山田", "ない言葉", "  佐藤  "]
        let selections: [MailboxSelection?] = [nil, .unified(.inbox), .account(Self.first, .sent), .label(Self.first, "仕事")]
        for text in searches {
            for selection in selections {
                for filter in MessageFilter.allCases {
                    let query = MessageQuery(accounts: Self.registered, selection: selection, filter: filter, searchText: text)
                    let want = expected(text, selection: selection, filter: filter)
                    #expect(try await store.summaries(matching: query) == want, "「\(text)」 \(String(describing: selection)) \(filter)")
                }
            }
        }

        // 念のため、数でも確かめる
        let everywhere = { (text: String) in MessageQuery(accounts: Self.registered, selection: nil, searchText: text) }
        // 差出人が「田中 健一」(アドレスに tanaka) か「Tanaka Ken」のメール。登録中の 2 アカウントの、迷惑メールとゴミ箱以外で 14 通
        let tanaka = try await store.summaries(matching: everywhere("tanaka"))
        #expect(tanaka.count == 14)
        #expect(tanaka.allSatisfy { $0.mailbox != .junk && $0.mailbox != .trash })
        #expect(try await store.summaries(matching: everywhere("ない言葉")).isEmpty)
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
