import MailStore
import SwiftUI

/// 「送信を取り消す」の帯 (T24、US-15)。送るのを待っているメールごとに、メインウィンドウの下に出す。
/// 押すと送らずに、元の中身で作成ウィンドウを開き直す。
struct UndoSendBanner: View {
    @Environment(MailService.self) private var service
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 8) {
            ForEach(service.pendingSends) { pending in
                HStack(spacing: 12) {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(Palette.accent)
                    Text("「\(Self.title(pending.subject))」を送信します")
                        .lineLimit(1)
                        .foregroundStyle(Palette.textPrimary)
                    Button("送信を取り消す") {
                        Task { await undo(pending.id) }
                    }
                    .buttonStyle(.plain)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .accessibilityIdentifier("undoSend.button")
                }
                .padding(.horizontal, 18)
                .frame(height: 40)
                .glassCapsule()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: service.pendingSends)
    }

    static func title(_ subject: String) -> String {
        subject.trimmingCharacters(in: .whitespaces).isEmpty ? "(件名なし)" : subject
    }

    private func undo(_ id: UUID) async {
        // 間に合わなかった (もう送り始めた) ときは、何もしない
        guard await service.cancelSend(id) else { return }
        openWindow(id: CozyMailApp.composeWindowID, value: ComposeRequest.restoring(id))
    }
}

/// あとで送ったメールについての知らせ (T24)。送れなかったら、書いた中身を作成ウィンドウで開き直す。
/// 送れたが「送信済み」に残せなかったときは、そのことだけを知らせる。
struct SendNoticeAlert: ViewModifier {
    @Environment(MailService.self) private var service
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        let notice = service.sendNotices.first
        return content.alert(
            notice?.canReopen == false ? "送りました" : "送れませんでした",
            isPresented: Binding(get: { notice != nil }, set: { _ in }),
            presenting: notice,
            actions: { notice in
                if notice.canReopen {
                    Button("作成ウィンドウで開く") {
                        service.dismissSendNotice(notice.id)
                        openWindow(id: CozyMailApp.composeWindowID, value: ComposeRequest.restoring(notice.id))
                    }
                } else {
                    Button("OK") { service.dismissSendNotice(notice.id) }
                }
            },
            message: { notice in
                if notice.canReopen {
                    Text("「\(UndoSendBanner.title(notice.subject))」を送れませんでした。\n\(notice.message)\n書いた中身は作成ウィンドウで開き直せます。")
                } else {
                    Text("「\(UndoSendBanner.title(notice.subject))」: \(notice.message)")
                }
            }
        )
    }
}
