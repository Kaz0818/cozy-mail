import Foundation
import Testing
@testable import MailStore

/// アカウントごとの署名 (T25、US-16)。
@Suite struct SignatureTests {
    private let account = AccountID("a")
    private let source = ReplySource(
        accountID: AccountID("a"), from: [Contact(name: "田中", address: "t@example.com")],
        to: [Contact(name: "", address: "me@example.com")], subject: "会議",
        date: Date(timeIntervalSince1970: 1_794_000_000), messageID: "m1@example.com", text: "よろしく"
    )

    @Test func aNewMessageEndsWithTheSignature() {
        let draft = Composer.draft(.new, replyingTo: nil, myAddresses: [], defaultAccount: account, signature: "山田 太郎\n株式会社サンプル")
        #expect(draft.body == "\n\n-- \n山田 太郎\n株式会社サンプル")
    }

    @Test func aReplyPutsTheSignatureAboveTheQuote() {
        let draft = Composer.draft(.reply, replyingTo: source, myAddresses: [], defaultAccount: nil, signature: "山田",
                                   timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(draft.body.hasPrefix("\n\n-- \n山田\n\n"))
        #expect(draft.body.contains("> よろしく"))
        let signature = try! #require(draft.body.range(of: "-- \n山田"))
        let quote = try! #require(draft.body.range(of: "> よろしく"))
        #expect(signature.lowerBound < quote.lowerBound)
    }

    @Test func aForwardPutsTheSignatureAboveTheForwardedMessage() {
        let draft = Composer.draft(.forward, replyingTo: source, myAddresses: [], defaultAccount: nil, signature: "山田")
        #expect(draft.body.hasPrefix("\n\n-- \n山田\n\n---------- 転送されたメッセージ ----------"))
    }

    @Test func anEmptySignatureAddsNothing() {
        #expect(Composer.draft(.new, replyingTo: nil, myAddresses: [], defaultAccount: account, signature: "  \n").body == "")
        let reply = Composer.draft(.reply, replyingTo: source, myAddresses: [], defaultAccount: nil, signature: "")
        #expect(!reply.body.contains("-- \n"))
    }

    // MARK: - 差出人を変えたとき

    @Test func switchingAccountsSwapsTheSignatureAndKeepsWhatYouWrote() {
        let body = "こんにちは\n\n-- \n山田 (仕事)"
        #expect(Composer.replacingSignature(in: body, old: "山田 (仕事)", new: "やまだ", quote: "") == "こんにちは\n\n-- \nやまだ")
    }

    @Test func switchingToAnAccountWithoutASignatureRemovesIt() {
        let body = "こんにちは\n\n-- \n山田"
        #expect(Composer.replacingSignature(in: body, old: "山田", new: "", quote: "") == "こんにちは")
    }

    @Test func switchingFromNoSignatureAddsOneAtTheEndOfANewMessage() {
        #expect(Composer.replacingSignature(in: "こんにちは", old: "", new: "山田", quote: "") == "こんにちは\n\n-- \n山田")
    }

    @Test func switchingFromNoSignatureAddsOneAboveTheQuote() {
        let draft = Composer.draft(.reply, replyingTo: source, myAddresses: [], defaultAccount: nil, signature: "")
        let body = "返事です" + draft.body
        let swapped = Composer.replacingSignature(in: body, old: "", new: "山田", quote: draft.quote)
        #expect(swapped == "返事です\n\n-- \n山田" + draft.body)
    }

    /// 署名を手で消していたら、勝手に戻さない。
    @Test func aSignatureYouDeletedIsNotPutBack() {
        #expect(Composer.replacingSignature(in: "こんにちは", old: "山田", new: "やまだ", quote: "") == "こんにちは")
    }
}

/// 署名の保存 (アカウント一覧とは別の場所。アカウント一覧の保存の形は変えない)。
@Suite struct SignatureStoreTests {
    @Test func savesAndReadsBackPerAccount() async throws {
        let storage = InMemoryAccountListStorage()
        let store = SignatureStore(storage: storage)
        try await store.setSignature("山田\n株式会社サンプル", for: AccountID("a"))
        try await store.setSignature("やまだ", for: AccountID("b"))
        let reopened = SignatureStore(storage: storage)
        #expect(await reopened.signature(for: AccountID("a")) == "山田\n株式会社サンプル")
        #expect(await reopened.signature(for: AccountID("b")) == "やまだ")
        #expect(await reopened.signature(for: AccountID("c")) == "")
    }

    @Test func anEmptySignatureIsForgotten() async throws {
        let storage = InMemoryAccountListStorage()
        let store = SignatureStore(storage: storage)
        try await store.setSignature("山田", for: AccountID("a"))
        try await store.setSignature("  ", for: AccountID("a"))
        #expect(await store.signature(for: AccountID("a")) == "")
        #expect(await store.all().isEmpty)
    }

    @Test func removingAnAccountForgetsItsSignature() async throws {
        let store = SignatureStore(storage: InMemoryAccountListStorage())
        try await store.setSignature("山田", for: AccountID("a"))
        try await store.remove(AccountID("a"))
        #expect(await store.signature(for: AccountID("a")) == "")
    }
}
