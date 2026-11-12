import Foundation

/// メールの日時の見せ方。一覧は短く、本文は日と時刻。
enum MailDateText {
    static func list(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return format(date, "H:mm", calendar).paddedHour(from: date, calendar: calendar)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨日"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return format(date, "M/d", calendar)
        }
        return format(date, "yyyy/M/d", calendar)
    }

    static func reader(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = format(date, "H:mm", calendar)
        if calendar.isDate(date, inSameDayAs: now) { return "今日 \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨日 \(time)"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return format(date, "M月d日", calendar) + " " + time
        }
        return format(date, "yyyy年M月d日", calendar) + " " + time
    }

    private static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

private extension String {
    /// 一覧の時刻は見本どおり 2 桁の時 (`09:30`) にそろえる。
    func paddedHour(from date: Date, calendar: Calendar) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return String(format: "%02d:%02d", hour, minute)
    }
}
