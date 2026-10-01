import Foundation

/** A calendar day without a time or time zone, like "2026-09-26" (Java's LocalDate). */
public struct Day: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /** The day at the start of a date such as "2026-09-26" or "2026-09-26T18:30:00Z"; nil for anything else. */
    public init?(_ text: String?) {
        guard let text else { return nil }
        let parts = text.trimmed().prefix(10).split(separator: "-")
        guard parts.count == 3, parts[0].count == 4,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /** The day [date] falls on, here. */
    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /** Days since 1970-01-01. */
    public init(number: Int) {
        // Howard Hinnant's civil_from_days.
        let z: Int = number + 719_468
        let era: Int = (z >= 0 ? z : z - 146_096) / 146_097
        let doe: Int = z - era * 146_097
        let a: Int = doe / 1460
        let b: Int = doe / 36524
        let c: Int = doe / 146_096
        let yoe: Int = (doe - a + b - c) / 365
        let leaps: Int = yoe / 4 - yoe / 100
        let doy: Int = doe - (365 * yoe + leaps)
        let mp: Int = (5 * doy + 2) / 153
        let d: Int = doy - (153 * mp + 2) / 5 + 1
        let m: Int = mp < 10 ? mp + 3 : mp - 9
        let y: Int = yoe + era * 400
        self.init(year: m <= 2 ? y + 1 : y, month: m, day: d)
    }

    public static func today() -> Day { Day(Date()) }

    /** Days since 1970-01-01 (Java's toEpochDay). */
    public var number: Int {
        let y: Int = month <= 2 ? year - 1 : year
        let era: Int = (y >= 0 ? y : y - 399) / 400
        let yoe: Int = y - era * 400
        let mp: Int = (month + 9) % 12
        let doy: Int = (153 * mp + 2) / 5 + day - 1
        let leaps: Int = yoe / 4 - yoe / 100
        let doe: Int = yoe * 365 + leaps + doy
        return era * 146_097 + doe - 719_468
    }

    public func adding(days: Int) -> Day { Day(number: number + days) }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (a: Day, b: Day) -> Bool { a.number < b.number }
}
