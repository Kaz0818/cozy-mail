import Foundation

/// RFC 2047 のエンコードされた単語 (`=?charset?B?...?=`) の解除。
enum EncodedWord {
    private struct Word {
        let charset: String
        let bytes: [UInt8]
    }

    /// 同じ文字コードで並んだ単語のまとまり。
    private struct WordRun {
        var words: [Word]

        var charset: String { words[0].charset }

        /// まずバイト列をつないで読み、読めなければ 1 語ずつ読む。
        func decoded() -> String {
            let joined = words.flatMap(\.bytes)
            if let text = Charset.strictDecode(joined, charset: charset) { return text }
            return words.map { Charset.decode($0.bytes, charset: $0.charset) }.joined()
        }
    }

    private enum Piece {
        case text(String)
        case word(Word)

        var isWord: Bool {
            if case .word = self { return true }
            return false
        }
    }

    /// 文字列中のエンコードされた単語を解除する。
    /// 並んだ単語どうしの間の空白は捨て、同じ文字コードの単語はバイト列をつないでから読む
    /// (ISO-2022-JP で 1 文字が 2 つの単語にまたがることがあるため)。
    static func decode(_ input: String) -> String {
        let pieces = split(input)
        var output = ""
        var pending: WordRun?
        var index = 0
        while index < pieces.count {
            switch pieces[index] {
            case let .word(word):
                if var current = pending, current.charset.lowercased() == word.charset.lowercased() {
                    current.words.append(word)
                    pending = current
                } else {
                    if let current = pending { output += current.decoded() }
                    pending = WordRun(words: [word])
                }
            case let .text(text):
                let isGapBetweenWords = text.allSatisfy(\.isWhitespace)
                    && index + 1 < pieces.count
                    && pieces[index + 1].isWord
                    && pending != nil
                if !isGapBetweenWords {
                    if let current = pending {
                        output += current.decoded()
                        pending = nil
                    }
                    output += text
                }
            }
            index += 1
        }
        if let current = pending { output += current.decoded() }
        return output
    }

    private static func split(_ input: String) -> [Piece] {
        var pieces: [Piece] = []
        var rest = Substring(input)
        while let start = rest.range(of: "=?") {
            guard let word = parseWord(rest[start.lowerBound...]) else {
                pieces.append(.text(String(rest[..<start.upperBound])))
                rest = rest[start.upperBound...]
                continue
            }
            if start.lowerBound > rest.startIndex {
                pieces.append(.text(String(rest[..<start.lowerBound])))
            }
            pieces.append(.word(word.word))
            rest = rest[word.end...]
        }
        if !rest.isEmpty { pieces.append(.text(String(rest))) }
        return pieces
    }

    /// `=?charset?X?text?=` を読む。形が違えば nil。
    private static func parseWord(_ text: Substring) -> (word: Word, end: Substring.Index)? {
        let body = text.dropFirst(2)
        guard let charsetEnd = body.firstIndex(of: "?") else { return nil }
        var charset = String(body[..<charsetEnd])
        if let languageMark = charset.firstIndex(of: "*") { charset = String(charset[..<languageMark]) }
        let afterCharset = body[body.index(after: charsetEnd)...]
        guard let mode = afterCharset.first, afterCharset.dropFirst().first == "?" else { return nil }
        let encoded = afterCharset.dropFirst(2)
        guard let close = encoded.range(of: "?=") else { return nil }
        let payload = Array(encoded[..<close.lowerBound].utf8)
        guard !payload.contains(UInt8(ascii: " ")) else { return nil }
        let bytes: [UInt8]
        switch mode {
        case "B", "b": bytes = TransferEncoding.base64(payload)
        case "Q", "q": bytes = TransferEncoding.quotedPrintable(payload, underscoreIsSpace: true)
        default: return nil
        }
        return (Word(charset: charset, bytes: bytes), close.upperBound)
    }
}
