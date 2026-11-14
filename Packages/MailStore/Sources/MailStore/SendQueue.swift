import Foundation

/// 送信の取り消し (T24、US-15)。送るメールを決めた秒数だけ預かり、その間なら取り消せる。
///
/// - 秒数が過ぎたら送る。送り始めたあとは取り消せない。
/// - アプリを終えるときは `flush()` で、預かっているものをすぐに送る (送り途中のものも終わるまで待つ)。
/// - 結果 (送れた・送れなかった) は `onEvent` で知らせる。送れなかったときは、書いたものを失わないよう下書きを返す。
public actor SendQueue {
    public enum Event: Sendable, Equatable {
        /// 送り始めた。もう取り消せない。
        case started(UUID)
        case sent(UUID, SendOutcome)
        /// 送れなかった (預かっていた下書き、理由)。
        case failed(UUID, Draft, String)
    }

    private struct Entry {
        var draft: Draft
        var timer: Task<Void, Never>?
        /// 送り始めたら true。もう取り消せない。
        var isSending = false
    }

    private let send: @Sendable (Draft) async throws -> SendOutcome
    private let onEvent: @Sendable (Event) async -> Void
    private let describe: @Sendable (any Error) -> String
    private var entries: [UUID: Entry] = [:]
    /// 預けた順 (`flush()` はこの順に送る)。
    private var order: [UUID] = []

    public init(
        send: @escaping @Sendable (Draft) async throws -> SendOutcome,
        onEvent: @escaping @Sendable (Event) async -> Void,
        describe: @escaping @Sendable (any Error) -> String = { String(describing: $0) }
    ) {
        self.send = send
        self.onEvent = onEvent
        self.describe = describe
    }

    /// 送るのを待っている (まだ取り消せる) もの。
    public var pendingIDs: [UUID] {
        order.filter { entries[$0]?.isSending == false }
    }

    /// `delay` のあとに送る。戻り値は取り消すときに使う。
    @discardableResult
    public func enqueue(_ draft: Draft, delay: Duration) -> UUID {
        let id = UUID()
        entries[id] = Entry(draft: draft)
        order.append(id)
        entries[id]?.timer = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return  // 取り消された、または flush() が先に送った
            }
            await self?.deliver(id)
        }
        return id
    }

    /// 送る前なら取り消して、下書きを返す。もう送り始めた・送り終えたときは nil。
    public func cancel(_ id: UUID) -> Draft? {
        guard let entry = entries[id], !entry.isSending else { return nil }
        entry.timer?.cancel()
        remove(id)
        return entry.draft
    }

    /// 預かっているものを、待たずにすぐ送る。送り途中のものも終わるまで待つ。
    /// 送っている間に別のものの秒数が過ぎて送り始めることもあるので、残りがなくなるまで繰り返す。
    public func flush() async {
        while let id = pendingIDs.first {
            entries[id]?.timer?.cancel()
            await deliver(id)
        }
        while let timer = order.lazy.compactMap({ self.entries[$0] }).first(where: \.isSending)?.timer {
            await timer.value
        }
    }

    private func deliver(_ id: UUID) async {
        guard let entry = entries[id], !entry.isSending else { return }
        entries[id]?.isSending = true
        await onEvent(.started(id))
        let event: Event
        do {
            event = .sent(id, try await send(entry.draft))
        } catch {
            event = .failed(id, entry.draft, describe(error))
        }
        remove(id)
        await onEvent(event)
    }

    private func remove(_ id: UUID) {
        entries[id] = nil
        order.removeAll { $0 == id }
    }
}
