import Foundation
import Testing
@testable import MailStore
#if canImport(SwiftData)
@testable import MailStoreSwiftData
#endif

/// アカウントごとの Gmail のラベルの一覧 (サイドバーに出すもの、T13)。どの保存先でも同じに動く。
@Suite struct AccountLabelsTests {
    private let gmail = AccountID("gmail")
    private let other = AccountID("other")

    private func checkLabels(_ store: any MessageStore) async throws {
        #expect(try await store.labels(account: gmail).isEmpty)

        try await store.setLabels(["仕事", "仕事/経理"], account: gmail)
        try await store.setLabels(["趣味"], account: other)
        #expect(try await store.labels(account: gmail) == ["仕事", "仕事/経理"])

        // 同期のたびに、サーバーの一覧で置き換える
        try await store.setLabels(["Work"], account: gmail)
        #expect(try await store.labels(account: gmail) == ["Work"])

        // アカウントを削除したら、そのアカウントの一覧だけ消える
        try await store.deleteAccount(gmail)
        #expect(try await store.labels(account: gmail).isEmpty)
        #expect(try await store.labels(account: other) == ["趣味"])
    }

    @Test func inMemoryStoreKeepsLabelsPerAccount() async throws {
        try await checkLabels(InMemoryMessageStore())
    }

    #if canImport(SwiftData)
    @Test func swiftDataStoreKeepsLabelsPerAccount() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountLabelsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await checkLabels(SwiftDataMessageStore(directory: directory))
    }
    #endif
}
