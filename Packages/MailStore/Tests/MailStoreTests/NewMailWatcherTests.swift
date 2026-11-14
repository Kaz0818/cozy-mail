import Foundation
import MailCore
import Testing
@testable import MailStore

/// 受信トレイの見張り (T20a)。偽の接続で、IDLE の知らせ・時間切れ・切断・IDLE がないサーバーを試す。
@Suite struct NewMailWatcherTests {
    /// 台本どおりに IDLE の結果を返す偽の接続。台本が尽きたら、止められるまで待つ。
    actor ScriptedSession: MailServerSession {
        enum Step { case event(IMAPIdleEvent), fail }
        private var steps: [Step]
        private let idle: Bool
        private(set) var idleCalls: [(mailbox: String, timeout: Duration)] = []
        private(set) var closed = false

        init(idle: Bool = true, steps: [Step]) {
            self.idle = idle
            self.steps = steps
        }

        func supportsIdle() async throws -> Bool { idle }

        func idle(in mailbox: String, timeout: Duration) async throws -> IMAPIdleEvent {
            idleCalls.append((mailbox, timeout))
            guard !steps.isEmpty else {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                return .cancelled
            }
            switch steps.removeFirst() {
            case let .event(event): return event
            case .fail: throw IMAPError.connectionClosed
            }
        }

        func close() async { closed = true }

        // 見張りでは使わない命令
        func listMailboxes() async throws -> [IMAPMailbox] { [] }
        func examine(_ mailbox: String) async throws -> IMAPMailboxStatus { fatalError() }
        func searchUIDs(in mailbox: String, since date: Date, calendar: Calendar) async throws -> [UInt32] { [] }
        func fetchHeaders(in mailbox: String, uids: [UInt32], includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] { [] }
        func fetchHeaders(in mailbox: String, fromUID uid: UInt32, includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] { [] }
        func fetchFlags(in mailbox: String, uids: ClosedRange<UInt32>, includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] { [] }
        func unreadCount(of mailbox: String) async throws -> Int { 0 }
        func fetchMessage(in mailbox: String, uid: UInt32) async throws -> Data { Data() }
        func setFlags(_ flags: [String], add: Bool, in mailbox: String, uids: [UInt32]) async throws {}
        func setGmailLabels(_ labels: [String], add: Bool, in mailbox: String, uids: [UInt32]) async throws {}
        func move(uids: [UInt32], from mailbox: String, to target: String) async throws {}
        func append(_ message: Data, to mailbox: String, flags: [String]) async throws {}
    }

    /// 呼ばれた回数・待った時間を記録する。
    actor Recorder {
        private(set) var changes = 0
        private(set) var sleeps: [Duration] = []
        private(set) var opens = 0
        func change() { changes += 1 }
        func slept(_ duration: Duration) { sleeps.append(duration) }
        func opened() -> Int { opens += 1; return opens }
    }

    private static let timing = NewMailWatcher.Timing(
        idleRenewal: .seconds(25 * 60), pollInterval: .seconds(60), firstRetry: .seconds(1), maxRetry: .seconds(300)
    )

    /// `until` が満たされるまで見張りを動かし、止める。
    private func run(
        sessions: [ScriptedSession?],
        recorder: Recorder,
        until done: @escaping @Sendable (Recorder) async -> Bool
    ) async {
        let watcher = NewMailWatcher(
            timing: Self.timing,
            openSession: {
                let index = await recorder.opened() - 1
                guard index < sessions.count, let session = sessions[index] else { throw IMAPError.connectionFailed("offline") }
                return session
            },
            onChange: { await recorder.change() },
            sleep: { duration in
                await recorder.slept(duration)
                try await Task.sleep(for: .milliseconds(1))
            }
        )
        let task = Task { await watcher.run() }
        for _ in 0..<2000 where !(await done(recorder)) {
            try? await Task.sleep(for: .milliseconds(2))
        }
        task.cancel()
        await task.value
    }

    @Test func aChangeTriggersASync() async {
        let session = ScriptedSession(steps: [.event(.changed), .event(.changed)])
        let recorder = Recorder()
        await run(sessions: [session], recorder: recorder) { await $0.changes >= 2 }
        #expect(await recorder.changes == 2)
        let calls = await session.idleCalls
        #expect(calls.first?.mailbox == "INBOX")
        #expect(calls.first?.timeout == .seconds(25 * 60))
    }

    /// 25 分たって何もなければ、同期せずに IDLE に入り直す。
    @Test func aTimeoutRenewsIdleWithoutSyncing() async {
        let session = ScriptedSession(steps: [.event(.timedOut), .event(.timedOut), .event(.changed)])
        let recorder = Recorder()
        await run(sessions: [session], recorder: recorder) { await $0.changes >= 1 }
        #expect(await recorder.changes == 1)
        #expect(await session.idleCalls.count >= 3)
    }

    /// つながり直したときに、切れていた間の新着を取るため 1 回同期する。
    @Test func reconnectsAfterADroppedConnectionAndCatchesUp() async {
        let first = ScriptedSession(steps: [.fail])
        let second = ScriptedSession(steps: [])
        let recorder = Recorder()
        await run(sessions: [first, second], recorder: recorder) { recorder in
            let opens = await recorder.opens
            let changes = await recorder.changes
            return opens >= 2 && changes >= 1
        }
        #expect(await first.closed)
        #expect(await recorder.sleeps.first == .seconds(1))
        #expect(await recorder.changes == 1)
    }

    /// つながらないときは、1 秒 → 2 秒 → 4 秒 … と間をあけ、5 分より長くは待たない。
    @Test func backsOffWhileOffline() async {
        let recorder = Recorder()
        await run(sessions: Array(repeating: nil, count: 12), recorder: recorder) { await $0.sleeps.count >= 11 }
        let sleeps = await recorder.sleeps
        #expect(Array(sleeps.prefix(5)) == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)])
        #expect(sleeps.max() == .seconds(300))
    }

    /// IDLE に対応していないサーバーは、1 分ごとに同期する。
    @Test func pollsEveryMinuteWithoutIdle() async {
        let session = ScriptedSession(idle: false, steps: [])
        let recorder = Recorder()
        await run(sessions: [session], recorder: recorder) { await $0.changes >= 3 }
        #expect(await session.idleCalls.isEmpty)
        #expect(await recorder.sleeps.prefix(3).allSatisfy { $0 == .seconds(60) })
    }

    @Test func stoppingClosesTheConnection() async {
        let session = ScriptedSession(steps: [])
        let recorder = Recorder()
        await run(sessions: [session], recorder: recorder) { _ in await session.idleCalls.count >= 1 }
        #expect(await session.closed)
    }
}
