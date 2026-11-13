import Foundation
import MailCore

/// 保存したメール全体の生データから、画面に出す本文と添付ファイルを組み立てる。
enum MessageBodyBuilder {
    static func body(id: MessageID, raw: Data) throws -> MessageBody {
        let parsed = try MIMEParser.parse(raw)
        var html = parsed.htmlBody
        var embeddedIndexes: Set<Int> = []

        // 本文に埋め込まれた画像 (cid:) は、外から読み込まなくても出るよう data: URL に置き換える
        if var text = html {
            for (index, attachment) in parsed.attachments.enumerated() {
                guard let contentID = attachment.contentID else { continue }
                let reference = "cid:\(contentID)"
                guard text.contains(reference) else { continue }
                text = text.replacingOccurrences(
                    of: reference, with: "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
                )
                embeddedIndexes.insert(index)
            }
            html = text
        }

        // 本文で使われた埋め込み画像以外を、添付ファイルとして見せる
        let attachments = parsed.attachments.enumerated()
            .filter { !embeddedIndexes.contains($0.offset) }
            .map { index, attachment in
                Attachment(
                    filename: attachment.filename,
                    mimeType: attachment.mimeType,
                    byteCount: Int64(attachment.data.count),
                    index: index
                )
            }

        return MessageBody(
            messageID: id,
            to: parsed.to.map { Contact(name: $0.name, address: $0.address) },
            cc: parsed.cc.map { Contact(name: $0.name, address: $0.address) },
            text: parsed.textBody ?? parsed.htmlBody.map(HTMLText.plainText(from:)) ?? "",
            html: html,
            attachments: attachments
        )
    }

    static func attachmentData(raw: Data, index: Int) throws -> Data {
        let attachments = try MIMEParser.parse(raw).attachments
        guard attachments.indices.contains(index) else { throw MailRepositoryError.attachmentNotFound }
        return attachments[index].data
    }

    /// 一覧の 2 行目に出す、本文の書き出し (1 行・140 文字まで)。
    static func preview(of body: MessageBody) -> String {
        let words = body.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return String(words.joined(separator: " ").prefix(140))
    }
}
