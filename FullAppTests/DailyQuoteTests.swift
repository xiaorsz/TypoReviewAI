import XCTest
@testable import CoachLab

@MainActor
final class DailyQuoteTests: XCTestCase {
    func testAvailableServerResponseMapsToDailyQuoteWithExplanation() throws {
        let data = Data(
            """
            {
              "date": "2026-07-31",
              "status": "available",
              "quote": {
                "id": "classic-001",
                "text": "学而时习之，不亦说乎？",
                "kind": "verified",
                "attribution": "《论语·学而》",
                "explanation": "学到知识后经常温习，会发现学习本身也很快乐。",
                "action": "今天睡前用三分钟回顾一个新知识点。"
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(ServerDailyQuoteResponse.self, from: data)
        let quote = try XCTUnwrap(response.dailyQuote)

        XCTAssertEqual(response.status, .available)
        XCTAssertEqual(quote.id, "classic-001")
        XCTAssertEqual(quote.dayKey, "2026-07-31")
        XCTAssertEqual(quote.kind, .verified)
        XCTAssertFalse(quote.explanation.isEmpty)
        XCTAssertFalse(quote.action.isEmpty)
    }

    func testExhaustedServerResponseContainsNoQuote() throws {
        let data = Data(
            """
            {"date":"2026-11-18","status":"exhausted","quote":null}
            """.utf8
        )

        let response = try JSONDecoder().decode(ServerDailyQuoteResponse.self, from: data)

        XCTAssertEqual(response.status, .exhausted)
        XCTAssertNil(response.dailyQuote)
    }

    func testCacheReturnsOnlyTheRequestedDay() {
        let defaults = makeDefaults()
        let cache = DailyQuoteCache(defaults: defaults, storageKey: "dailyQuote.test.cache")
        let quote = makeQuote(dayKey: "2026-07-31")

        cache.save(quote)

        XCTAssertEqual(cache.load(for: "2026-07-31"), quote)
        XCTAssertNil(cache.load(for: "2026-08-01"))
    }

    func testClearingCacheRemovesTodaysQuote() {
        let defaults = makeDefaults()
        let cache = DailyQuoteCache(defaults: defaults, storageKey: "dailyQuote.test.clear")
        cache.save(makeQuote(dayKey: "2026-07-31"))

        cache.clear()

        XCTAssertNil(cache.load(for: "2026-07-31"))
    }

    func testShanghaiDayKeyUsesServerTimezone() {
        let formatter = ISO8601DateFormatter()
        let beforeMidnightUTC = formatter.date(from: "2026-07-31T15:59:59Z")!
        let afterMidnightUTC = formatter.date(from: "2026-07-31T16:00:00Z")!

        XCTAssertEqual(DailyQuoteCache.shanghaiDayKey(for: beforeMidnightUTC), "2026-07-31")
        XCTAssertEqual(DailyQuoteCache.shanghaiDayKey(for: afterMidnightUTC), "2026-08-01")
    }

    private func makeQuote(dayKey: String) -> DailyQuote {
        DailyQuote(
            id: "classic-001",
            dayKey: dayKey,
            text: "学而时习之，不亦说乎？",
            kind: .verified,
            attribution: "《论语·学而》",
            explanation: "学到知识后经常温习，会发现学习本身也很快乐。",
            action: "今天睡前用三分钟回顾一个新知识点。"
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "DailyQuoteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
