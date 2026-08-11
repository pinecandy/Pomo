import AppKit
import Combine
import SwiftUI

/// Live-tuning store for the pill's optical knobs — the handful of appearance
/// values that are a matter of taste rather than geometry. Every dimension the
/// pill draws comes from `PillLayout` (DesignTokens.swift) instead; this store
/// deliberately holds nothing that participates in layout.
///
/// Each knob persists under `pomo.tuning.<name>`. `TuningPanelView` (⌘T) is the
/// only editor.
///
/// Readers:
///   - `hoverScale`   → PomoView (glass layers) + TimerInstanceController (glass)
///   - `glassOpacity` → TimerInstanceController (the VEV's alphaValue)
final class TuningStore: ObservableObject {
    static let shared = TuningStore()

    enum Default {
        static let hoverScale: CGFloat = 1.03
        // Glass (VEV) alpha. Semi-transparent for a glassy, see-through look,
        // but high enough that the VEV's own gaussian-blurred backdrop
        // dominates over raw wallpaper bleeding through the transparency — at
        // 0.6 the sharp desktop read through too clearly (user: frost the
        // backdrop). 0.8 is still translucent glass, far less sharp bleed.
        static let glassOpacity: CGFloat = 0.8
    }

    /// Glass growth factor while hovered. Applied to the SwiftUI glass layers
    /// and the AppKit glass — see `TimerInstanceController`.
    @Published var hoverScale: CGFloat { didSet { persist("hoverScale", hoverScale) } }
    /// VEV alpha (0.3–1.0). Lower = more see-through / glassier.
    @Published var glassOpacity: CGFloat { didSet { persist("glassOpacity", glassOpacity) } }

    private static let prefix = "pomo.tuning."
    private static func key(_ name: String) -> String { prefix + name }

    private func persist(_ name: String, _ value: CGFloat) {
        UserDefaults.standard.set(Double(value), forKey: Self.key(name))
    }

    private init() {
        let d = UserDefaults.standard
        func load(_ name: String) -> CGFloat? {
            d.object(forKey: Self.key(name)) != nil
                ? CGFloat(d.double(forKey: Self.key(name)))
                : nil
        }
        hoverScale   = load("hoverScale")   ?? Default.hoverScale
        glassOpacity = load("glassOpacity") ?? Default.glassOpacity
    }

    func resetToDefaults() {
        hoverScale   = Default.hoverScale
        glassOpacity = Default.glassOpacity
    }
}
