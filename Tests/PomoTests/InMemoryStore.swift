import Foundation

@testable import Pomo

/// A dictionary standing in for `UserDefaults`.
///
/// Exists because the alternative — a real `UserDefaults(suiteName:)` per test
/// — cannot be cleaned up reliably. `removePersistentDomain(forName:)` empties
/// the domain but leaves an empty `<suite>.plist` in ~/Library/Preferences,
/// and deleting the file races cfprefsd flushing the domain back out. Measured:
/// 76 stray files accumulated in the developer's home across a handful of test
/// runs even with a per-test delete AND a class-level sweep in place.
///
/// This touches no filesystem, so there is nothing to race and nothing to
/// clean up. It also makes each test's starting state provably empty rather
/// than "whatever survived the last run".
final class InMemoryStore: KeyValueStore {
    private(set) var storage: [String: Any] = [:]

    /// Every key currently set. Replaces the `persistentDomain(forName:)`
    /// lookup a real suite needed, and lets a test assert what was NOT
    /// written as easily as what was.
    var keys: [String] { storage.keys.sorted() }

    func integer(forKey defaultName: String) -> Int {
        // Matches UserDefaults: a missing or non-numeric value reads as 0.
        storage[defaultName] as? Int ?? 0
    }

    func string(forKey defaultName: String) -> String? {
        storage[defaultName] as? String
    }

    func data(forKey defaultName: String) -> Data? {
        storage[defaultName] as? Data
    }

    func set(_ value: Any?, forKey defaultName: String) {
        // Matches UserDefaults: setting nil removes the key.
        guard let value = value else {
            storage.removeValue(forKey: defaultName)
            return
        }
        storage[defaultName] = value
    }

    /// Test-side read that does not go through the protocol, for assertions.
    func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }
}
