import AppKit
import Combine

/// Three preset window sizes for the Pomo pill.
enum PomoSize: String, CaseIterable {
    case small
    case medium
    case large

    var displayName: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        }
    }

    /// Pill content dimensions (just the capsule, no shadow margin).
    /// Delegates to `PillLayout` (the token-first geometry system) so this
    /// preset table can never drift from what the pill actually renders. The
    /// "canonical" size for a preset is its 2-digit baseline (minutes < 100)
    /// — the numbers themselves are derived, never written down here.
    var pillSize: NSSize {
        PillLayout(sizeClass: self, minuteDigits: 2).pillSize
    }

    static func next(after current: PomoSize) -> PomoSize {
        switch current {
        case .small:  return .medium
        case .medium: return .large
        case .large:  return .large // saturate
        }
    }

    static func previous(before current: PomoSize) -> PomoSize {
        switch current {
        case .small:  return .small // saturate
        case .medium: return .small
        case .large:  return .medium
        }
    }
}

/// Shared, observable controller for the window size preset.
/// Owns persistence to UserDefaults under key "pomo.window.size".
final class PomoSizeController: ObservableObject {
    static let shared = PomoSizeController()

    @Published private(set) var current: PomoSize

    private static let defaultsKey = "pomo.window.size"

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let saved = PomoSize(rawValue: raw) {
            self.current = saved
        } else {
            self.current = .medium
        }
    }

    /// Set a new size and persist it. Invokes the size-change handler so the
    /// window controller can resize and reposition the NSWindow.
    func set(_ size: PomoSize) {
        guard size != current else { return }
        current = size
        UserDefaults.standard.set(size.rawValue, forKey: Self.defaultsKey)
        onChange?(size)
    }

    func bump(_ direction: Int) {
        if direction > 0 {
            set(PomoSize.next(after: current))
        } else if direction < 0 {
            set(PomoSize.previous(before: current))
        }
    }

    /// Hook the AppDelegate / window controller sets so it can react to changes.
    var onChange: ((PomoSize) -> Void)?
}
