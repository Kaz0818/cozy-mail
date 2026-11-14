import Foundation

/// 作成ウィンドウの種類。
public enum ComposeKind: Sendable, Hashable {
    case new
    case reply
    case replyAll
    case forward
}

/// 送る前のメール (作成ウィンドウの中身)。
public struct Draft: Sendable, Equatable {
    /// 差出人のアカウント。返信・転送では、受け取ったアカウントになる。
    public var accountID: AccountID?
    public var to: [Contact]
    public var cc: [Contact]
    public var bcc: [Contact]
    public var subject: String
    public var body: String
    public var attachments: [DraftAttachment]
    /// 返信のとき、元のメールの Message-ID (`<>` なし)。
    public var inReplyTo: String?
    /// 返信のとき、スレッドをつなぐための Message-ID の並び (`<>` なし)。
    public var references: [String]
    /// 返信・転送のとき、本文の下に付く引用 (または転送するメール) の部分。差出人を変えて署名を入れ直すときの目印 (T25)。
    public var quote: String

    public init(
        accountID: AccountID? = nil,
        to: [Contact] = [],
        cc: [Contact] = [],
        bcc: [Contact] = [],
        subject: String = "",
        body: String = "",
        attachments: [DraftAttachment] = [],
        inReplyTo: String? = nil,
        references: [String] = [],
        quote: String = ""
    ) {
        self.quote = quote
        self.accountID = accountID
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
    }

    /// 添付ファイルの合計の大きさ (バイト)。
    public var attachmentBytes: Int {
        attachments.reduce(0) { $0 + $1.data.count }
    }
}

public struct DraftAttachment: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

/// 返信・転送するときに使う、元のメールの情報。
public struct ReplySource: Sendable, Equatable {
    public var accountID: AccountID
    public var from: [Contact]
    public var replyTo: [Contact]
    public var to: [Contact]
    public var cc: [Contact]
    public var subject: String
    public var date: Date
    /// 元のメールの Message-ID (`<>` なし)。ないメールもある。
    public var messageID: String?
    public var references: [String]
    public var text: String
    /// 転送のときに付け直す添付ファイル。
    public var attachments: [DraftAttachment]

    public init(
        accountID: AccountID,
        from: [Contact],
        replyTo: [Contact] = [],
        to: [Contact] = [],
        cc: [Contact] = [],
        subject: String,
        date: Date,
        messageID: String? = nil,
        references: [String] = [],
        text: String,
        attachments: [DraftAttachment] = []
    ) {
        self.accountID = accountID
        self.from = from
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.subject = subject
        self.date = date
        self.messageID = messageID
        self.references = references
        self.text = text
        self.attachments = attachments
    }
}

/// 送る前に見つかった問題。
public enum DraftProblem: Error, Equatable, Sendable {
    case noAccount
    case noRecipients
    case invalidAddress(String)
    /// 添付ファイルが大きすぎる (多くのメールサービスの上限は 25 MB)。
    case attachmentsTooLarge(bytes: Int)
}

/// 作成ウィンドウの中身を作る (返信・全員に返信・転送の宛先、件名、引用)。
public enum Composer {
    /// 添付ファイルの合計の上限。Gmail・Yahoo! の上限 (25 MB) に、Base64 で約 4/3 倍になる分の余裕をみる。
    public static let maxAttachmentBytes = 18 * 1024 * 1024

    /// - Parameters:
    ///   - source: 元のメール (新規作成なら nil)。
    ///   - myAddresses: 自分のアドレス (すべてのアカウント)。全員に返信の宛先から除く。
    ///   - defaultAccount: 新規作成のときの差出人。
    ///   - signature: 差出人のアカウントの署名 (T25)。新規作成では本文の最後、返信・転送では引用の上に「-- 」と一緒に入れる。
    public static func draft(
        _ kind: ComposeKind,
        replyingTo source: ReplySource?,
        myAddresses: [String],
        defaultAccount: AccountID?,
        signature: String = "",
        timeZone: TimeZone = .current
    ) -> Draft {
        let block = signatureBlock(signature)
        guard let source, kind != .new else {
            return Draft(accountID: defaultAccount, body: block.isEmpty ? "" : "\n\n" + block)
        }
        let mine = Set(myAddresses.map { $0.lowercased() })
        let isMine = { (contact: Contact) in mine.contains(contact.address.lowercased()) }
        // 自分が送ったメールに返信するときは、元の宛先に送る (Gmail と同じ)
        let sentByMe = !source.from.isEmpty && source.from.allSatisfy(isMine)

        var draft = Draft(accountID: source.accountID)
        switch kind {
        case .new:
            break
        case .reply:
            draft.to = sentByMe ? source.to : (source.replyTo.isEmpty ? source.from : source.replyTo)
        case .replyAll:
            if sentByMe {
                draft.to = source.to
                draft.cc = source.cc
            } else {
                draft.to = source.replyTo.isEmpty ? source.from : source.replyTo
                draft.cc = source.to + source.cc
            }
            draft.to = unique(draft.to, excluding: [])
            draft.cc = unique(draft.cc.filter { !isMine($0) }, excluding: draft.to)
        case .forward:
            break
        }

        switch kind {
        case .reply, .replyAll:
            draft.subject = replySubject(source.subject)
            draft.quote = quoteHeader(source, timeZone: timeZone) + "\n" + quoted(source.text)
            draft.body = "\n\n" + (block.isEmpty ? "" : block + "\n\n") + draft.quote
            if let messageID = source.messageID {
                draft.inReplyTo = messageID
                draft.references = source.references.filter { $0 != messageID } + [messageID]
            }
        case .forward:
            draft.subject = forwardSubject(source.subject)
            draft.quote = forwardHeader(source, timeZone: timeZone) + "\n\n" + source.text
            draft.body = "\n\n" + (block.isEmpty ? "" : block + "\n\n") + draft.quote
            draft.attachments = source.attachments
        case .new:
            break
        }
        return draft
    }

    /// 送れる状態か。問題がなければ nil。
    public static func problem(in draft: Draft) -> DraftProblem? {
        guard draft.accountID != nil else { return .noAccount }
        let all = draft.to + draft.cc + draft.bcc
        guard !all.isEmpty else { return .noRecipients }
        if let bad = all.first(where: { !isValidAddress($0.address) }) { return .invalidAddress(bad.address) }
        if draft.attachmentBytes > maxAttachmentBytes { return .attachmentsTooLarge(bytes: draft.attachmentBytes) }
        return nil
    }

    // MARK: - 件名

    /// 「Re: 」を付ける。すでに付いていれば (大文字・小文字、全角のコロン、「返信:」も) そのまま。
    public static func replySubject(_ subject: String) -> String {
        hasPrefix(subject, ["re:", "re：", "返信:", "返信："]) ? subject : "Re: " + subject
    }

    /// 「Fwd: 」を付ける。すでに付いていれば (「Fw:」「転送:」も) そのまま。
    public static func forwardSubject(_ subject: String) -> String {
        hasPrefix(subject, ["fwd:", "fwd：", "fw:", "fw：", "転送:", "転送："]) ? subject : "Fwd: " + subject
    }

    private static func hasPrefix(_ subject: String, _ prefixes: [String]) -> Bool {
        let lowered = subject.trimmingCharacters(in: .whitespaces).lowercased()
        return prefixes.contains { lowered.hasPrefix($0) }
    }

    // MARK: - 署名 (T25)

    /// 署名の区切り (メールの決まりごと「-- 」+ 改行)。メールソフトはこの下を署名と見なす。
    public static let signatureSeparator = "-- \n"

    /// 本文に入れる署名の塊。空の署名なら空。
    static func signatureBlock(_ signature: String) -> String {
        let trimmed = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : signatureSeparator + trimmed
    }

    /// 差出人を変えたときに、署名を入れ替える。書いた本文はそのまま。
    /// - 前の署名が本文にあれば、新しい署名に置き換える (新しい署名が空なら消す)。手で消していたら、何もしない。
    /// - 前のアカウントに署名がなければ、引用 (`quote`) の上に入れる。引用がなければ本文の最後に足す。
    public static func replacingSignature(in body: String, old: String, new: String, quote: String) -> String {
        let oldBlock = signatureBlock(old)
        let newBlock = signatureBlock(new)
        var body = body
        if !oldBlock.isEmpty {
            guard let range = body.range(of: "\n\n" + oldBlock) else { return body }
            body.replaceSubrange(range, with: newBlock.isEmpty ? "" : "\n\n" + newBlock)
            return body
        }
        guard !newBlock.isEmpty else { return body }
        if !quote.isEmpty, let range = body.range(of: "\n\n" + quote, options: .backwards) {
            body.insert(contentsOf: "\n\n" + newBlock, at: range.lowerBound)
        } else {
            body += "\n\n" + newBlock
        }
        return body
    }

    // MARK: - 引用

    /// 例: `2026年11月13日(金) 14:05 田中 健一 <k.tanaka@example.com>:`
    static func quoteHeader(_ source: ReplySource, timeZone: TimeZone) -> String {
        "\(formatDate(source.date, timeZone: timeZone)) \(format(source.from)):"
    }

    static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
    }

    static func forwardHeader(_ source: ReplySource, timeZone: TimeZone) -> String {
        var lines = [
            "---------- 転送されたメッセージ ----------",
            "差出人: \(format(source.from))",
            "日付: \(formatDate(source.date, timeZone: timeZone))",
            "件名: \(source.subject)",
            "宛先: \(format(source.to))",
        ]
        if !source.cc.isEmpty { lines.append("Cc: \(format(source.cc))") }
        return lines.joined(separator: "\n")
    }

    private static func formatDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy年M月d日(E) H:mm"
        return formatter.string(from: date)
    }

    // MARK: - アドレス

    /// 「山田 太郎 <taro@example.com>」の形の並び。
    /// 名前に `,` `;` などが入っていれば `"..."` で囲む (宛先の欄に入れて、`parseRecipients` で読み戻せるように)。
    public static func format(_ contacts: [Contact]) -> String {
        contacts.map { contact in
            guard !contact.name.isEmpty else { return contact.address }
            let needsQuotes = contact.name.contains { ",;、<>\"".contains($0) }
            let name = needsQuotes ? "\"\(contact.name.replacingOccurrences(of: "\"", with: ""))\"" : contact.name
            return "\(name) <\(contact.address)>"
        }.joined(separator: ", ")
    }

    /// 宛先の欄に打った文字を、宛先の並びにする。`,` `;` 改行で区切り、`名前 <アドレス>` と `アドレス` を読む。
    /// 読めなかったものは `invalid` に入れる (画面で知らせる)。
    public static func parseRecipients(_ text: String) -> (contacts: [Contact], invalid: [String]) {
        var contacts: [Contact] = []
        var invalid: [String] = []
        for raw in splitRecipients(text) {
            let piece = raw.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            let contact: Contact
            if let open = piece.lastIndex(of: "<"), let close = piece.lastIndex(of: ">"), open < close {
                let address = piece[piece.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                let name = piece[..<open].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                contact = Contact(name: name, address: address)
            } else {
                contact = Contact(name: "", address: piece)
            }
            if isValidAddress(contact.address) {
                contacts.append(contact)
            } else {
                invalid.append(piece)
            }
        }
        return (unique(contacts, excluding: []), invalid)
    }

    /// `,` `;` `、` 改行で区切る。ただし `"..."` (名前) と `<...>` (アドレス) の中の区切りは無視する。
    private static func splitRecipients(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for character in text {
            switch character {
            case "\"": inQuotes.toggle()
            case "<" where !inQuotes: inAngle = true
            case ">" where !inQuotes: inAngle = false
            case ",", ";", "、":
                // (`where` は最後の 1 つにしか効かないので、条件は中で調べる)
                if !inQuotes && !inAngle {
                    pieces.append(current)
                    current = ""
                    continue
                }
            default:
                if character.isNewline {
                    pieces.append(current)
                    current = ""
                    inQuotes = false
                    inAngle = false
                    continue
                }
            }
            current.append(character)
        }
        pieces.append(current)
        return pieces
    }

    /// `local@domain.tld` の形か (空白・改行・`<>` などを含まない)。
    public static func isValidAddress(_ address: String) -> Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."), address.utf8.count <= 254
        else { return false }
        let forbidden = CharacterSet(charactersIn: " \t<>(),;:\\\"[]").union(.controlCharacters).union(.newlines)
        return address.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }

    /// 同じアドレスは最初の 1 つだけ残し、`excluding` にあるアドレスも除く (大文字・小文字は区別しない)。
    private static func unique(_ contacts: [Contact], excluding: [Contact]) -> [Contact] {
        var seen = Set(excluding.map { $0.address.lowercased() })
        return contacts.filter { seen.insert($0.address.lowercased()).inserted }
    }
}
