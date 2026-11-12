import Foundation
import Testing
@testable import AccountKit

@Suite struct TokenManagerTests {
    let account = "gmail-work"

    @Test func returnsTheStoredTokenWhileItIsStillValid() async throws {
        let store = InMemorySecretStore()
        let manager = TokenManager(client: makeClient(FakeHTTP([])), store: store, now: { fixedNow })
        try await manager.save(
            OAuthTokens(accessToken: "valid", refreshToken: "1//r", expiresAt: fixedNow.addingTimeInterval(600), email: nil),
            for: account
        )
        #expect(try await manager.accessToken(for: account) == "valid")
    }

    @Test func refreshesWhenAboutToExpireAndSavesTheNewToken() async throws {
        let store = InMemorySecretStore()
        let http = FakeHTTP([(200, #"{"access_token":"fresh","expires_in":3600}"#)])
        let manager = TokenManager(client: makeClient(http), store: store, now: { fixedNow })
        try await manager.save(
            OAuthTokens(accessToken: "stale", refreshToken: "1//r", expiresAt: fixedNow.addingTimeInterval(30), email: nil),
            for: account
        )

        #expect(try await manager.accessToken(for: account) == "fresh")
        #expect(try await manager.accessToken(for: account) == "fresh")
        #expect(http.requests.count == 1)
        let saved = try #require(try store.data(for: "oauth.\(account)"))
        #expect(try JSONDecoder().decode(OAuthTokens.self, from: saved).accessToken == "fresh")
    }

    @Test func unknownAccountThrowsNotSignedIn() async {
        let manager = TokenManager(client: makeClient(FakeHTTP([])), store: InMemorySecretStore(), now: { fixedNow })
        await #expect(throws: OAuthError.notSignedIn) { _ = try await manager.accessToken(for: "nobody") }
    }

    @Test func revokedRefreshTokenRemovesTheTokensSoTheUserSignsInAgain() async throws {
        let store = InMemorySecretStore()
        let http = FakeHTTP([(400, #"{"error":"invalid_grant"}"#)])
        let manager = TokenManager(client: makeClient(http), store: store, now: { fixedNow })
        try await manager.save(OAuthTokens(accessToken: "x", refreshToken: "1//r", expiresAt: fixedNow, email: nil), for: account)

        await #expect(throws: OAuthError.invalidGrant) { _ = try await manager.accessToken(for: account) }
        #expect(try store.data(for: "oauth.\(account)") == nil)
    }

    @Test func signOutDeletesTheTokens() async throws {
        let store = InMemorySecretStore()
        let manager = TokenManager(client: makeClient(FakeHTTP([])), store: store, now: { fixedNow })
        try await manager.save(OAuthTokens(accessToken: "x", refreshToken: nil, expiresAt: fixedNow, email: nil), for: account)
        try await manager.signOut(account)
        #expect(try store.data(for: "oauth.\(account)") == nil)
    }
}
