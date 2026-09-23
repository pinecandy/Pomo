import Combine

/// A frame change resamples the behind-window blur and hitches hover.
final class PomoHoverState: ObservableObject {
    /// True while the pointer is over the pill (or POMO_FORCE_HOVER is set).
    @Published var isHovering: Bool = false
}
