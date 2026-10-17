import XCTest
@testable import Reset

/// The window scanner reads transcripts straight from their bytes; these rows pin down what it keeps.
final class TranscriptParseTests: XCTestCase {
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    func testKeepsResponsesAndLimitsAndStopsAtTheLastCompleteLine() throws {
        let rows = [
            "",
            #"{"type":"user","timestamp":"2026-03-02T09:00:00.000Z"}"#,
            #"{"type":"assistant","timestamp":"2026-03-02T09:14:05.120Z","requestId":"r1","message":{}}"#,
            "", "",
            #"{"type":"assistant","timestamp":"2026-03-02T09:20:00.000Z","isApiErrorMessage":true,"requestId":"r2"}"#,
            #"{"type":"assistant","timestamp":"2026-03-02T09:21:00.000Z","message":{}}"#,
            #"{"type":"assistant","message":{}}"#,
            #"{"type":"assistant","timestamp":"2026-03-02T10:00:00.000Z","quotaLimits":{"status":"rejected","resetsAt":1772460000,"rateLimitType":"five_hour"}}"#,
        ]
        let complete = rows.joined(separator: "\n") + "\n"
        let halfWritten = #"{"type":"assistant","timestamp":"2026-03-02T10:05:00.000Z","requestId":"r3""#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try (complete + halfWritten).write(to: url, atomically: true, encoding: .utf8)
        let size = complete.utf8.count + halfWritten.utf8.count

        let (events, offset) = TranscriptScanner.parse(url, from: 0, size: size)
        XCTAssertEqual(events, [.init(time: iso.date(from: "2026-03-02T09:14:05.120Z")!, kind: .activity),
                                .init(time: iso.date(from: "2026-03-02T10:00:00.000Z")!,
                                      kind: .fiveHourLimit(Date(timeIntervalSince1970: 1_772_460_000)))],
                       "not the user row, the error, the row without a requestId or timestamp, or the half-written row")
        XCTAssertEqual(offset, complete.utf8.count, "the half-written row is read next time")

        // An append starts mid-file, and a file can be read only up to the size seen when it was listed.
        let afterThird = rows.prefix(3).joined(separator: "\n").utf8.count + 1
        XCTAssertEqual(TranscriptScanner.parse(url, from: afterThird, size: size).0.count, 1, "only the limit row")
        XCTAssertEqual(TranscriptScanner.parse(url, from: 0, size: afterThird).0.count, 1, "only the first response")
        XCTAssertEqual(TranscriptScanner.parse(url, from: offset, size: size).1, offset, "nothing complete past the offset")
    }

    func testReadsTimestampsExactlyAsTheFormatterDoes() {
        func read(_ s: String) -> Date? { Array(s.utf8).withUnsafeBytes { TranscriptScanner.date($0) } }
        // Every day from 2020 through 2031, each at a different time and millisecond.
        let first = iso.date(from: "2020-01-01T00:00:00.000Z")!
        for i in 0..<4383 {
            let s = iso.string(from: first.addingTimeInterval(Double(i) * 86400 + Double((i * 7_919_311) % 86_400_000) / 1000))
            XCTAssertEqual(read(s), iso.date(from: s), s)
        }
        // Shapes and values left to the formatter, whatever it makes of them.
        for s in ["2024-02-29T23:59:59.999Z", "2023-02-29T00:00:00.000Z", "2026-04-31T00:00:00.000Z", "2026-13-01T00:00:00.000Z",
                  "2026-03-02T24:00:00.000Z", "2026-03-02T09:14:60.000Z", "1999-12-31T23:59:59.999Z", "2026-03-02T09:14:05Z",
                  "2026-03-02T09:14:05.12Z", "2026-03-02T09:14:05.120+05:30", "2026-03-02T09:14:05.1a0Z", "not a date",
                  "2000-02-29T12:00:00.000Z", "2100-02-29T00:00:00.000Z", "2400-02-29T00:00:00.000Z"] {
            XCTAssertEqual(read(s), iso.date(from: s), s)
        }
        // Bytes that aren't text never make a date, as when the row was read as a String.
        XCTAssertNil((Array("2026-03-02T09:14:05.120Z".utf8) + [0xFF]).withUnsafeBytes { TranscriptScanner.date($0) })
    }
}
