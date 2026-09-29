import Foundation
import Security

public protocol CredentialStoring: Sendable {
    func loadPassword() throws -> String
    func savePassword(_ password: String) throws
}

public enum CredentialStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            "Keychain operation failed (OSStatus \(status))."
        }
    }
}

public struct KeychainCredentialStore: CredentialStoring {
    private let service: String
    private let account: String

    public init(
        service: String = "jp.example.ipphone",
        account: String = "sip-password"
    ) {
        self.service = service
        self.account = account
    }

    public func loadPassword() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw CredentialStoreError.unexpectedStatus(status) }
        guard let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public func savePassword(_ password: String) throws {
        let selector: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if password.isEmpty {
            let status = SecItemDelete(selector as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStoreError.unexpectedStatus(status)
            }
            return
        }

        let data = Data(password.utf8)
        let updateStatus = SecItemUpdate(
            selector as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(updateStatus)
        }

        var item = selector
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(addStatus)
        }
    }
}

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: SIPSettings
    @Published public var password: String
    @Published public private(set) var lastError: String?

    private static let settingsKey = "sip-settings-v1"
    private let defaults: UserDefaults
    private let credentialStore: any CredentialStoring

    public init(
        defaults: UserDefaults = .standard,
        credentialStore: any CredentialStoring = KeychainCredentialStore()
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        if let data = defaults.data(forKey: Self.settingsKey),
           let stored = try? JSONDecoder().decode(SIPSettings.self, from: data)
        {
            settings = stored
        } else {
            settings = SIPSettings()
        }
        do {
            password = try credentialStore.loadPassword()
            lastError = nil
        } catch {
            password = ""
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    public func save() -> [SIPSettingsValidationIssue] {
        let issues = settings.validationIssues()
        guard issues.isEmpty else { return issues }

        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: Self.settingsKey)
            try credentialStore.savePassword(password)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        return []
    }
}
