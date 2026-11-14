import Foundation
import Testing
@testable import CozyMail

/// 添付ファイルを Finder へドラッグするときの、一時ファイルの書き出し (T31、US-5)。
@Suite struct AttachmentDragTests {
    private struct LoadFailure: Error {}

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func writesTheAttachmentUnderItsOwnName() async throws {
        let bytes = Data([0x25, 0x50, 0x44, 0x46, 0x00, 0xFF])
        let drag = DraggableAttachment(filename: "見積書.pdf") { bytes }
        let url = try await drag.writeTemporaryFile()
        defer { remove(url) }
        #expect(url.lastPathComponent == "見積書.pdf")
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func unsafeNamesCannotEscapeTheTemporaryFolder() async throws {
        let drag = DraggableAttachment(filename: "../../evil.sh") { Data("x".utf8) }
        let url = try await drag.writeTemporaryFile()
        defer { remove(url) }
        #expect(url.lastPathComponent == "_.._evil.sh")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
            == FileManager.default.temporaryDirectory.standardizedFileURL)
    }

    @Test func emptyNamesGetAFallbackName() async throws {
        let drag = DraggableAttachment(filename: "  ") { Data() }
        let url = try await drag.writeTemporaryFile()
        defer { remove(url) }
        #expect(url.lastPathComponent == "attachment")
    }

    /// 取れなかったときは、空のファイルを作らずにエラーにする。
    @Test func aFailedLoadThrowsAndLeavesNoFile() async {
        let drag = DraggableAttachment(filename: "a.txt") { throw LoadFailure() }
        await #expect(throws: LoadFailure.self) { try await drag.writeTemporaryFile() }
    }

    @Test func eachDragUsesItsOwnFolder() async throws {
        let drag = DraggableAttachment(filename: "a.txt") { Data("1".utf8) }
        let first = try await drag.writeTemporaryFile()
        let second = try await drag.writeTemporaryFile()
        defer { remove(first); remove(second) }
        #expect(first != second)
    }
}
