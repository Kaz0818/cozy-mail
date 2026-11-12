import Foundation

/// 読み取ったメール。
public struct ParsedMessage: Sendable, Equatable {
    public var headers: MIMEHeaders
    public var subject: String
    public var from: [EmailAddress]
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var date: Date?
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    /// 改行は `\n` にそろえてある。
    public var textBody: String?
    public var htmlBody: String?
    public var attachments: [ParsedAttachment]
}

public struct ParsedAttachment: Sendable, Equatable {
    public var filename: String
    public var mimeType: String
    public var data: Data
    public var contentID: String?
    /// 本文の中に埋め込まれる画像など。
    public var isInline: Bool
}

public enum MIMEParseError: Error, Equatable {
    case empty
}

/// メールの生データ (RFC 5322 / MIME) を読む。
public enum MIMEParser {
    public static func parse(_ data: Data) throws(MIMEParseError) -> ParsedMessage {
        guard !data.isEmpty else { throw .empty }
        let root = MIMEPart(Array(data)[...])
        let headers = root.headers
        var message = ParsedMessage(
            headers: headers,
            subject: EncodedWord.decode(headers["Subject"] ?? ""),
            from: AddressParser.parseList(headers["From"]),
            to: AddressParser.parseList(headers["To"]),
            cc: AddressParser.parseList(headers["Cc"]),
            replyTo: AddressParser.parseList(headers["Reply-To"]),
            date: MailDateParser.parse(headers["Date"]),
            messageID: AddressParser.messageIDs(headers["Message-ID"]).first,
            inReplyTo: AddressParser.messageIDs(headers["In-Reply-To"]).first,
            references: AddressParser.messageIDs(headers["References"]),
            textBody: nil,
            htmlBody: nil,
            attachments: []
        )
        collect(root, into: &message)
        return message
    }

    /// 本文とする部分と添付ファイルを振り分ける。最初に見つかったテキスト / HTML を本文にする。
    private static func collect(_ part: MIMEPart, into message: inout ParsedMessage) {
        if !part.children.isEmpty {
            for child in part.children { collect(child, into: &message) }
            return
        }
        let disposition = ParameterizedValue(part.headers["Content-Disposition"])
        let filename = disposition.parameters["filename"] ?? part.contentType.parameters["name"]
        let type = part.contentType.value.isEmpty ? "text/plain" : part.contentType.value
        let isAttachment = disposition.value == "attachment" || filename != nil

        if !isAttachment, type == "text/plain", message.textBody == nil {
            message.textBody = part.decodedText
        } else if !isAttachment, type == "text/html", message.htmlBody == nil {
            message.htmlBody = part.decodedText
        } else if !part.isMultipart {
            let contentID = AddressParser.messageIDs(part.headers["Content-ID"]).first
            message.attachments.append(ParsedAttachment(
                filename: filename ?? "attachment",
                mimeType: type,
                data: Data(part.decodedBytes),
                contentID: contentID,
                isInline: disposition.value != "attachment" && (disposition.value == "inline" || contentID != nil)
            ))
        }
    }
}

/// MIME の 1 つの部分 (全体もその 1 つ)。
struct MIMEPart {
    let headers: MIMEHeaders
    let contentType: ParameterizedValue
    let body: ArraySlice<UInt8>
    let children: [MIMEPart]

    var isMultipart: Bool {
        contentType.value.hasPrefix("multipart/")
    }

    init(_ bytes: ArraySlice<UInt8>) {
        let (headerBytes, bodyBytes) = Self.splitHeaderAndBody(bytes)
        headers = MIMEHeaders.parse(headerBytes)
        contentType = ParameterizedValue(headers["Content-Type"])
        body = bodyBytes
        if contentType.value.hasPrefix("multipart/"), let boundary = contentType.parameters["boundary"] {
            children = Self.splitMultipart(bodyBytes, boundary: boundary).map(MIMEPart.init)
        } else {
            children = []
        }
    }

    var decodedBytes: [UInt8] {
        TransferEncoding.decode(Array(body), encoding: headers["Content-Transfer-Encoding"])
    }

    var decodedText: String {
        Charset.decode(decodedBytes, charset: contentType.parameters["charset"])
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// 最初の空行でヘッダーと本文に分ける。
    private static func splitHeaderAndBody(_ bytes: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
        var lineStart = bytes.startIndex
        while lineStart < bytes.endIndex {
            let lineEnd = bytes[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.endIndex
            var contentEnd = lineEnd
            if contentEnd > lineStart, bytes[contentEnd - 1] == UInt8(ascii: "\r") { contentEnd -= 1 }
            if contentEnd == lineStart {
                let bodyStart = min(lineEnd + 1, bytes.endIndex)
                return (bytes[bytes.startIndex..<lineStart], bytes[bodyStart...])
            }
            lineStart = lineEnd + 1
        }
        return (bytes, bytes[bytes.endIndex...])
    }

    /// `--boundary` の行で区切る。区切り行の直前の改行は、区切りの一部として捨てる。
    private static func splitMultipart(_ bytes: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let delimiter = Array(("--" + boundary).utf8)
        var parts: [ArraySlice<UInt8>] = []
        var partStart: Int?
        var lineStart = bytes.startIndex
        while lineStart < bytes.endIndex {
            let lineEnd = bytes[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.endIndex
            var contentEnd = lineEnd
            while contentEnd > lineStart, [UInt8(ascii: "\r"), UInt8(ascii: " "), UInt8(ascii: "\t")]
                .contains(bytes[contentEnd - 1]) {
                contentEnd -= 1
            }
            let line = bytes[lineStart..<contentEnd]
            let isDelimiter = line.elementsEqual(delimiter)
            let isClose = line.elementsEqual(delimiter + Array("--".utf8))
            if isDelimiter || isClose {
                if let start = partStart {
                    var end = lineStart
                    if end > start, bytes[end - 1] == UInt8(ascii: "\n") { end -= 1 }
                    if end > start, bytes[end - 1] == UInt8(ascii: "\r") { end -= 1 }
                    parts.append(bytes[start..<end])
                }
                if isClose { return parts }
                partStart = min(lineEnd + 1, bytes.endIndex)
            }
            lineStart = lineEnd + 1
        }
        if let start = partStart, start < bytes.endIndex { parts.append(bytes[start...]) }
        return parts
    }
}
