import SwiftUI

/// A small progress indicator for a quick terminal tab, driven by the focused
/// surface's `OSC 9;4` progress report.
///
/// Hand-rolled rather than using `ProgressView` for the same reasons as
/// `SurfaceProgressBar`: the stock control is broken on macOS 26, and this needs
/// to tint with the tab's own foreground color so it reads on light and dark
/// surfaces alike.
struct QuickTerminalTabProgressView: View {
    /// Percent complete (0-100) when the surface reported one. Nil means the
    /// surface only knows that something is running, so the arc spins.
    let progress: UInt8?

    /// The color to draw with; the tab passes its own foreground color.
    let color: Color

    @State private var rotation: Angle = .zero

    private var trim: CGFloat {
        guard let progress else { return Constants.indeterminateTrim }
        // A zero trim draws nothing, which reads as "not started" rather than
        // "0% done", so keep a hairline of arc visible from the first percent.
        return max(CGFloat(progress) / 100, Constants.minimumTrim)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(Constants.trackOpacity), lineWidth: Constants.lineWidth)
            Circle()
                .trim(from: 0, to: trim)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: Constants.lineWidth, lineCap: .round)
                )
                // A determinate ring starts at the top like a dial; an
                // indeterminate arc is rotated by the animation instead.
                .rotationEffect(progress == nil ? rotation : .degrees(-90))
        }
        .frame(width: Constants.size, height: Constants.size)
        .onAppear(perform: start)
        .onChange(of: progress) { _ in start() }
        .accessibilityHidden(true)
    }

    /// Starts (or restarts) the spin. Restarting matters because SwiftUI drops a
    /// `repeatForever` animation once the value it drives returns to its start,
    /// which is what a repeated report would otherwise do.
    private func start() {
        guard progress == nil else {
            rotation = .zero
            return
        }

        rotation = .zero
        withAnimation(.linear(duration: Constants.spinDuration).repeatForever(autoreverses: false)) {
            rotation = .degrees(360)
        }
    }
}

extension QuickTerminalTabProgressView {
    enum Constants {
        static let size: CGFloat = 10
        static let lineWidth: CGFloat = 1.5
        static let trackOpacity: Double = 0.25
        /// A quarter arc reads as motion even at 10pt.
        static let indeterminateTrim: CGFloat = 0.25
        static let minimumTrim: CGFloat = 0.02
        static let spinDuration: Double = 0.9
    }
}