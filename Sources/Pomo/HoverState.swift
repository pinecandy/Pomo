import Combine

/// Hover-state bridge: SwiftUI (`PomoView`) publishes the pill-hover flag,
/// AppKit (`TimerInstanceController`) subscribes so it can scale that timer's
/// NSVisualEffectView glass IN SYNC with the SwiftUI `hoverScale` on the
/// contents.
///
/// The bridge exists because the VEV has to live outside SwiftUI to keep the
/// live `.behindWindow` blur unfrozen. A `.scaleEffect` in SwiftUI therefore
/// only grows the text and icons — the glass underneath would stay put. This
/// flag is the wire that lets it grow with them.
///
/// Owned per-controller, never app-wide: `TimerInstanceController` creates one
/// and injects it into its own `PomoView`.
final class PomoHoverState: ObservableObject {
    /// True while the pointer is over the pill (or POMO_FORCE_HOVER is set).
    @Published var isHovering: Bool = false
}
