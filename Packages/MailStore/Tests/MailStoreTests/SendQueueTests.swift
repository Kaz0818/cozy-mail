import Foundation
import Testing
@testable import MailStore

/// 送信の取り消し (T24、US-15): 決めた秒数は送らずに待ち、その間なら取り消せる。
@Suite struct SendQueueTests {
    /// 送ったもの・届いた知らせを記録する。
    actor Log {
        private(set) var sent: [String] = []
        private(set) var events: [SendQueue.Event] = []
        var failNext = false
        func send(_ draft: Draft) throws -> SendOutcome {
            if failNext {
                failNext = false
                throw CancellationError()
            }
            sent.append(draft.subject)
            return .sent
        }
        func record(_ event: SendQueue.Event) { events.append(event) }
        func setFailNext() { failNext = true }
    }

    private func queue(_ log: Log) -> SendQueue {
        SendQueue(send: { try await log.send($0) }, onEvent: { await log.record($0) })
    }

    private func draft(_ subject: String) -> Draft {
        Draft(accountID: AccountID("a"), to: [Contact(name: "", address: "t@example.com")], subject: subject, body: "本文")
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<300 where !(await condition()) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func sendsAfterTheDelay() async {
        let log = Log()
        let queue = queue(log)
        let id = await queue.enqueue(draft("会議"), delay: .milliseconds(100))
        #expect(await queue.pendingIDs == [id])
        #expect(await log.sent.isEmpty)
        await waitUntil { await log.sent.count == 1 }
        #expect(await log.sent == ["会議"])
        #expect(await queue.pendingIDs.isEmpty)
        #expect(await log.events == [.started(id), .sent(id, .sent)])
    }

    @Test func cancellingBeforeTheDelayGivesTheDraftBackAndSendsNothing() async throws {
        let log = Log()
        let queue = queue(log)
        let id = await queue.enqueue(draft("会議"), delay: .milliseconds(200))
        let restored = await queue.cancel(id)
        #expect(restored?.subject == "会議")
        try await Task.sleep(for: .milliseconds(400))
        #expect(await log.sent.isEmpty)
        #expect(await queue.pendingIDs.isEmpty)
    }

    @Test func tooLateToCancelAfterSending() async {
        let log = Log()
        let queue = queue(log)
        let id = await queue.enqueue(draft("会議"), delay: .milliseconds(20))
        await waitUntil { await log.sent.count == 1 }
        #expect(await queue.cancel(id) == nil)
    }

    /// アプリを終えるときは、待たずにすぐ送る。
    @Test func flushSendsEverythingNow() async {
        let log = Log()
        let queue = queue(log)
        _ = await queue.enqueue(draft("1"), delay: .seconds(30))
        _ = await queue.enqueue(draft("2"), delay: .seconds(30))
        await queue.flush()
        #expect(await log.sent == ["1", "2"])
        #expect(await queue.pendingIDs.isEmpty)
    }

    /// 送り途中のときにアプリを終えても、送り終わるまで待ってから終わる。
    @Test func flushWaitsForASendAlreadyUnderway() async {
        actor Slow {
            var started = false
            var finished = false
            func send() async throws -> SendOutcome {
                started = true
                try await Task.sleep(for: .milliseconds(200))
                finished = true
                return .sent
            }
        }
        let slow = Slow()
        let queue = SendQueue(send: { _ in try await slow.send() }, onEvent: { _ in })
        _ = await queue.enqueue(draft("会議"), delay: .milliseconds(10))
        await waitUntil { await slow.started }
        await queue.flush()
        #expect(await slow.finished)
    }

    /// 終えるために送っている間に、別のメールの秒数が過ぎて送り始めても、それも送り終わるまで待つ。
    @Test func flushAlsoWaitsForASendThatStartsDuringTheFlush() async {
        actor Slow {
            private(set) var finished: [String] = []
            func send(_ draft: Draft) async throws -> SendOutcome {
                try await Task.sleep(for: .milliseconds(200))
                finished.append(draft.subject)
                return .sent
            }
        }
        let slow = Slow()
        let queue = SendQueue(send: { try await slow.send($0) }, onEvent: { _ in })
        _ = await queue.enqueue(draft("1"), delay: .seconds(30))
        _ = await queue.enqueue(draft("2"), delay: .milliseconds(50))
        await queue.flush()
        #expect(await slow.finished.sorted() == ["1", "2"])
    }

    /// 送れなかったら、書いたものを失わないよう下書きを返す。
    @Test func aFailureReturnsTheDraft() async {
        let log = Log()
        await log.setFailNext()
        let queue = queue(log)
        let id = await queue.enqueue(draft("会議"), delay: .milliseconds(20))
        await waitUntil { await log.events.count == 2 }
        guard case let .failed(failedID, failedDraft, _) = await log.events.last else {
            Issue.record("失敗の知らせが来なかった")
            return
        }
        #expect(failedID == id)
        #expect(failedDraft.subject == "会議")
    }
}
