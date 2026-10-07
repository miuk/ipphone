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

    @Test(arguments: ["sip", "sips"])
    func preservesCompleteSIPURI(scheme: String) throws {
        let settings = SIPSettings(serverHost: "example.test")
        let uri = "\(scheme):2001@example.net:5061;transport=tls;user=phone;x-test=value"
        #expect(
            try settings.destinationURI(for: uri) == uri
        )
    }

    @Test
    func bracketsIPv6Domain() throws {
        let settings = SIPSettings(serverHost: "2001:db8::1")
        #expect(try settings.destinationURI(for: "1002") == "sip:1002@[2001:db8::1]")
        #expect(settings.registrarURI == "sip:[2001:db8::1]:5060;transport=udp")
    }

    @Test
    func buildsSIPSRegistrarWhenConfigured() {
        let settings = SIPSettings(
            serverHost: "sip.example.test",
            serverPort: 5061,
            transport: .tls,
            tlsURIScheme: .sips
        )
        #expect(settings.registrarURI == "sips:sip.example.test:5061")
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

    @Test
    func decodesExistingSettingsWithoutLocalIPAddress() throws {
        let settings = SIPSettings(serverHost: "sip.example.test", userID: "1001", phoneNumber: "1001")
        let data = try JSONEncoder().encode(settings)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "localIPAddress")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SIPSettings.self, from: legacyData)
        #expect(decoded == settings)
        #expect(decoded.localIPAddress == nil)
    }

    @Test(arguments: ["127.0.0.1", "192.168.1.10", "::1", "2001:db8::1"])
    func acceptsUnicastIPAddresses(address: String) {
        let settings = SIPSettings(localIPAddress: address)
        #expect(!settings.validationIssues().contains { $0.field == .localIPAddress })
    }

    @Test(arguments: ["", "example.test", "0.0.0.0", "::", "224.0.0.1", "ff02::1", "fe80::1", "fe80::1%en0", "127.0.0.1\r\nVia: invalid"])
    func rejectsInvalidOrUnusableLocalIPAddresses(address: String) {
        let settings = SIPSettings(localIPAddress: address)
        #expect(settings.validationIssues().contains { $0.field == .localIPAddress })
    }

    @Test
    func listsLocalInterfaceAddresses() throws {
        let addresses = try LocalIPAddress.available()
        #expect(addresses.contains { $0.address == "127.0.0.1" })
        #expect(addresses.allSatisfy { !$0.interfaceName.isEmpty && LocalIPAddress.isValid($0.address) })
        #expect(Set(addresses.map(\.id)).count == addresses.count)
    }

    @Test
    func selectsLoopbackSourceForLoopbackServer() {
        #expect(LocalIPAddress.routedSourceAddress(to: "127.0.0.1", port: 5060) == "127.0.0.1")
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
            phoneNumber: "1001",
            localIPAddress: "127.0.0.1"
        )
        store.password = "secret-value"

        #expect(store.save().isEmpty)
        let persistedData = try #require(defaults.data(forKey: "sip-settings-v1"))
        #expect(!String(decoding: persistedData, as: UTF8.self).contains("secret-value"))
        #expect(try credentials.loadPassword() == "secret-value")
        let restored = SettingsStore(defaults: defaults, credentialStore: credentials)
        #expect(restored.settings == store.settings)
        #expect(restored.settings.localIPAddress == "127.0.0.1")
    }
}

private final class MemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private var password = ""
    func loadPassword() throws -> String { password }
    func savePassword(_ password: String) throws { self.password = password }
}
