import SwiftUI

/// Live-tuning panel (⌘T). One slider per optical knob in `TuningStore`;
/// dragging a slider updates the real pill instantly — the SwiftUI contents
/// re-render off the @Published value, and the AppKit glass follows through
/// `TimerInstanceController`'s Combine subscriptions.
///
/// Geometry is deliberately absent: every pill dimension comes from
/// `PillLayout` (DesignTokens.swift), so there is nothing here to tune.
struct TuningPanelView: View {
    @ObservedObject var tuning = TuningStore.shared
    @ObservedObject var sizeController = PomoSizeController.shared

    /// This panel's own chrome. Flat (not per-PomoSize) on purpose — the
    /// settings window is not the pill, so it does not follow the pill's
    /// size class.
    private enum Chrome {
        static let rowSpacing: CGFloat  = 14
        static let stackSpacing: CGFloat = 4
        static let padding: CGFloat     = 16
        static let minWidth: CGFloat    = 340
        static let minHeight: CGFloat   = 420
        static let titleSize: CGFloat   = 15
        static let subtitleSize: CGFloat = 11
        static let sectionSize: CGFloat = 10
        static let sectionKerning: CGFloat = 0.6
        static let labelSize: CGFloat   = 12
        static let readoutSize: CGFloat = 11
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Chrome.rowSpacing) {
                header

                sectionTitle("Appearance")
                factorRow(title: "Hover scale", value: $tuning.hoverScale, range: 1.0...1.10)
                valueRow(title: "Glass opacity", value: $tuning.glassOpacity,
                         range: 0.3...1.0, format: "%.2f")
                Divider().padding(.vertical, 2)

                Button("Reset to defaults") {
                    tuning.resetToDefaults()
                }
                .controlSize(.small)
            }
            .padding(Chrome.padding)
        }
        .frame(minWidth: Chrome.minWidth, minHeight: Chrome.minHeight)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: Chrome.sectionSize, weight: .semibold))
            .foregroundColor(.secondary)
            .kerning(Chrome.sectionKerning)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Pill Tuning")
                .font(.system(size: Chrome.titleSize, weight: .semibold))
            Text("Size \(sizeController.current.displayName) · H = \(Int(sizeController.current.pillSize.height))pt")
                .font(.system(size: Chrome.subtitleSize))
                .foregroundColor(.secondary)
        }
    }

    /// Plain numeric slider row with a custom format (e.g. opacity 0.60).
    @ViewBuilder
    private func valueRow(title: String,
                          value: Binding<CGFloat>,
                          range: ClosedRange<CGFloat>,
                          format: String) -> some View {
        sliderRow(title: title, value: value, range: range) {
            String(format: format, $0)
        }
    }

    /// Absolute-factor slider row (e.g. hover scale 1.00–1.10).
    @ViewBuilder
    private func factorRow(title: String,
                           value: Binding<CGFloat>,
                           range: ClosedRange<CGFloat>) -> some View {
        sliderRow(title: title, value: value, range: range) {
            String(format: "%.3f×", $0)
        }
    }

    @ViewBuilder
    private func sliderRow(title: String,
                           value: Binding<CGFloat>,
                           range: ClosedRange<CGFloat>,
                           readout: @escaping (CGFloat) -> String) -> some View {
        VStack(alignment: .leading, spacing: Chrome.stackSpacing) {
            HStack {
                Text(title)
                    .font(.system(size: Chrome.labelSize, weight: .medium))
                Spacer()
                Text(readout(value.wrappedValue))
                    .font(.system(size: Chrome.readoutSize, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }
}
