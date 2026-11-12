import Foundation

/// パスワードやトークンを保存する場所。アプリではキーチェーン (`AccountKitKeychain`)、テストではメモリ上を使う。
public protocol SecretStore: Sendable {
    func data(for key: String) throws -> Data?
    /// `nil` を渡すと消す。
    func set(_ data: Data?, for key: String) throws
}

public struct SecretStoreError: Error, Equatable, CustomStringConvertible {
    public let status: Int32
    public let operation: String

    public init(status: Int32, operation: String) {
        self.status = status
        self.operation = operation
    }

    public var description: String {
        "秘密情報の\(operation)に失敗しました (コード \(status))"
    }
}

/// テストと SwiftUI プレビュー用。アプリを終了すると消える。
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init() {}

    public func data(for key: String) throws -> Data? {
        lock.withLock { storage[key] }
    }

    public func set(_ data: Data?, for key: String) throws {
        lock.withLock { storage[key] = data }
    }
}
