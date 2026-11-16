import Foundation
import Testing
@testable import MailStore

/// 外部の画像をいつも表示する差出人 (T33、US-5)。アドレスがちょうど同じときだけ。
@Suite struct TrustedImageSenderStoreTests {
    @Test func remembersTheAddressTrimmedAndLowercased() throws {
        let store = TrustedImageSenderStore(storage: InMemoryAccountListStorage())
        try store.trust("  Shop@Example.COM \n")
        #expect(store.addresses() == ["shop@example.com"])
        #expect(store.contains("shop@example.com"))
        #expect(store.contains("SHOP@example.com"))
    }

    @Test func anotherAddressAtTheSameDomainIsNotTrusted() throws {
        let store = TrustedImageSenderStore(storage: InMemoryAccountListStorage())
        try store.trust("shop@example.com")
        #expect(!store.contains("news@example.com"))
        #expect(!store.contains("example.com"))
        #expect(!store.contains("shop@example.com.evil.test"))
    }

    @Test func anEmptyAddressIsNeverRememberedOrTrusted() throws {
        let store = TrustedImageSenderStore(storage: InMemoryAccountListStorage())
        try store.trust("   ")
        #expect(store.addresses().isEmpty)
        #expect(!store.contains(""))
        #expect(TrustedImageSenderStore.key(for: " \n") == nil)
    }

    @Test func trustingTwiceKeepsOneEntry() throws {
        let store = TrustedImageSenderStore(storage: InMemoryAccountListStorage())
        try store.trust("shop@example.com")
        try store.trust("SHOP@example.com")
        #expect(store.addresses() == ["shop@example.com"])
    }

    @Test func removingStopsTrustingOnlyThatAddressAndSurvivesReopening() throws {
        let storage = InMemoryAccountListStorage()
        let store = TrustedImageSenderStore(storage: storage)
        try store.trust("shop@example.com")
        try store.trust("news@example.org")
        try store.remove("Shop@Example.com")
        let reopened = TrustedImageSenderStore(storage: storage)
        #expect(reopened.addresses() == ["news@example.org"])
        #expect(!reopened.contains("shop@example.com"))
    }

    @Test func trustedAddressesSurviveReopening() throws {
        let storage = InMemoryAccountListStorage()
        try TrustedImageSenderStore(storage: storage).trust("shop@example.com")
        #expect(TrustedImageSenderStore(storage: storage).contains("shop@example.com"))
    }

    @Test func brokenSavedDataReadsAsEmpty() throws {
        let storage = InMemoryAccountListStorage()
        try storage.save(Data("not json".utf8))
        let store = TrustedImageSenderStore(storage: storage)
        #expect(store.addresses().isEmpty)
        try store.trust("shop@example.com")
        #expect(store.addresses() == ["shop@example.com"])
    }
}
