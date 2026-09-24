import AppKit
import CoreGraphics

/// A receipt is still unread until the user acts; this gate only decides whether
/// it is appropriate to attempt a full-screen presentation.
struct PresentationAvailabilityState {
    var sessionIsActive = true
    var sessionIsLocked = false
    var screensAreAwake = true
    var systemIsAwake = true
    var hasScreens = true

    var canPresent: Bool {
        sessionIsActive && !sessionIsLocked && screensAreAwake && systemIsAwake && hasScreens
    }
}

/// Main-thread-only session and display monitor. No permission or lock action is
/// performed, and a positive result does not mean that a user has read a message.
final class PresentationAvailability {
    private var state = PresentationAvailabilityState()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var onChange: ((Bool) -> Void)?
    private var lastPublished: Bool?
    private var generation = 0

    init() {
        precondition(Thread.isMainThread)
    }

    var canPresent: Bool {
        precondition(Thread.isMainThread)
        return effectiveState().canPresent
    }

    func start(onChange: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        stop()
        state = PresentationAvailabilityState()
        self.onChange = onChange
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.state.sessionIsActive = false }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.state.sessionIsActive = true }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.state.screensAreAwake = false }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.state.screensAreAwake = true }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.state.systemIsAwake = false }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.state.systemIsAwake = true }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { _ in }

        // These distributed notifications supplement the public workspace
        // events, which also cover switching to a different logged-in user.
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.state.sessionIsLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.state.sessionIsLocked = false }
        publishIfChanged()
    }

    func stop() {
        precondition(Thread.isMainThread)
        generation += 1
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        onChange = nil
        lastPublished = nil
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         change: @escaping (PresentationAvailability) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            change(self)
            self.publishIfChanged()
            // The window server's dictionary and display state can settle just
            // after its notification. Recheck without prematurely showing UI.
            let currentGeneration = self.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.publishIfChanged()
            }
        }
        observers.append((center, token))
    }

    private func effectiveState() -> PresentationAvailabilityState {
        var current = state
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            current.sessionIsActive = false
            return current
        }
        current.sessionIsActive = current.sessionIsActive
            && (session[kCGSessionOnConsoleKey as String] as? Bool == true)
            && (session[kCGSessionLoginDoneKey as String] as? Bool != false)
        // macOS supplies this supplementary key on locked GUI sessions. It is
        // not a public CGSession constant, so absent values are not treated as
        // proof that the session is unlocked; the event state is retained.
        current.sessionIsLocked = current.sessionIsLocked
            || (session["CGSSessionScreenIsLocked"] as? Bool == true)
        let screens = NSScreen.screens
        current.hasScreens = !screens.isEmpty
        let displayIDs = screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        current.screensAreAwake = current.screensAreAwake
            && displayIDs.contains { CGDisplayIsAsleep($0) == 0 }
        return current
    }

    private func publishIfChanged() {
        let available = canPresent
        guard available != lastPublished else { return }
        lastPublished = available
        onChange?(available)
    }
}
