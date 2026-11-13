import Foundation

/// 送るメール。宛先・件名・本文は、組み立てるときに RFC 5322 / MIME の形にする。
public struct OutgoingMessage: Sendable, Equatable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    /// ヘッダーには書かず、SMTP の宛先にだけ使う。
    public var bcc: [EmailAddress]
    public var subject: String
    /// 改行は `\n` でも `\r\n` でもよい。
    public var textBody: String
    public var attachments: [OutgoingAttachment]
    /// 返信のとき、元のメールの Message-ID (`<>` なし)。
    public var inReplyTo: String?
    /// 返信のとき、元のメールの References に元のメールの Message-ID を足したもの (`<>` なし)。
    public var references: [String]
    public var date: Date
    /// このメールの Message-ID (`<>` なし)。`MIMEBuilder.makeMessageID(for:)` で作る。
    public var messageID: String

    public init(
        from: EmailAddress,
        to: [EmailAddress],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        subject: String,
        textBody: String,
        attachments: [OutgoingAttachment] = [],
        inReplyTo: String? = nil,
        references: [String] = [],
        date: Date = Date(),
        messageID: String
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.textBody = textBody
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        self.date = date
        self.messageID = messageID
    }

    /// SMTP で送る相手 (To・Cc・Bcc)。同じアドレスは 1 回だけ (大文字・小文字は区別しない)。
    public var envelopeRecipients: [String] {
        var seen: Set<String> = []
        return (to + cc + bcc).map(\.address).filter { seen.insert($0.lowercased()).inserted }
    }
}

public struct OutgoingAttachment: Sendable, Equatable {
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public enum MIMEBuildError: Error, Equatable, CustomStringConvertible {
    /// メールアドレスの形が正しくない (空、空白や改行を含む、`@` がないなど)。
    case invalidAddress(String)
    /// 宛先が 1 つもない。
    case noRecipients

    public var description: String {
        switch self {
        case let .invalidAddress(address): "メールアドレスの形が正しくありません: \(address)"
        case .noRecipients: "宛先がありません"
        }
    }
}

/// 送るメールを、SMTP でそのまま送れるバイト列 (改行は CRLF、7 ビットだけ) にする。
///
/// - 件名・名前・添付ファイル名の日本語は UTF-8 にして、RFC 2047 (件名・名前) と RFC 2231 (ファイル名) で書く。
/// - 本文は UTF-8 の Base64。どのサーバーを通っても崩れない。
/// - 件名や名前に改行が入っていても、ヘッダーを増やせないよう空白に置き換える (ヘッダーの差し込み対策)。
public enum MIMEBuilder {
    public static func build(_ message: OutgoingMessage, boundary: String = makeBoundary()) throws(MIMEBuildError) -> Data {
        guard !message.envelopeRecipients.isEmpty else { throw .noRecipients }
        for address in [message.from] + message.to + message.cc + message.bcc {
            try validate(address.address)
        }

        var headers: [String] = []
        headers.append(field("Date", formatDate(message.date)))
        headers.append(field("From", formatAddresses([message.from])))
        if !message.to.isEmpty { headers.append(field("To", formatAddresses(message.to))) }
        if !message.cc.isEmpty { headers.append(field("Cc", formatAddresses(message.cc))) }
        headers.append(field("Subject", encodeHeaderText(message.subject)))
        headers.append(field("Message-ID", "<\(clean(message.messageID))>"))
        if let inReplyTo = message.inReplyTo {
            headers.append(field("In-Reply-To", "<\(clean(inReplyTo))>"))
        }
        if !message.references.isEmpty {
            headers.append(field("References", message.references.map { "<\(clean($0))>" }.joined(separator: "\r\n ")))
        }
        headers.append("MIME-Version: 1.0")

        let text = textPart(message.textBody)
        var output: String
        if message.attachments.isEmpty {
            output = (headers + text.headers).joined(separator: "\r\n") + "\r\n\r\n" + text.body
        } else {
            headers.append("Content-Type: multipart/mixed;\r\n boundary=\"\(boundary)\"")
            output = headers.joined(separator: "\r\n") + "\r\n\r\n"
            output += "This is a multi-part message in MIME format.\r\n"
            output += "--\(boundary)\r\n" + text.headers.joined(separator: "\r\n") + "\r\n\r\n" + text.body
            for attachment in message.attachments {
                let part = attachmentPart(attachment)
                output += "--\(boundary)\r\n" + part.headers.joined(separator: "\r\n") + "\r\n\r\n" + part.body
            }
            output += "--\(boundary)--\r\n"
        }
        return Data(output.utf8)
    }

    /// `<ランダム>@<差出人のドメイン>` の形の Message-ID (`<>` なし)。
    public static func makeMessageID(for from: EmailAddress) -> String {
        let domain = from.address.split(separator: "@").last.map(String.init) ?? "cozymail.local"
        return "\(UUID().uuidString)@\(domain)"
    }

    public static func makeBoundary() -> String {
        "=_CozyMail_\(UUID().uuidString)"
    }

    // MARK: - 部品

    private static func textPart(_ text: String) -> (headers: [String], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        return (
            ["Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64"],
            base64Lines(Data(normalized.utf8))
        )
    }

    private static func attachmentPart(_ attachment: OutgoingAttachment) -> (headers: [String], body: String) {
        let type = attachment.mimeType.contains("/") && attachment.mimeType.allSatisfy(isTokenOrSlash)
            ? attachment.mimeType.lowercased()
            : "application/octet-stream"
        let name = fileNameParameter(attachment.filename)
        return (
            [
                "Content-Type: \(type);\r\n \(name.contentType)",
                "Content-Disposition: attachment;\r\n \(name.disposition)",
                "Content-Transfer-Encoding: base64",
            ],
            base64Lines(attachment.data)
        )
    }

    /// 76 文字ごとに改行した Base64 (最後も改行で終える)。
    private static func base64Lines(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        // 改行の入れ方は OS ごとの差をなくすため、自分で 76 文字ずつに切る
        let encoded = Array(data.base64EncodedString().utf8)
        return stride(from: 0, to: encoded.count, by: 76).map { start in
            String(decoding: encoded[start..<min(start + 76, encoded.count)], as: UTF8.self) + "\r\n"
        }.joined()
    }

    /// ファイル名: ASCII だけなら `filename="..."`、それ以外は RFC 2231 の `filename*0*=UTF-8''...`
    /// (長い名前は `filename*1*=` と続けて、1 行を短く保つ)。
    /// 古いメールソフトのため、`Content-Type` の `name` には RFC 2047 の形も入れる。
    private static func fileNameParameter(_ filename: String) -> (contentType: String, disposition: String) {
        let name = clean(filename).isEmpty ? "attachment" : clean(filename)
        let isPlain = name.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 && $0 != "\"" && $0 != "\\" }
        if isPlain {
            return ("name=\"\(name)\"", "filename=\"\(name)\"")
        }
        let encoded = name.utf8.map { byte -> String in
            let isSafe = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || [UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_")].contains(byte)
            return isSafe ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
        return (
            "name=\"\(encodedWords(name).joined(separator: "\r\n "))\"",
            continuedParameter("filename", charsetPrefix: "UTF-8''", encoded: encoded)
        )
    }

    /// RFC 2231 の分割: `name*0*=UTF-8''%E4...;` `name*1*=%E5...` を 1 行ずつ。`%XX` の途中では切らない。
    private static func continuedParameter(_ name: String, charsetPrefix: String, encoded: String) -> String {
        // 「 filename*12*=」と最後の「;」を足しても 78 文字に収まる長さ。最初の行は「UTF-8''」の分だけ短く
        let maxLength = 78 - (name.count + 6) - 1
        var segments: [String] = []
        var current = ""
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let length = encoded[index] == "%" ? 3 : 1
            let end = encoded.index(index, offsetBy: length, limitedBy: encoded.endIndex) ?? encoded.endIndex
            let piece = encoded[index..<end]
            let limit = segments.isEmpty ? maxLength - charsetPrefix.count : maxLength
            if !current.isEmpty, current.count + piece.count > limit {
                segments.append(current)
                current = ""
            }
            current += piece
            index = end
        }
        segments.append(current)
        return segments.enumerated().map { number, segment in
            "\(name)*\(number)*=\(number == 0 ? charsetPrefix : "")\(segment)"
        }.joined(separator: ";\r\n ")
    }

    // MARK: - ヘッダー

    private static func field(_ name: String, _ value: String) -> String {
        "\(name): \(value)"
    }

    /// 名前つきのアドレスの並び。長くならないよう、2 つ目からは折り返す。
    private static func formatAddresses(_ addresses: [EmailAddress]) -> String {
        addresses.map(formatAddress).joined(separator: ",\r\n ")
    }

    private static func formatAddress(_ address: EmailAddress) -> String {
        let name = clean(address.name)
        guard !name.isEmpty else { return "<\(address.address)>" }
        let isPlainASCII = name.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }
        if isPlainASCII {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(address.address)>"
        }
        return encodedWords(name).joined(separator: "\r\n ") + " <\(address.address)>"
    }

    /// 件名など: ASCII だけで短ければそのまま、それ以外は RFC 2047 の単語に分けて折り返す。
    private static func encodeHeaderText(_ text: String) -> String {
        let value = clean(text)
        let isPlainASCII = value.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }
        if isPlainASCII, value.utf8.count <= 900, !value.contains("=?") {
            return value
        }
        return encodedWords(value).joined(separator: "\r\n ")
    }

    /// `=?UTF-8?B?...?=` の単語に分ける。1 語は 75 文字まで (RFC 2047)。文字の途中では切らない。
    static func encodedWords(_ text: String) -> [String] {
        // Base64 で 52 文字 + 前後の 12 文字 = 64 文字。「Subject: 」などを前に付けても 78 文字に収まる
        let maxBytesPerWord = 39
        var words: [String] = []
        var chunk: [UInt8] = []
        for character in text {
            let bytes = Array(String(character).utf8)
            if !chunk.isEmpty, chunk.count + bytes.count > maxBytesPerWord {
                words.append(encodedWord(chunk))
                chunk = []
            }
            chunk += bytes
        }
        if !chunk.isEmpty || words.isEmpty { words.append(encodedWord(chunk)) }
        return words
    }

    private static func encodedWord(_ bytes: [UInt8]) -> String {
        "=?UTF-8?B?\(Data(bytes).base64EncodedString())?="
    }

    /// RFC 5322 の日付 (例: `Fri, 13 Nov 2026 20:00:00 +0900`)。
    static func formatDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// 改行などの制御文字を空白にする (ヘッダーを勝手に増やされないように)。
    private static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            scalar.properties.generalCategory == .control ? " " : scalar
        })).trimmingCharacters(in: .whitespaces)
    }

    /// 送れる形のアドレスか。`local@domain` で、空白・制御文字・`<>`・`,` などを含まない。
    private static func validate(_ address: String) throws(MIMEBuildError) {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        let forbidden = CharacterSet(charactersIn: " \t\r\n<>(),;:\\\"[]").union(.controlCharacters)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              address.unicodeScalars.allSatisfy({ !forbidden.contains($0) }),
              address.utf8.count <= 254
        else { throw .invalidAddress(address) }
    }

    private static func isTokenOrSlash(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "/+-.".contains(character))
    }
}
