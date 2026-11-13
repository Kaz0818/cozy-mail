import Foundation

/// HTML メールから、一覧の書き出しや検索に使う文章を取り出す。見た目の再現はしない (表示は WebView で行う)。
public enum HTMLText {
    public static func plainText(from html: String) -> String {
        var text = html
        // 中身を表示しない要素は、中身ごと消す
        for tag in ["head", "style", "script", "title"] {
            text = replace("<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", in: text, with: " ")
        }
        // 行やブロックの区切りは改行に、表のセルは空白にする
        text = replace("<br\\s*/?>", in: text, with: "\n")
        text = replace("</(p|div|tr|li|h[1-6]|blockquote|table|ul|ol)\\s*>", in: text, with: "\n")
        text = replace("</t[dh]\\s*>", in: text, with: " ")
        // 残りのタグを消す
        text = replace("<[^>]+>", in: text, with: "")
        text = decodeEntities(text)

        // 行ごとに空白を詰め、空行は 1 行まで
        var lines: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" || $0 == "\r" })
                .joined(separator: " ")
            if line.isEmpty {
                if let last = lines.last, !last.isEmpty { lines.append("") }
            } else {
                lines.append(line)
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: template)
        )
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "©", "reg": "®", "yen": "¥",
        "hellip": "…", "mdash": "—", "ndash": "–", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
    ]

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            output += rest[..<amp]
            let afterAmp = rest[rest.index(after: amp)...]
            if let semicolon = afterAmp.prefix(10).firstIndex(of: ";"), let decoded = decode(String(afterAmp[..<semicolon])) {
                output += decoded
                rest = afterAmp[afterAmp.index(after: semicolon)...]
            } else {
                output += "&"
                rest = afterAmp
            }
        }
        return output + rest
    }

    private static func decode(_ entity: String) -> String? {
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            return UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if entity.hasPrefix("#") {
            return UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return namedEntities[entity.lowercased()]
    }
}
