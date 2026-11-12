import Foundation

/// アカウントごとの OAuth トークンを保存し、期限が近ければ更新して渡す。
public actor TokenManager {
    /// 期限まで残りがこれより短ければ、先に更新する。
    private static let refreshMargin: TimeInterval = 120

    private let client: OAuthClient
    private let store: any SecretStore
    private let now: @Sendable () -> Date

    public init(client: OAuthClient, store: any SecretStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.store = store
        self.now = now
    }

    public func save(_ tokens: OAuthTokens, for account: String) throws(OAuthError) {
        do {
            try store.set(JSONEncoder().encode(tokens), for: Self.key(account))
        } catch {
            throw .storage(String(describing: error))
        }
    }

    /// 使えるアクセストークンを返す。更新用トークンが無効なら保存分を消して `invalidGrant` を投げる。
    public func accessToken(for account: String) async throws(OAuthError) -> String {
        let tokens = try load(account)
        if tokens.expiresAt.timeIntervalSince(now()) > Self.refreshMargin {
            return tokens.accessToken
        }
        do {
            let refreshed = try await client.refresh(tokens)
            try save(refreshed, for: account)
            return refreshed.accessToken
        } catch .invalidGrant {
            try? signOut(account)
            throw .invalidGrant
        }
    }

    public func signOut(_ account: String) throws(OAuthError) {
        do {
            try store.set(nil, for: Self.key(account))
        } catch {
            throw .storage(String(describing: error))
        }
    }

    private func load(_ account: String) throws(OAuthError) -> OAuthTokens {
        let data: Data?
        do {
            data = try store.data(for: Self.key(account))
        } catch {
            throw .storage(String(describing: error))
        }
        guard let data else { throw .notSignedIn }
        guard let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) else { throw .notSignedIn }
        return tokens
    }

    static func key(_ account: String) -> String {
        "oauth.\(account)"
    }
}
