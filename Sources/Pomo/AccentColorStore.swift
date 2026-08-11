import Combine
import SwiftUI

/// Gauge/accent color single source of truth. `Tokens.Decor.accentGreenRGB`
/// delegates here.
final class AccentColorStore: ObservableObject {
    static let shared = AccentColorStore()
    static let defaultsKey = "pomo.accent.rgb"           // stored as "R,G,B" (0-255 ints)
    static let defaultRGB: (Double, Double, Double) = (0.0/255, 167.0/255, 96.0/255)

    @Published private(set) var rgb: (Double, Double, Double)

    private init() {
        // Priority: QA env POMO_ACCENT_RGB (non-persistent) > UserDefaults > default.
        if let env = ProcessInfo.processInfo.environment["POMO_ACCENT_RGB"],
           let parsed = Self.parse(env) {
            rgb = parsed
        } else if let stored = UserDefaults.standard.string(forKey: Self.defaultsKey),
                  let parsed = Self.parse(stored) {
            rgb = parsed
        } else {
            rgb = Self.defaultRGB
        }
    }

    /// Accepts "R,G,B" (whitespace tolerant) and "#RRGGBB"/"RRGGBB" hex. 0-255
    /// range validated. Returns nil on any parse/validation failure.
    ///
    /// The hex guard needs BOTH conjuncts, for opposite reasons:
    ///
    /// - `isASCII` alongside `isHexDigit`, because `Character.isHexDigit` is
    ///   Unicode-aware. A fullwidth "ＦＦ００００" satisfies it, but `Scanner`
    ///   parsed nothing from it — and the old code discarded the scanner's
    ///   success flag, so the gauge silently turned black. A partly-fullwidth
    ///   "00A79６" was worse: it produced (0,10,121), a wrong colour with no
    ///   hint anything went wrong. Both are reachable, since this dialog's own
    ///   prompt is Japanese and an IME left in fullwidth mode types exactly
    ///   those characters. Both now return nil.
    ///
    /// - `UInt64(_:radix:)` rather than `Scanner`, because the scanner stops
    ///   at the first bad character instead of rejecting the string. But it
    ///   permits a leading sign, so "+FF000" and "-00000" are six characters
    ///   that parse — hence the character-class guard in front of it.
    static func parse(_ raw: String) -> (Double, Double, Double)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // hex
        let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        if hex.count == 6, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }),
           let v = UInt64(hex, radix: 16) {
            return (Double((v >> 16) & 0xFF)/255, Double((v >> 8) & 0xFF)/255, Double(v & 0xFF)/255)
        }
        // "R,G,B"
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 else { return nil }
        let ints = parts.compactMap { Int($0) }
        guard ints.count == 3, ints.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return (Double(ints[0])/255, Double(ints[1])/255, Double(ints[2])/255)
    }

    /// Inverse of `parse` for the "R,G,B" form — the one place a triple turns
    /// into the stored/displayed string.
    static func format(_ rgb: (Double, Double, Double)) -> String {
        let r = Int((rgb.0 * 255).rounded())
        let g = Int((rgb.1 * 255).rounded())
        let b = Int((rgb.2 * 255).rounded())
        return "\(r),\(g),\(b)"
    }

    /// Sets + persists (stored as "R,G,B"). All windows update immediately via
    /// @Published.
    func set(_ newRGB: (Double, Double, Double)) {
        rgb = newRGB
        UserDefaults.standard.set(Self.format(newRGB), forKey: Self.defaultsKey)
    }

    /// Reverts to the default (0,167,96) and removes the stored key.
    func reset() {
        rgb = Self.defaultRGB
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }
}
