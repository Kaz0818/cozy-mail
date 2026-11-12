import Foundation

/// 文字コード名 (メールの `charset=`) から文字列への変換。
enum Charset {
    static func encoding(named name: String) -> String.Encoding? {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "utf-8", "utf8": .utf8
        case "us-ascii", "ascii": .ascii
        case "iso-8859-1", "iso8859-1", "latin1": .isoLatin1
        case "iso-8859-2", "iso8859-2", "latin2": .isoLatin2
        case "windows-1252", "cp1252": .windowsCP1252
        case "iso-2022-jp", "csiso2022jp": .iso2022JP
        case "shift_jis", "shift-jis", "sjis", "x-sjis", "windows-31j", "cp932", "ms932": .shiftJIS
        case "euc-jp", "x-euc-jp": .japaneseEUC
        case "utf-16": .utf16
        default: nil
        }
    }

    /// 指定の文字コードでだけ読む。読めなければ nil。
    static func strictDecode(_ bytes: some Sequence<UInt8>, charset: String) -> String? {
        guard let encoding = encoding(named: charset) else { return nil }
        return String(data: Data(bytes), encoding: encoding)
    }

    /// 指定の文字コードで読む。読めなければ UTF-8、それもだめなら Latin-1 で読む (必ず何かしらの文字列を返す)。
    static func decode(_ bytes: some Sequence<UInt8>, charset: String?) -> String {
        let data = Data(bytes)
        if let charset, let encoding = encoding(named: charset), let string = String(data: data, encoding: encoding) {
            return string
        }
        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}

/// `Content-Transfer-Encoding` の解除。
enum TransferEncoding {
    static func decode(_ bytes: [UInt8], encoding: String?) -> [UInt8] {
        switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64": base64(bytes)
        case "quoted-printable": quotedPrintable(bytes)
        default: bytes
        }
    }

    static func base64(_ bytes: [UInt8]) -> [UInt8] {
        var text = String(decoding: bytes.filter { !isWhitespace($0) }, as: UTF8.self)
        let remainder = text.count % 4
        if remainder != 0 { text += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: text, options: .ignoreUnknownCharacters).map { [UInt8]($0) } ?? []
    }

    /// quoted-printable を解除する。`underscoreIsSpace` はヘッダーの Q エンコーディング用。
    static func quotedPrintable(_ bytes: [UInt8], underscoreIsSpace: Bool = false) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "=") {
                let next = index + 1 < bytes.count ? bytes[index + 1] : nil
                if next == UInt8(ascii: "\n") {
                    index += 2
                    continue
                }
                if next == UInt8(ascii: "\r"), index + 2 < bytes.count, bytes[index + 2] == UInt8(ascii: "\n") {
                    index += 3
                    continue
                }
                if index + 2 < bytes.count, let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
                output.append(byte)
            } else if underscoreIsSpace, byte == UInt8(ascii: "_") {
                output.append(UInt8(ascii: " "))
            } else {
                output.append(byte)
            }
            index += 1
        }
        return output
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n")
    }
}
