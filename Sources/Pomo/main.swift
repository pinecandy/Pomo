import AppKit
import SwiftUI

// POMO_RENDER_PNG=/path.png — offscreen-render the pill onto a dark colorful
// background and exit. Bypasses the floating .behindWindow panel (which
// `screencapture` does not reliably capture) so layout changes can be verified
// deterministically as a flat image. Used by Forge for padding QA.
if let outPath = ProcessInfo.processInfo.environment["POMO_RENDER_PNG"] {
  MainActor.assumeIsolated {
    AppDelegate.applyForcedSizeIfAny()
    let model = PomodoroSource(instanceIndex: 0)
    AppDelegate.applyForcedPhaseIfAny(model: model)

    let pill = PomoView().environmentObject(model)

    // §3.6: the QA canvas is PillLayout.windowSize for the SAME
    // {sizeClass, minuteDigits} the live pill would resolve — computed from
    // the model AFTER applyForcedPhaseIfAny, so POMO_REMAINING_SECONDS is
    // reflected in the canvas size exactly like a real launch. This is what
    // makes the PNG harness and the real app agree on every dimension (§9:
    // no separate QA-only sizing math).
    let layout = PillLayout(sizeClass: PomoSizeController.shared.current,
                            minuteDigits: model.minuteDigits)

    // Window-sized canvas (pill + shadow padding) over a dark, colorful field so
    // the side whitespace is obvious against the capsule edge.
    let canvas = layout.windowSize
    let bg = LinearGradient(
        colors: [
            Color(red: 0.10, green: 0.02, blue: 0.20),
            Color(red: 0.02, green: 0.12, blue: 0.18),
            Color(red: 0.18, green: 0.04, blue: 0.10),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    let pillSize = layout.pillSize
    let composed = ZStack {
        bg
        // Draw the ACTUAL capsule rect (== pillSize, what the VEV renders live)
        // as a translucent fill + bright outline so the content-to-edge gap is
        // measurable. This is the boundary the horizontal padding pushes against.
        RoundedRectangle(cornerRadius: pillSize.height * Tokens.Decor.cornerFactor, style: .circular)
            .fill(Color.black.opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: pillSize.height * Tokens.Decor.cornerFactor, style: .circular)
                    .stroke(Color.yellow.opacity(0.9), lineWidth: 1)
            )
            .frame(width: pillSize.width, height: pillSize.height)
        pill
    }
    .frame(width: canvas.width, height: canvas.height)

    let renderer = ImageRenderer(content: composed)
    renderer.scale = 2.0
    if let nsImage = renderer.nsImage,
       let tiff = nsImage.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: outPath))
        FileHandle.standardError.write(Data("POMO_RENDER_PNG wrote \(outPath)\n".utf8))
    } else {
        FileHandle.standardError.write(Data("POMO_RENDER_PNG render failed\n".utf8))
    }
  }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // `NSApplication.delegate` is weak, and this local is the only strong
    // reference. Without withExtendedLifetime, ARC is free to release it at
    // its last use — the assignment above — leaving the delegate nil before
    // applicationDidFinishLaunching ever fires. Invisible in debug builds;
    // in release it would present as "app launches, no window", the same
    // symptom as the offscreen-origin bug.
    withExtendedLifetime(delegate) {
        app.run()
    }
}
