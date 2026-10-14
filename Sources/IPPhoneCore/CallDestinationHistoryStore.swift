import Combine
import Foundation

@MainActor
public final class CallDestinationHistoryStore: ObservableObject {
    @Published public private(set) var destinations: [String]

    private static let storageKey = "call-destination-history-v1"
    private static let maximumCount = 20
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var restored: [String] = []
        for value in defaults.stringArray(forKey: Self.storageKey) ?? [] {
            let destination = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !destination.isEmpty && !restored.contains(destination) {
                restored.append(destination)
            }
            if restored.count == Self.maximumCount { break }
        }
        destinations = restored
    }

    public func record(_ value: String) {
        let destination = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return }
        destinations.removeAll { $0 == destination }
        destinations.insert(destination, at: 0)
        destinations = Array(destinations.prefix(Self.maximumCount))
        defaults.set(destinations, forKey: Self.storageKey)
    }

    public func clear() {
        destinations = []
        defaults.removeObject(forKey: Self.storageKey)
    }
}
