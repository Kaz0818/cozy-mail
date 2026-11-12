import Foundation

/// メールアドレスと表示名。
public struct EmailAddress: Hashable, Sendable {
    public var name: String
    public var address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

/// ヘッダーの並び。名前の大文字・小文字は区別しない。
public struct MIMEHeaders: Sendable, Equatable {
    public private(set) var fields: [(name: String, value: String)]

    init(fields: [(name: String, value: String)]) {
        self.fields = fields
    }

    /// 最初に見つかった値 (折り返しは解除済み、エンコードされた単語はそのまま)。
    public subscript(name: String) -> String? {
        let key = name.lowercased()
        return fields.first { $0.name.lowercased() == key }?.value
    }

    public static func == (lhs: MIMEHeaders, rhs: MIMEHeaders) -> Bool {
        lhs.fields.map(\.name) == rhs.fields.map(\.name) && lhs.fields.map(\.value) == rhs.fields.map(\.value)
    }

    /// ヘッダー部分のバイト列を読む。続きの行 (空白で始まる行) は前の行につなげる。
    static func parse(_ bytes: ArraySlice<UInt8>) -> MIMEHeaders {
        let text = Charset.decode(bytes, charset: "utf-8")
        var fields: [(name: String, value: String)] = []
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if let first = line.first, first == " " || first == "\t", !fields.isEmpty {
                fields[fields.count - 1].value += line
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields.append((name, value))
        }
        return MIMEHeaders(fields: fields.map { ($0.name, $0.value.trimmingCharacters(in: .whitespaces)) })
    }
}

/// `type/subtype; key=value; ...` の形のヘッダー値。
struct ParameterizedValue {
    /// 小文字にした本体 (例: `text/plain`)。
    let value: String
    /// 小文字にしたキー → 解除済みの値。RFC 2231 (`filename*=`) と RFC 2047 の両方を解除する。
    let parameters: [String: String]

    init(_ header: String?) {
        let parts = Self.splitOutsideQuotes(header ?? "", separator: ";")
        value = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        parameters = Self.decodeParameters(parts.dropFirst())
    }

    private static func decodeParameters(_ parts: ArraySlice<String>) -> [String: String] {
        var plain: [String: String] = [:]
        // RFC 2231 の分割された値: 名前 → [(番号, 値, エンコードされているか)]
        var extended: [String: [(index: Int, value: String, encoded: Bool)]] = [:]
        for part in parts {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = part[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let raw = unquote(part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            guard let star = key.firstIndex(of: "*") else {
                plain[key] = EncodedWord.decode(raw)
                continue
            }
            let base = String(key[..<star])
            let suffix = key[key.index(after: star)...]
            let encoded = suffix.hasSuffix("*") || suffix.isEmpty
            let index = Int(suffix.trimmingCharacters(in: CharacterSet(charactersIn: "*"))) ?? 0
            extended[base, default: []].append((index, raw, encoded))
        }
        for (base, segments) in extended {
            plain[base] = joinExtended(segments.sorted { $0.index < $1.index })
        }
        return plain
    }

    /// `UTF-8''%E4%BC%81...` のような分割された値をつなげて読む。
    private static func joinExtended(_ segments: [(index: Int, value: String, encoded: Bool)]) -> String {
        var charset: String?
        var bytes: [UInt8] = []
        for (position, segment) in segments.enumerated() {
            var value = Substring(segment.value)
            if position == 0, segment.encoded {
                let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if pieces.count == 3 {
                    charset = String(pieces[0])
                    value = pieces[2]
                }
            }
            bytes += segment.encoded ? percentDecode(value) : Array(value.utf8)
        }
        return Charset.decode(bytes, charset: charset)
    }

    private static func percentDecode(_ text: Substring) -> [UInt8] {
        let utf8 = Array(text.utf8)
        var output: [UInt8] = []
        var index = 0
        while index < utf8.count {
            if utf8[index] == UInt8(ascii: "%"), index + 2 < utf8.count,
               let byte = UInt8(String(decoding: utf8[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                output.append(byte)
                index += 3
            } else {
                output.append(utf8[index])
                index += 1
            }
        }
        return output
    }

    static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.first == "\"", text.last == "\"" else { return text }
        var output = ""
        var escaping = false
        for character in text.dropFirst().dropLast() {
            if escaping {
                output.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                output.append(character)
            }
        }
        return output
    }

    /// 引用符の中と `<...>` の中を除いて区切る。
    static func splitOutsideQuotes(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote = false
        var angleDepth = 0
        var escaping = false
        for character in text {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            switch character {
            case "\\" where inQuote:
                escaping = true
            case "\"":
                inQuote.toggle()
            case "<" where !inQuote:
                angleDepth += 1
            case ">" where !inQuote:
                angleDepth = max(0, angleDepth - 1)
            case separator where !inQuote && angleDepth == 0:
                parts.append(current)
                current = ""
                continue
            default:
                break
            }
            current.append(character)
        }
        parts.append(current)
        return parts
    }
}

enum AddressParser {
    static func parseList(_ header: String?) -> [EmailAddress] {
        guard let header else { return [] }
        return ParameterizedValue.splitOutsideQuotes(header, separator: ",").compactMap(parse)
    }

    private static func parse(_ raw: String) -> EmailAddress? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        // グループ構文 (`名前: a@b, c@d;`) の名前と末尾の `;` を外す
        if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("<"), !text[..<colon].contains("@") {
            text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        if text.hasSuffix(";") { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            let address = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            let name = ParameterizedValue.unquote(text[..<open].trimmingCharacters(in: .whitespaces))
            guard address.contains("@") else { return nil }
            return EmailAddress(name: EncodedWord.decode(name), address: address)
        }
        let address = stripComments(text)
        guard address.contains("@") else { return nil }
        return EmailAddress(name: "", address: address)
    }

    private static func stripComments(_ text: String) -> String {
        var output = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 } else if character == ")" { depth = max(0, depth - 1) } else if depth == 0 {
                output.append(character)
            }
        }
        return output.trimmingCharacters(in: .whitespaces)
    }

    /// `<id@host>` の並びから中身だけを取り出す。
    static func messageIDs(_ header: String?) -> [String] {
        guard let header else { return [] }
        var ids: [String] = []
        var rest = Substring(header)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            ids.append(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        if ids.isEmpty {
            ids = header.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return ids
    }
}

enum MailDateParser {
    private static let formats = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz",
    ]

    static func parse(_ header: String?) -> Date? {
        guard var text = header else { return nil }
        if let comment = text.firstIndex(of: "(") { text = String(text[..<comment]) }
        text = text.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
