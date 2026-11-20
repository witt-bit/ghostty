import Combine
import SwiftUI

class QuickTerminalTab: ObservableObject, Identifiable {

    /// User-defined title override. When set, this takes precedence over the surface title.
    @Published var titleOverride: String?

    /// The latest title from the focused surface (without any override applied).
    @Published private(set) var surfaceTitle: String

    /// Whether the focused surface currently has its bell flag set. The view layer
    /// decides whether to prefix the title with a bell glyph based on the user's
    /// `bell-features` config — this property just reflects raw surface state.
    @Published private(set) var surfaceBell: Bool = false

    /// The focused surface's `OSC 9;4` progress report, if any. Programs use it
    /// to say "I'm still working", which is what lets a tab keep showing a
    /// spinner while you look at a different tab.
    @Published private(set) var surfaceProgress: Ghostty.Action.ProgressReport?

    /// Whether a command in the focused surface is still running. A report of
    /// `error` is not busy: the program failed and stopped. `pause` is: the
    /// operation is done but hasn't been dismissed yet.
    var isBusy: Bool {
        switch surfaceProgress?.state {
        case .set, .indeterminate, .pause: return true
        case .remove, .error, .none: return false
        }
    }

    /// The focused surface's `OSC 7501` program status, if any. This is the
    /// richer signal of the two: it can also say that the program is blocked on
    /// the user, so a tab can tell "still working" apart from "needs me".
    @Published private(set) var surfaceProgramStatus: Ghostty.Action.ProgramStatus?

    /// What the tab should show for the program behind it.
    struct Activity {
        enum Kind {
            /// Running.
            case working
            /// Can't continue until the user does something.
            case blocked
        }

        let kind: Kind
        /// What a blocked program needs, when the program said.
        let blockReason: Ghostty.Action.ProgramStatus.Kind?
        /// Percent complete, when the program reported one.
        let percent: UInt8?
        /// One line from the program describing what it is doing, if any.
        let message: String
    }

    /// Whether a command in the focused surface has been running long enough
    /// to be worth showing. Commands that finish quickly (`ls`) would only
    /// flash the indicator, so a command has to survive
    /// `commandBusyDelay` before it counts as activity.
    @Published private(set) var commandBusy: Bool = false

    /// How long a command has to run before its indicator appears.
    private static let commandBusyDelay: TimeInterval = 0.7

    private var commandBusyTimer: Timer?

    /// The activity indicator for the tab, or nil when nothing is running.
    ///
    /// `OSC 7501` wins over `OSC 9;4` because it knows about blocked programs;
    /// a program that only speaks `OSC 9;4` (cargo, ninja, ...) still gets a
    /// spinner out of its progress report. `done` and `error` are not activity:
    /// the program stopped, and the indicator's whole job is to say "still
    /// running".
    var activity: Activity? {
        if let status = surfaceProgramStatus {
            switch status.state {
            case .working:
                return Activity(
                    kind: .working,
                    blockReason: nil,
                    percent: status.progress,
                    message: status.message
                )
            case .blocked:
                return Activity(
                    kind: .blocked,
                    blockReason: status.kind,
                    percent: status.progress,
                    message: status.message
                )
            case .idle, .done, .error, .clear:
                return nil
            }
        }

        // A command is running: this is the fallback for everything that does
        // not report status itself, which is most of what you actually wait on.
        if commandBusy {
            return Activity(kind: .working, blockReason: nil, percent: nil, message: "")
        }

        guard isBusy else { return nil }
        return Activity(kind: .working, blockReason: nil, percent: surfaceProgress?.progress, message: "")
    }

    /// The tab color for visual identification
    @Published var tabColor: TerminalTabColor = .none

    /// The current background color of the focused surface (dynamic if set,
    /// otherwise the configured background color).
    @Published private(set) var backgroundColor: Color?

    /// The configured background opacity of the focused surface. Used to keep
    /// the active tab visually continuous with the translucent terminal below it.
    @Published private(set) var backgroundOpacity: Double = 1

    let id = UUID()
    var surfaceTree: SplitTree<Ghostty.SurfaceView>

    /// The displayed title for the tab. Override wins, otherwise the surface title.
    /// Bell prefix is applied at the view layer where the config is available.
    var title: String { titleOverride ?? surfaceTitle }

    private var cancellables: Set<AnyCancellable> = []

    init(surfaceTree: SplitTree<Ghostty.SurfaceView>, title: String = "Terminal") {
        self.surfaceTree = surfaceTree
        self.surfaceTitle = surfaceTree.first { $0.focused }?.title ?? title

        subscribeToSurface(surfaceTree.first { $0.focused })
    }

    /// Updates the surface subscriptions to track the given surface.
    /// Called when the focused surface changes within this tab.
    func updateFocusedSurface(_ surface: Ghostty.SurfaceView?) {
        subscribeToSurface(surface)
    }

    private func commandBusyChanged(_ busy: Bool) {
        commandBusyTimer?.invalidate()
        commandBusyTimer = nil

        guard busy else {
            commandBusy = false
            return
        }

        commandBusyTimer = Timer.scheduledTimer(
            withTimeInterval: Self.commandBusyDelay,
            repeats: false
        ) { [weak self] _ in
            self?.commandBusy = true
            self?.commandBusyTimer = nil
        }
    }

    private func subscribeToSurface(_ surface: Ghostty.SurfaceView?) {
        cancellables.removeAll()
        commandBusyTimer?.invalidate()
        commandBusyTimer = nil
        commandBusy = false
        guard let surface else {
            backgroundColor = nil
            backgroundOpacity = 1
            surfaceBell = false
            surfaceProgress = nil
            surfaceProgramStatus = nil
            return
        }

        // Mirrors BaseTerminalController's focused-surface title pipeline so the
        // tab's `surfaceTitle` and `surfaceBell` stay in sync from a single sink.
        surface.$title
            .combineLatest(surface.$bell)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title, bell in
                guard let self else { return }
                self.surfaceTitle = title
                self.surfaceBell = bell
            }
            .store(in: &cancellables)

        // Progress reports (OSC 9;4) arrive as a whole new value per report and
        // are cleared by the program when it's done, so there is nothing to
        // merge here: whatever the surface last reported is the current state.
        surface.$progressReport
            .receive(on: DispatchQueue.main)
            .sink { [weak self] report in
                self?.surfaceProgress = report
            }
            .store(in: &cancellables)

        // Program status (OSC 7501) is the same shape: one value per report,
        // cleared by the program (or by the shell's command-finished mark).
        surface.$programStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.surfaceProgramStatus = status
            }
            .store(in: &cancellables)

        // Command level activity. Delayed on the way in so short commands do
        // not flash, but immediate on the way out so the indicator never
        // lingers after the command is gone.
        surface.$commandBusy
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] busy in
                self?.commandBusyChanged(busy)
            }
            .store(in: &cancellables)

        // Prefer the dynamic background color (OSC 11, etc.) and fall back to the
        // surface's configured background. Opacity always comes from the config.
        surface.$backgroundColor
            .combineLatest(surface.$derivedConfig)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dynamic, config in
                guard let self else { return }
                self.backgroundColor = dynamic ?? config.backgroundColor
                self.backgroundOpacity = config.backgroundOpacity
            }
            .store(in: &cancellables)
    }
}
