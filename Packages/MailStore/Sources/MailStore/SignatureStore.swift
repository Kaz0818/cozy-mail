import Foundation

/// アカウントごとの署名の保存 (T25、US-16)。
/// アカウント一覧 (`accounts.v1`) とは別の場所に置く (アカウント一覧の保存の形を変えないため)。アプリでは UserDefaults の `signatures.v1`。
public actor SignatureStore {
    private let storage: any AccountListStorage
    private var cache: [String: String]?

    public init(storage: any AccountListStorage) {
        self.storage = storage
    }

    /// アプリで使う保存先。
    public static func live() -> SignatureStore {
        SignatureStore(storage: UserDefaultsAccountListStorage(key: "signatures.v1"))
    }

    /// 署名。なければ空。
    public func signature(for id: AccountID) -> String {
        load()[id.rawValue] ?? ""
    }

    /// すべての署名 (アカウントの ID ごと)。
    public func all() -> [AccountID: String] {
        Dictionary(uniqueKeysWithValues: load().map { (AccountID($0.key), $0.value) })
    }

    /// 署名を保存する。前後の空白を除いて空なら、消す。
    public func setSignature(_ signature: String, for id: AccountID) throws {
        var list = load()
        let trimmed = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        list[id.rawValue] = trimmed.isEmpty ? nil : trimmed
        try save(list)
    }

    /// アカウントを消したときに、その署名も消す。
    public func remove(_ id: AccountID) throws {
        var list = load()
        list[id.rawValue] = nil
        try save(list)
    }

    private func load() -> [String: String] {
        if let cache { return cache }
        let decoded = (try? storage.load()).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = decoded
        return decoded
    }

    private func save(_ list: [String: String]) throws {
        try storage.save(JSONEncoder().encode(list))
        cache = list
    }
}
