import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// 本文の添付ファイルを Finder へドラッグするための形 (T31、US-5)。
///
/// サンドボックスのアプリは、Finder に勝手にファイルを置けない。そこで SwiftUI の `Transferable`
/// (`FileRepresentation`) を使い、Finder に「落とされた」ときに初めて中身を取って一時ファイルに書き、
/// そのファイルを渡す (Finder が落とした場所へ写す)。ドラッグを始めただけでは通信しない。
struct DraggableAttachment: Transferable {
    let filename: String
    /// 添付の中身を取る (まだ取っていなければサーバーから)。失敗したら投げる。
    let load: @Sendable () async throws -> Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            SentTransferredFile(try await item.writeTemporaryFile())
        }
    }

    /// 一時フォルダの中の、ドラッグのたびに別のフォルダに、元のファイル名で書き出す。
    /// 名前は `SafeHTML.safeFileName` で整える (「/」を含む名前で外に出られないように)。
    func writeTemporaryFile() async throws -> URL {
        let data = try await load()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(SafeHTML.safeFileName(filename))
        try data.write(to: url)
        return url
    }
}
