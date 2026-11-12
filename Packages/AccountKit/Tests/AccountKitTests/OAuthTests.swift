import Foundation
import Testing
@testable import AccountKit

/// 決まった応答を返し、送られた内容を記録する偽の HTTP。
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, String)]
    private(set) var requests: [(url: URL, fields: [String: String])] = []

    init(_ responses: [(Int, String)]) {
        self.responses = responses
    }

    func postForm(_ url: URL, fields: [String: String]) async throws -> (status: Int, body: Data) {
        lock.withLock {
            requests.append((url, fields))
            let (status, body) = responses.removeFirst()
            return (status, Data(body.utf8))
        }
    }
}

/// `{"email": ...}` を中身に持つ、署名なしの ID トークン。
func makeIDToken(email: String) -> String {
    func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return base64URL(#"{"alg":"RS256"}"#) + "." + base64URL(#"{"email":"\#(email)","email_verified":true}"#) + ".sig"
}

let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

func makeClient(_ http: FakeHTTP) -> OAuthClient {
    OAuthClient(
        configuration: .google(clientID: "client-123.apps.googleusercontent.com", clientSecret: "shh"),
        http: http,
        now: { fixedNow }
    )
}

@Suite struct PKCETests {
    /// 期待値は Python (hashlib.sha256 + urlsafe_b64encode) で別に計算したもの。
    @Test func challengeIsBase64URLOfSHA256OfVerifier() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mJ92IoKjRJ6sS84jeQzX7JN3hT8vKM")
        #expect(pkce.challenge == "lIGPQlvglmog_Zvgzsmnuu1f9DQMAoB34SVnAJZH0LY")
    }

    @Test func randomVerifierIsLongAndURLSafe() {
        let verifier = PKCE().verifier
        #expect((43...128).contains(verifier.count))
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(verifier.allSatisfy { allowed.contains($0) })
        #expect(PKCE().verifier != verifier)
    }
}

@Suite struct OAuthClientTests {
    @Test func authorizationURLHasTheRequiredParameters() throws {
        let client = makeClient(FakeHTTP([]))
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mJ92IoKjRJ6sS84jeQzX7JN3hT8vKM")
        let url = client.authorizationURL(
            redirectURI: "http://127.0.0.1:5000", state: "state-1", pkce: pkce, loginHint: "me@gmail.com"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(components.host == "accounts.google.com")
        #expect(query == [
            "client_id": "client-123.apps.googleusercontent.com",
            "redirect_uri": "http://127.0.0.1:5000",
            "response_type": "code",
            "scope": "https://mail.google.com/ openid email",
            "state": "state-1",
            "code_challenge": "lIGPQlvglmog_Zvgzsmnuu1f9DQMAoB34SVnAJZH0LY",
            "code_challenge_method": "S256",
            "access_type": "offline",
            "prompt": "consent select_account",
            "login_hint": "me@gmail.com",
        ])
    }

    @Test func redirectWithCodeAndMatchingStateReturnsCode() throws {
        let url = try #require(URL(string: "http://127.0.0.1:5000/?state=s1&code=4%2FabcDEF&scope=x"))
        #expect(try OAuthClient.authorizationCode(from: url, expectedState: "s1") == "4/abcDEF")
    }

    @Test func redirectWithWrongStateIsRejected() throws {
        let url = try #require(URL(string: "http://127.0.0.1:5000/?state=evil&code=abc"))
        #expect(throws: OAuthError.stateMismatch) { try OAuthClient.authorizationCode(from: url, expectedState: "s1") }
    }

    @Test func redirectWithAccessDeniedMeansUserCancelled() throws {
        let url = try #require(URL(string: "http://127.0.0.1:5000/?error=access_denied&state=s1"))
        #expect(throws: OAuthError.userCancelled) { try OAuthClient.authorizationCode(from: url, expectedState: "s1") }
    }

    @Test func exchangeSendsCodeAndVerifierAndReadsTokensAndEmail() async throws {
        let http = FakeHTTP([(200, """
        {"access_token":"ya29.access","expires_in":3599,"refresh_token":"1//refresh",
         "scope":"https://mail.google.com/ openid email","token_type":"Bearer","id_token":"\(makeIDToken(email: "me@gmail.com"))"}
        """)])
        let pkce = PKCE(verifier: "verifier-abc")
        let tokens = try await makeClient(http).exchange(code: "4/abc", pkce: pkce, redirectURI: "http://127.0.0.1:5000")

        #expect(tokens == OAuthTokens(
            accessToken: "ya29.access", refreshToken: "1//refresh",
            expiresAt: fixedNow.addingTimeInterval(3599), email: "me@gmail.com"
        ))
        let request = try #require(http.requests.first)
        #expect(request.url.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.fields == [
            "grant_type": "authorization_code", "code": "4/abc", "code_verifier": "verifier-abc",
            "redirect_uri": "http://127.0.0.1:5000", "client_id": "client-123.apps.googleusercontent.com",
            "client_secret": "shh",
        ])
    }

    @Test func refreshKeepsTheOldRefreshTokenWhenNoneIsReturned() async throws {
        let http = FakeHTTP([(200, #"{"access_token":"ya29.new","expires_in":3600,"token_type":"Bearer"}"#)])
        let old = OAuthTokens(accessToken: "old", refreshToken: "1//keep", expiresAt: fixedNow, email: "me@gmail.com")
        let tokens = try await makeClient(http).refresh(old)

        #expect(tokens == OAuthTokens(
            accessToken: "ya29.new", refreshToken: "1//keep", expiresAt: fixedNow.addingTimeInterval(3600),
            email: "me@gmail.com"
        ))
        #expect(http.requests.first?.fields["grant_type"] == "refresh_token")
        #expect(http.requests.first?.fields["refresh_token"] == "1//keep")
    }

    @Test func revokedRefreshTokenThrowsInvalidGrant() async throws {
        let http = FakeHTTP([(400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)])
        let old = OAuthTokens(accessToken: "old", refreshToken: "1//gone", expiresAt: fixedNow, email: nil)
        await #expect(throws: OAuthError.invalidGrant) { _ = try await makeClient(http).refresh(old) }
    }

    @Test func otherServerErrorsCarryTheMessage() async throws {
        let http = FakeHTTP([(500, #"{"error":"internal_failure"}"#)])
        let old = OAuthTokens(accessToken: "old", refreshToken: "1//r", expiresAt: fixedNow, email: nil)
        await #expect(throws: OAuthError.server(status: 500, message: "internal_failure")) {
            _ = try await makeClient(http).refresh(old)
        }
    }

    @Test func tokensDescriptionNeverContainsSecrets() {
        let tokens = OAuthTokens(accessToken: "ya29.secret", refreshToken: "1//secret", expiresAt: fixedNow, email: "a@b")
        #expect(!String(describing: tokens).contains("secret"))
    }
}
