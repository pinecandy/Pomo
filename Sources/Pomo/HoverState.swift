import Combine

/// Hover-state bridge: SwiftUI (`PomoView`) publishes the pill-hover flag,
/// AppKit (`TimerInstanceController`) subscribes so it can take and return
/// keyboard focus. The live blur view is not resized on hover. A frame change
/// resamples the behind-window blur and hitches the transition.
///
/// Owned per-controller, never app-wide: `TimerInstanceController` creates one
/// and injects it into its own `PomoView`.
final class PomoHoverState: ObservableObject {
    /// True while the pointer is over the pill (or POMO_FORCE_HOVER is set).
    @Published var isHovering: Bool = false
}
