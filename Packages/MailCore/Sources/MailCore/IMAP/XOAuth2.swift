/// SASL XOAUTH2 (Gmail、Outlook) の最初の応答を作る。
/// 形式: `user=<メールアドレス>^Aauth=Bearer <アクセストークン>^A^A` (^A は 0x01)。送るときに Base64 にする。
enum XOAuth2 {
    static func initialResponse(username: String, accessToken: String) -> String {
        "user=\(username)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
    }
}
