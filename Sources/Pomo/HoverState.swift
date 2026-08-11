import Combine

/// Hover-state bridge: SwiftUI (`PomoView`) publishes the pill-hover flag,
/// AppKit (`TimerInstanceController`) subscribes so it can scale that timer's
/// NSVisualEffectView glass in sync with the SwiftUI reflection and glow.
///
/// The bridge exists because the VEV has to live outside SwiftUI to keep the
/// live `.behindWindow` blur unfrozen. This flag keeps the AppKit glass aligned
/// with the SwiftUI glass layers while text and controls remain screen-stable.
///
/// Owned per-controller, never app-wide: `TimerInstanceController` creates one
/// and injects it into its own `PomoView`.
final class PomoHoverState: ObservableObject {
    /// True while the pointer is over the pill (or POMO_FORCE_HOVER is set).
    @Published var isHovering: Bool = false
}
