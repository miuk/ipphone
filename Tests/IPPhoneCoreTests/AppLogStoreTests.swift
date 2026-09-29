import Testing
@testable import IPPhoneCore

@MainActor
struct AppLogStoreTests {
    @Test
    func limitsEntriesAndExportsText() {
        let store = AppLogStore(maximumEntryCount: 2)
        store.append(.info, category: "Test", "first")
        store.append(.warning, category: "Test", "second")
        store.append(.error, category: "Test", "third")

        #expect(store.entries.map(\.message) == ["second", "third"])
        #expect(store.exportedText.contains("[ERROR] [Test] third"))
    }

    @Test
    func redactsKnownSecretFormats() {
        let message = """
        password=hunter2 response="abcdef"
        Authorization: Digest username=1001
        token=xyz sip:alice:uri-pass@example.test
        """
        let redacted = AppLogStore.redactingSecrets(in: message)
        #expect(!redacted.contains("hunter2"))
        #expect(!redacted.contains("abcdef"))
        #expect(!redacted.contains("username=1001"))
        #expect(!redacted.contains("xyz"))
        #expect(!redacted.contains("uri-pass"))
        #expect(redacted.contains("sip:alice:<redacted>@example.test"))
    }
}
