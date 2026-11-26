import SwiftUI

struct QuickTerminalTabItemView: View {
    @ObservedObject var tab: QuickTerminalTab

    let isHighlighted: Bool
    let isGlassEnabled: Bool
    /// The active Ghostty config, used to format the title (bell prefix etc.)
    /// via `QuickTerminalController.computeTitle` — the same rule the window
    /// title uses for regular terminals.
    let config: Ghostty.Config
    /// Passed in from the bar so we can reset hover state when the tab list
    /// changes — SwiftUI sometimes drops the `.onHover` exit when a tab
    /// shifts out from under the cursor during an insertion/removal, which
    /// leaves the previously-hovered tab's close button stuck visible.
    let tabsCount: Int
    let onSelect: () -> Void
    let onClose: () -> Void
    let shortcut: KeyboardShortcut?
    /// Whether the bar squeezed this tab so far that a title can't be read.
    /// A condensed tab keeps only the leading slot -- the close button while
    /// hovered, the activity indicator otherwise -- so the bar can pack more
    /// tabs before it has to spill into the overflow menu.
    let isCondensed: Bool
    /// Reported up to the bar so it can show the condensed tab's title as a
    /// preview while the pointer is over it: a squeezed tab has no room to
    /// draw one itself.
    let onHoverChange: (Bool) -> Void

    private var displayTitle: String {
        QuickTerminalController.computeTitle(title: tab.title, bell: tab.surfaceBell, config: config)
    }

    @State private var isHovering = false
    @State private var isHoveringCloseButton = false
    /// Whether the pointer is over the leading slot itself. A condensed tab is
    /// only ~30pt wide, so letting a hover anywhere on it reveal the close
    /// button would put the close target under a good half of its area and
    /// turn "switch to this tab" into "close this tab" often enough to hurt.
    @State private var isHoveringLeadingSlot = false

    private var surfaceColor: NSColor {
        tab.backgroundColor.map { NSColor($0) } ?? .windowBackgroundColor
    }

    private var surfaceOpacity: Double {
        tab.backgroundOpacity
    }

    /// Color to blend the surface color toward when dimming or highlighting.
    private var contrastColor: NSColor {
        surfaceColor.isLightColor ? .black : .white
    }

    private func tinted(by fraction: CGFloat, opacity: Double = 1) -> Color {
        let blended = surfaceColor.blended(withFraction: fraction, of: contrastColor) ?? surfaceColor
        return Color(blended).opacity(opacity)
    }

    /// Extra opacity applied to inactive states when glass is enabled so the
    /// glass effect bleeds through behind the tab bar. Kept high enough that
    /// the tint isn't washed out by the glass — especially on light themes.
    private var inactiveGlassOpacity: Double { isGlassEnabled ? 0.85 : 1 }

    /// How far to blend the surface color toward the contrast color for
    /// inactive/hover states. Glass needs a heavier tint since the glass
    /// effect behind the tab dilutes the result.
    private var hoverTint: CGFloat { isGlassEnabled ? 0.30 : 0.20 }
    private var inactiveTint: CGFloat { isGlassEnabled ? 0.55 : 0.35 }

    private var backgroundColor: Color {
        if isHighlighted { return Color(surfaceColor).opacity(surfaceOpacity) }
        let opacity = surfaceOpacity * inactiveGlassOpacity
        if isHovering { return tinted(by: hoverTint, opacity: opacity) }
        return tinted(by: inactiveTint, opacity: opacity)
    }

    private var closeButtonBackgroundColor: Color {
        isHoveringCloseButton ? tinted(by: 0.45) : backgroundColor
    }

    private var primaryForeground: Color { Color(contrastColor) }
    private var secondaryForeground: Color { primaryForeground.opacity(0.6) }

    var body: some View {
        HStack(spacing: Constants.horizontalSpacing) {
            renderLeadingSlot()
            if !isCondensed {
                renderTitle()
                renderColorIndicator()
                if let shortcut = shortcut {
                    renderShortcut(shortcut)
                }
            }
        }
        .padding(.horizontal, Constants.horizontalPadding)
        .frame(height: Constants.height)
        // The bar hands every tab an explicit width; `collapsedWidth` is the
        // floor, enough for the leading slot and nothing else.
        .frame(minWidth: Constants.collapsedWidth, maxWidth: .infinity)
        // Titles truncate long before the bar runs out of room, so the tooltip
        // is the only way to read a full one.
        .help(displayTitle)
        .background(
            Rectangle()
                .fill(backgroundColor)
                .onMiddleClick(perform: onClose)
        )
        .onHover { isHovering in
            self.isHovering = isHovering
            onHoverChange(isHovering)
        }
        .onChange(of: tabsCount) { _ in
            // SwiftUI sometimes drops the `.onHover` exit when a tab shifts
            // out from under the cursor during an insertion/removal, leaving
            // the close button stuck visible. Force a reset; if the cursor
            // really is over this tab the next mouse move will restore it.
            isHovering = false
            isHoveringCloseButton = false
            isHoveringLeadingSlot = false
        }
        .onTapGesture {
            DispatchQueue.main.async {
                onSelect()
            }
        }
    }

    @ViewBuilder private func renderCloseButton() -> some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: Constants.closeButtonFontSize))
                .foregroundColor(isHovering ? primaryForeground : secondaryForeground)
                .padding(Constants.closeButtonPadding)
        }
        .buttonStyle(PlainButtonStyle())
        .background(
            RoundedRectangle(cornerSize: Constants.closeButtonCornerRadius)
                .fill(closeButtonBackgroundColor)
        )
        .onHover { isHoveringCloseButton in
            self.isHoveringCloseButton = isHoveringCloseButton
        }
        .help("Click to close this tab; Option-click to close all tabs except this one")
    }

    /// One thing at a time: the close button while the cursor is over the tab,
    /// and the activity indicator otherwise. Sharing the slot keeps the
    /// indicator away from the title, and the title never shifts because the
    /// slot keeps its width either way.
    ///
    /// A condensed tab only reveals the close button once the pointer is over
    /// the slot itself, so the rest of the tab stays a plain "select me"
    /// target no matter how narrow it gets.
    private var showsCloseButton: Bool {
        isCondensed ? isHoveringLeadingSlot : isHovering
    }

    @ViewBuilder private func renderLeadingSlot() -> some View {
        ZStack {
            if showsCloseButton {
                renderCloseButton()
            } else if let activity = tab.activity {
                renderActivityIndicator(activity)
            }
        }
        .frame(width: Constants.leadingSlotSize, height: Constants.leadingSlotSize)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.12), value: isHoveringLeadingSlot)
        .onHover { isHoveringLeadingSlot = $0 }
    }

    /// The indicator that tells you a tab is still working (or needs you)
    /// while you're reading another one.
    @ViewBuilder private func renderActivityIndicator(_ activity: QuickTerminalTab.Activity) -> some View {
        Group {
            switch activity.kind {
            case .working:
                QuickTerminalTabProgressView(
                    progress: activity.percent,
                    color: isHighlighted ? primaryForeground : secondaryForeground
                )
            case .blocked:
                // A blocked program is not progressing, so it must not look
                // like one: no spin, and a color that says "look at me"
                // instead of the tab's own foreground.
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: Constants.blockedIconSize))
                    .foregroundColor(.orange)
            }
        }
        .help(Self.help(for: activity))
        .accessibilityLabel(Self.help(for: activity))
    }

    /// The tooltip for an activity indicator. The program's own description is
    /// untrusted text, so it is only ever appended as a label.
    private static func help(for activity: QuickTerminalTab.Activity) -> String {
        switch activity.kind {
        case .working:
            let verb = activity.message.isEmpty ? "Running" : activity.message
            guard let percent = activity.percent else { return verb }
            return "\(verb) - \(percent)% complete"

        case .blocked:
            let reason: String
            switch activity.blockReason {
            case .permission: reason = "Waiting for your permission"
            case .question: reason = "Waiting for your answer"
            case .auth: reason = "Waiting for a credential"
            case .none: reason = "Waiting for you"
            }
            return activity.message.isEmpty ? reason : "\(reason): \(activity.message)"
        }
    }

    @ViewBuilder private func renderColorIndicator() -> some View {
        if let color = tab.tabColor.displayColor {
            Circle()
                .fill(Color(color))
                .frame(width: Constants.colorIndicatorSize, height: Constants.colorIndicatorSize)
        }
    }

    @ViewBuilder private func renderTitle() -> some View {
        Text(displayTitle)
            .foregroundColor(isHighlighted ? primaryForeground : secondaryForeground)
            .lineLimit(Constants.titleLineLimit)
            .truncationMode(.tail)
            .frame(minWidth: 0, maxWidth: .infinity)
    }

    @ViewBuilder private func renderShortcut(_ shortcut: KeyboardShortcut) -> some View {
        Text(shortcut.description)
            .font(.system(size: Constants.shortcutFontSize))
            .foregroundColor(isHighlighted ? primaryForeground : secondaryForeground)
            .opacity(0.7)
    }
}

extension QuickTerminalTabItemView {
    enum Constants {
        /// The width a tab shrinks to when the bar runs out of room: the
        /// leading slot and its padding, nothing else. Hovering still reveals
        /// the close button because that is what the slot switches to.
        static let collapsedWidth: CGFloat = horizontalPadding * 2 + leadingSlotSize
        static let height: CGFloat = 24
        static let horizontalSpacing: CGFloat = 4
        static let horizontalPadding: CGFloat = 8
        static let closeButtonPadding: CGFloat = 2
        static let closeButtonCornerRadius: CGSize = .init(width: 4, height: 4)
        static let closeButtonFontSize: CGFloat = 10
        static let shortcutFontSize: CGFloat = 11
        static let colorIndicatorSize: CGFloat = 6
        /// Wide enough for the close button (10pt glyph + 2pt padding each
        /// side) so swapping in the 10pt indicator does not move the title.
        static let leadingSlotSize: CGFloat = 14
        static let blockedIconSize: CGFloat = 10
        static let titleLineLimit: Int = 1
    }
}
