import Foundation
import Testing
@testable import IPPhoneCore

struct SIPSettingsTests {
    @Test
    func buildsNumberDestinationUsingConfiguredDomain() throws {
        let settings = SIPSettings(
            serverHost: "192.0.2.10",
            serverPort: 5061,
            transport: .tls,
            userID: "1001",
            phoneNumber: "1001",
            sipDomain: "example.test"
        )

        #expect(
            try settings.destinationURI(for: "+81 (3) 1234-5678")
                == "sip:+81312345678@example.test;transport=tls"
        )
    }

    @Test
    func preservesCompleteSIPURI() throws {
        let settings = SIPSettings(serverHost: "example.test")
        #expect(
            try settings.destinationURI(for: "sips:2001@example.net:5061")
                == "sips:2001@example.net:5061"
        )
    }

    @Test
    func bracketsIPv6Domain() throws {
        let settings = SIPSettings(serverHost: "2001:db8::1")
        #expect(try settings.destinationURI(for: "1002") == "sip:1002@[2001:db8::1]")
        #expect(settings.registrarURI == "sip:[2001:db8::1]:5060;transport=udp")
    }

    @Test
    func reportsRequiredAndRangeValidationIssues() {
        let issues = SIPSettings().validationIssues()
        #expect(issues.contains { $0.field == .serverHost })
        #expect(issues.contains { $0.field == .userID })
        #expect(issues.contains { $0.field == .phoneNumber })
    }

    @Test
    func switchingTransportUpdatesOnlyDefaultPort() {
        var defaultSettings = SIPSettings()
        defaultSettings.selectTransport(.tls)
        #expect(defaultSettings.serverPort == 5061)

        var customSettings = SIPSettings(serverPort: 5090)
        customSettings.selectTransport(.tls)
        #expect(customSettings.serverPort == 5090)
    }
}

@MainActor
struct SettingsStoreTests {
    @Test
    func persistsSettingsSeparatelyFromPassword() throws {
        let suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = MemoryCredentialStore()
        let store = SettingsStore(defaults: defaults, credentialStore: credentials)
        store.settings = SIPSettings(
            serverHost: "sip.example.test",
            userID: "1001",
            phoneNumber: "1001"
        )
        store.password = "secret-value"

        #expect(store.save().isEmpty)
        let persistedData = try #require(defaults.data(forKey: "sip-settings-v1"))
        #expect(!String(decoding: persistedData, as: UTF8.self).contains("secret-value"))
        #expect(try credentials.loadPassword() == "secret-value")
    }
}

private final class MemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private var password = ""
    func loadPassword() throws -> String { password }
    func savePassword(_ password: String) throws { self.password = password }
}
