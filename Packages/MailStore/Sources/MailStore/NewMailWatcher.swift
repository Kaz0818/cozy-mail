import MailCore

/// 1 つのアカウントの受信トレイを見張り、変わったら `onChange` を呼ぶ (T20a、US-12)。
///
/// - IDLE に対応したサーバーでは、IDLE で知らせを待つ。何もなければ `idleRenewal` (25 分) ごとに入り直す
///   (サーバーは 30 分ほどで IDLE を切ることがあるため)。
/// - IDLE がないサーバーでは、`pollInterval` (1 分) ごとに `onChange` を呼ぶ。
/// - つながらない・切れたときは、`firstRetry` から倍々に間をあけ、`maxRetry` より長くは待たずにつなぎ直す。
///   つなぎ直せたら、切れていた間の新着を取るため 1 回 `onChange` を呼ぶ。
///
/// `run()` は、それを動かしている作業が止められるまで戻らない。止めると接続を閉じる。
public struct NewMailWatcher: Sendable {
    public struct Timing: Sendable {
        public var idleRenewal: Duration
        public var pollInterval: Duration
        public var firstRetry: Duration
        public var maxRetry: Duration

        public init(
            idleRenewal: Duration = .seconds(25 * 60),
            pollInterval: Duration = .seconds(60),
            firstRetry: Duration = .seconds(1),
            maxRetry: Duration = .seconds(300)
        ) {
            self.idleRenewal = idleRenewal
            self.pollInterval = pollInterval
            self.firstRetry = firstRetry
            self.maxRetry = maxRetry
        }
    }

    public typealias Opener = @Sendable () async throws -> any MailServerSession

    private let timing: Timing
    private let mailbox: String
    private let openSession: Opener
    private let onChange: @Sendable () async -> Void
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        timing: Timing = Timing(),
        mailbox: String = "INBOX",
        openSession: @escaping Opener,
        onChange: @escaping @Sendable () async -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.timing = timing
        self.mailbox = mailbox
        self.openSession = openSession
        self.onChange = onChange
        self.sleep = sleep
    }

    public func run() async {
        var retry = timing.firstRetry
        var connectedBefore = false
        while !Task.isCancelled {
            let session: any MailServerSession
            do {
                session = try await openSession()
            } catch {
                guard await pause(retry) else { return }
                retry = min(retry * 2, timing.maxRetry)
                continue
            }
            if connectedBefore { await onChange() }
            connectedBefore = true
            var healthy = false
            do {
                try await watch(session, healthy: &healthy)
                await session.close()
                return
            } catch {
                await session.close()
                // 一度でもちゃんと見張れた接続なら、1 秒から待ち直す。すぐ失敗する接続なら、待ち時間を延ばしていく
                // (つながるのに IDLE が失敗し続けるサーバーで、1 秒ごとに同期し続けないため)
                if healthy { retry = timing.firstRetry }
                guard await pause(retry) else { return }
                retry = min(retry * 2, timing.maxRetry)
            }
        }
    }

    /// 1 つの接続で見張り続ける。止められたら戻り、切れたら投げる。
    /// IDLE が結果を返した・1 分の確認が 1 回済んだら `healthy` を true にする。
    private func watch(_ session: any MailServerSession, healthy: inout Bool) async throws {
        if try await session.supportsIdle() {
            while !Task.isCancelled {
                let event = try await session.idle(in: mailbox, timeout: timing.idleRenewal)
                healthy = true
                switch event {
                case .changed: await onChange()
                case .timedOut: continue
                case .cancelled: return
                }
            }
        } else {
            while !Task.isCancelled {
                guard await pause(timing.pollInterval) else { return }
                healthy = true
                await onChange()
            }
        }
    }

    /// 待つ。止められたら false。
    private func pause(_ duration: Duration) async -> Bool {
        do {
            try await sleep(duration)
        } catch {
            return false
        }
        return !Task.isCancelled
    }
}
