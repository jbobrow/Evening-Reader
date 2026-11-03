import Foundation

/// Publication dates arrive in whatever format the publisher felt like.
///
/// A publication date is a calendar day, and a day is the only thing the app ever
/// shows. So anything naming a day rather than a moment is anchored to midnight
/// where the reader is, and the day the publisher wrote is the day the reader sees.
/// Reading `2026-08-29` as midnight UTC and then printing it in California is how an
/// article comes to be dated the day before it came out.
///
/// Shared because the app is not the only thing that reads an article out of a page: the
/// Mac's browser extensions do too, and a date has to come out the same either way.
enum PublishedDate {
    static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let day = calendarDay(text) { return day }

        let iso = ISO8601DateFormatter()
        for options in [[.withInternetDateTime, .withFractionalSeconds] as ISO8601DateFormatter.Options,
                        [.withInternetDateTime]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: text) { return date }

        // A day written out in words is a day like any other, and is read where the
        // reader is for the same reason.
        formatter.timeZone = .current
        for format in ["yyyy/MM/dd", "MMMM d, yyyy", "d MMMM yyyy", "MMM d, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Local midnight on the day a string names, for a string that names a day: a bare
    /// `2026-08-29`, or a timestamp whose clock reads midnight in whatever zone it
    /// states.
    ///
    /// That second case is not a curiosity. It is what a date-only value becomes once
    /// something upstream widens it into a timestamp — Defuddle hands back a page's
    /// `2026-08-29` as `2026-08-29T00:00:00+00:00`, and the day is already gone by the
    /// time it arrives here. A publisher that means a moment writes one; midnight on the
    /// nose is a day wearing a clock.
    private static func calendarDay(_ text: String) -> Date? {
        guard text.count >= 10 else { return nil }
        let pieces = text.prefix(10).split(separator: "-")
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2])
        else { return nil }

        var clock = text.dropFirst(10)
        if !clock.isEmpty {
            guard clock.first == "T" || clock.first == " " else { return nil }
            clock = clock.dropFirst()
            // The zone, if one is stated, is not part of the question: midnight in the
            // publisher's zone is still the day the publisher meant.
            for designator in ["Z", "+", "-"] {
                if let cut = clock.range(of: designator) { clock = clock[..<cut.lowerBound] }
            }
            var reading = String(clock)
            if let dot = reading.firstIndex(of: ".") {
                guard reading[reading.index(after: dot)...].allSatisfy({ $0 == "0" }) else { return nil }
                reading = String(reading[..<dot])
            }
            guard ["00:00", "00:00:00", "0000", "000000"].contains(reading) else { return nil }
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components)
    }
}
