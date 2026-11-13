import Foundation

/// HTML メールを安全に表示するための文書づくり (SPEC 7)。
///
/// - JavaScript は WebView の設定で止める。それに加えて、ここで作る Content-Security-Policy でスクリプトを一切許さない。
/// - 外部の画像・スタイル・フォントは、`allowsRemoteContent` が true になるまで読み込まない (開封の追跡を防ぐ)。
///   本文に埋め込まれた画像 (data: URL) はいつでも表示する。
enum SafeHTML {
    /// 外から読み込むもの (画像・背景・スタイルシート) があるか。「画像を表示」ボタンを出すかどうかに使う。
    /// ふつうのリンク (`<a href>`) は読み込みではないので含めない。
    static func hasRemoteContent(_ html: String) -> Bool {
        html.range(of: remotePattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let remotePattern =
        #"(\b(src|background|poster)\s*=\s*["']?\s*https?:)|(url\(\s*["']?\s*https?:)|(<link\b[^>]*\bhref\s*=\s*["']?\s*https?:)"#

    /// 表示用の HTML 文書。決まりごと (CSP) を一番先頭に置くので、メールの中身全体に効く。
    static func document(for html: String, allowsRemoteContent: Bool) -> String {
        let remote = allowsRemoteContent ? " https: http:" : ""
        let policy = [
            "default-src 'none'",
            "img-src data:\(remote)",
            "style-src 'unsafe-inline'\(remote)",
            "font-src data:\(remote)",
            "media-src data:\(remote)",
        ].joined(separator: "; ")
        return """
        <!doctype html><html><head>\
        <meta http-equiv="Content-Security-Policy" content="\(policy)">\
        <meta charset="utf-8"><meta name="color-scheme" content="light">\
        <style>\(baseStyle)</style></head><body>\(html)</body></html>
        """
    }

    /// メールの多くは白い背景を前提に作られているので、白い紙の上に表示する。
    private static let baseStyle = """
    html,body{margin:0;padding:0;background:#fff;}\
    body{padding:20px 24px;font:15px -apple-system,"Hiragino Sans",sans-serif;color:#111;line-height:1.6;\
    word-wrap:break-word;overflow-wrap:anywhere;}\
    img{max-width:100%;height:auto;}table{max-width:100%;}pre{white-space:pre-wrap;}
    """

    /// 添付ファイルを保存するときの名前。フォルダをまたげる文字は使わせない。
    static func safeFileName(_ name: String) -> String {
        var cleaned = String(name.map { "/:\\".contains($0) ? "_" : $0 })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "attachment" : cleaned
    }
}
