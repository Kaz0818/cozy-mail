import AccountKit
import Foundation
import MailStore
import Testing
@testable import CozyMail

/// 外部の画像をいつも表示する差出人 (T33)。本文の画面は待たずに答えを読むので、起動したときから答えられること。
@MainActor @Suite struct MailServiceTrustedImageSendersTests {
    private func makeService(_ storage: InMemoryAccountListStorage) -> MailService {
        MailService(
            directory: AccountDirectory(storage: InMemoryAccountListStorage(), secrets: InMemorySecretStore()),
            store: InMemoryMessageStore(),
            imageSenders: TrustedImageSenderStore(storage: storage)
        )
    }

    @Test func answersRightAfterStartingWithoutWaiting() throws {
        let storage = InMemoryAccountListStorage()
        try TrustedImageSenderStore(storage: storage).trust("shop@example.com")
        let service = makeService(storage)
        #expect(service.showsImages(from: "Shop@Example.com"))
        #expect(!service.showsImages(from: "news@example.com"))
        #expect(service.trustedImageSenders == ["shop@example.com"])
    }

    @Test func trustingIsSavedAndShownAtOnce() throws {
        let storage = InMemoryAccountListStorage()
        let service = makeService(storage)
        try service.trustImages(from: "shop@example.com")
        #expect(service.showsImages(from: "shop@example.com"))
        #expect(TrustedImageSenderStore(storage: storage).contains("shop@example.com"))
    }

    @Test func removingFromSettingsBlocksImagesAgain() throws {
        let storage = InMemoryAccountListStorage()
        let service = makeService(storage)
        try service.trustImages(from: "shop@example.com")
        try service.stopTrustingImages(from: "shop@example.com")
        #expect(!service.showsImages(from: "shop@example.com"))
        #expect(service.trustedImageSenders.isEmpty)
        #expect(!TrustedImageSenderStore(storage: storage).contains("shop@example.com"))
    }

    @Test func anEmptySenderIsNeverTrusted() throws {
        let service = makeService(InMemoryAccountListStorage())
        try service.trustImages(from: "  ")
        #expect(!service.showsImages(from: ""))
        #expect(service.trustedImageSenders.isEmpty)
    }

    /// 既定 (テストと `-ui-testing` の `preview()`) では、本物の UserDefaults に書かない。
    @Test func theDefaultsDoNotWriteTheRealUserDefaults() throws {
        let key = "trustedImageSenders.v1"
        let before = UserDefaults.standard.data(forKey: key)
        try MailService.preview().trustImages(from: "ui-test@example.com")
        try MailService(
            directory: AccountDirectory(storage: InMemoryAccountListStorage(), secrets: InMemorySecretStore()),
            store: InMemoryMessageStore()
        ).trustImages(from: "unit-test@example.com")
        #expect(UserDefaults.standard.data(forKey: key) == before)
    }
}
