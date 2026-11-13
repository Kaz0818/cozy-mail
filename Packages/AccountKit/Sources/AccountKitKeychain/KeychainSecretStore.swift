#if canImport(Security)
import AccountKit
import Foundation
import Security

/// macOS のキーチェーンに保存する。この Mac だけに置き、iCloud には同期しない。
/// アプリを作り直すたびに「キーチェーンを使おうとしています」と聞かれることがある (署名が変わるため)。「常に許可」を選ぶ。
/// 無料の Apple ID で署名すると、作り直しても聞かれなくなる (docs/signing.md)。
public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "com.cozymail.secrets") {
        self.service = service
    }

    public func data(for key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw SecretStoreError(status: status, operation: "読み込み")
        }
    }

    public func set(_ data: Data?, for key: String) throws {
        guard let data else {
            let status = SecItemDelete(baseQuery(key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError(status: status, operation: "削除")
            }
            return
        }
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(key)
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecretStoreError(status: addStatus, operation: "保存") }
        } else if status != errSecSuccess {
            throw SecretStoreError(status: status, operation: "保存")
        }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
            // データ保護キーチェーン (kSecUseDataProtectionKeychain) は、有料の開発者アカウントで署名したアプリでないと
            // 使えない (errSecMissingEntitlement)。自分の Mac で署名して使う (SPEC 2.1) ので、通常のキーチェーンを使う
        ]
    }
}
#endif
