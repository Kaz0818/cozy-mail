import Foundation

/// 外部の画像をいつも表示する差出人の保存 (T33、US-5)。アプリでは UserDefaults の `trustedImageSenders.v1`。
///
/// 外部の画像は、開いたことを送り主に知らせる (追跡) ので、決め方は控えめにする:
/// メールアドレスがちょうど同じときだけ (名前やドメイン全体では決めない)。差出人の欄はなりすませるため。
/// 本文の画面は待たずに答えを読むので、actor ではなく、その場で読み書きする形にしている (呼ぶのはメインスレッドだけ)。
public struct TrustedImageSenderStore: Sendable {
    private let storage: any AccountListStorage

    public init(storage: any AccountListStorage) {
        self.storage = storage
    }

    /// アプリで使う保存先。
    public static func live() -> TrustedImageSenderStore {
        TrustedImageSenderStore(storage: UserDefaultsAccountListStorage(key: "trustedImageSenders.v1"))
    }

    /// 比べるときの形 (前後の空白を除いて小文字)。空なら nil。
    public static func key(for address: String) -> String? {
        let key = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty ? nil : key
    }

    /// 覚えているアドレス (小文字)。
    public func addresses() -> Set<String> {
        let decoded = (try? storage.load()).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return Set(decoded)
    }

    public func contains(_ address: String) -> Bool {
        Self.key(for: address).map { addresses().contains($0) } ?? false
    }

    /// 覚える。空のアドレスは覚えない。
    public func trust(_ address: String) throws {
        guard let key = Self.key(for: address) else { return }
        var list = addresses()
        list.insert(key)
        try save(list)
    }

    public func remove(_ address: String) throws {
        guard let key = Self.key(for: address) else { return }
        var list = addresses()
        list.remove(key)
        try save(list)
    }

    private func save(_ list: Set<String>) throws {
        try storage.save(JSONEncoder().encode(list.sorted()))
    }
}
