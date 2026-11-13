import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OAuth 2.0 の接続先。
public struct OAuthConfiguration: Sendable {
    public var clientID: String
    /// Google の「デスクトップ アプリ」用クライアントには必要。秘密としては扱えない値だが、リポジトリには置かない。
    public var clientSecret: String?
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var scopes: [String]

    /// Gmail 用。`https://mail.google.com/` が IMAP / SMTP に必要な権限。`openid email` はメールアドレスを知るため。
    public static func google(clientID: String, clientSecret: String?) -> OAuthConfiguration {
        OAuthConfiguration(
            clientID: clientID,
            clientSecret: clientSecret,
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            scopes: ["https://mail.google.com/", "openid", "email"]
        )
    }
}

/// PKCE (RFC 7636)。認可コードを横取りされても使えないようにする。
public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init() {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<48).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        self.init(verifier: Base64URL.encode(Data(bytes)))
    }

    init(verifier: String) {
        self.verifier = verifier
        challenge = Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

public struct OAuthTokens: Codable, Sendable, Equatable, CustomStringConvertible {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    /// ID トークンから読んだメールアドレス。
    public var email: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.email = email
    }

    public var description: String {
        "OAuthTokens(email: \(email ?? "-"), expiresAt: \(expiresAt), <redacted>)"
    }
}

public enum OAuthError: Error, Equatable {
    /// ログイン画面で「キャンセル」された。
    case userCancelled
    /// 戻ってきた `state` が違う (別の画面から送られた可能性がある)。
    case stateMismatch
    /// 戻ってきた URL に認可コードがない。
    case missingCode
    /// 更新用トークンが無効 (取り消された、期限切れ)。もう一度ログインが必要。
    case invalidGrant
    /// このアカウントのトークンが保存されていない。
    case notSignedIn
    case server(status: Int, message: String)
    case invalidResponse
    case network(String)
    case storage(String)
}

/// フォームを POST する HTTP。テストでは偽物に差し替える。
public protocol HTTPClient: Sendable {
    func postForm(_ url: URL, fields: [String: String]) async throws -> (status: Int, body: Data)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func postForm(_ url: URL, fields: [String: String]) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode(fields).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// 認可 URL の組み立て、認可コードとトークンの交換、トークンの更新。
public struct OAuthClient: Sendable {
    public let configuration: OAuthConfiguration
    private let http: any HTTPClient
    private let now: @Sendable () -> Date

    public init(configuration: OAuthConfiguration, http: any HTTPClient = URLSessionHTTPClient(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.http = http
        self.now = now
    }

    public func authorizationURL(redirectURI: String, state: String, pkce: PKCE, loginHint: String? = nil) -> URL {
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // 更新用トークンを必ずもらうため (2 回目以降のログインでも)
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
        ]
        if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = items
        return components.url!
    }

    /// ブラウザから戻ってきた URL から認可コードを取り出す。
    public static func authorizationCode(from redirect: URL, expectedState: String) throws(OAuthError) -> String {
        let items = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if query["error"] == "access_denied" { throw .userCancelled }
        guard query["state"] == expectedState else { throw .stateMismatch }
        guard let code = query["code"], !code.isEmpty else { throw .missingCode }
        return code
    }

    public func exchange(code: String, pkce: PKCE, redirectURI: String) async throws(OAuthError) -> OAuthTokens {
        let response = try await post([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": pkce.verifier,
            "redirect_uri": redirectURI,
        ])
        return OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: now().addingTimeInterval(response.expiresIn),
            email: response.idToken.flatMap(IDToken.email)
        )
    }

    public func refresh(_ tokens: OAuthTokens) async throws(OAuthError) -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else { throw .invalidGrant }
        let response = try await post(["grant_type": "refresh_token", "refresh_token": refreshToken])
        return OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            expiresAt: now().addingTimeInterval(response.expiresIn),
            email: response.idToken.flatMap(IDToken.email) ?? tokens.email
        )
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: TimeInterval
        let refreshToken: String?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    private func post(_ fields: [String: String]) async throws(OAuthError) -> TokenResponse {
        var fields = fields
        fields["client_id"] = configuration.clientID
        if let secret = configuration.clientSecret { fields["client_secret"] = secret }

        let status: Int
        let body: Data
        do {
            (status, body) = try await http.postForm(configuration.tokenEndpoint, fields: fields)
        } catch {
            throw .network(error.localizedDescription)
        }
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: body))?.error ?? ""
            if message == "invalid_grant" { throw .invalidGrant }
            throw .server(status: status, message: message)
        }
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: body) else {
            throw .invalidResponse
        }
        return response
    }
}

/// ID トークン (JWT) の中身からメールアドレスを読む。
/// トークンは TLS でトークンの窓口から直接受け取ったものなので、署名の確認はしない (OpenID Connect Core 3.1.3.7)。
enum IDToken {
    static func email(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payload = Base64URL.decode(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return object["email"] as? String
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

enum FormEncoding {
    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
    }

    private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
