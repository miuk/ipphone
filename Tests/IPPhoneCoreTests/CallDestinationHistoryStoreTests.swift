import Foundation
import Testing
@testable import IPPhoneCore

@MainActor
struct CallDestinationHistoryStoreTests {
    @Test
    func persistsRecentDestinationsAndMovesDuplicatesToFront() throws {
        let suite = "CallDestinationHistoryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CallDestinationHistoryStore(defaults: defaults)

        store.record(" 1001\n")
        store.record("sip:2001@example.test;transport=tls")
        store.record("1001")
        store.record(" \n")

        let expected = ["1001", "sip:2001@example.test;transport=tls"]
        #expect(store.destinations == expected)
        #expect(CallDestinationHistoryStore(defaults: defaults).destinations == expected)
    }

    @Test
    func retainsTwentyMostRecentDestinationsAndClearsPersistedHistory() throws {
        let suite = "CallDestinationHistoryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CallDestinationHistoryStore(defaults: defaults)
        for number in 1...25 { store.record(String(number)) }

        #expect(store.destinations == (6...25).reversed().map { String($0) })
        #expect(CallDestinationHistoryStore(defaults: defaults).destinations == store.destinations)
        store.clear()
        #expect(store.destinations.isEmpty)
        #expect(CallDestinationHistoryStore(defaults: defaults).destinations.isEmpty)
    }
}
