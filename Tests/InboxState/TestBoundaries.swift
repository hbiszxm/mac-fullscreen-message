import AppKit

let inboxTestSuiteName = "cn.local.fullscreen-message.tests.inbox-state.\(UUID().uuidString)"
let inboxTestDefaults = UserDefaults(suiteName: inboxTestSuiteName)!
var inboxTestSoundCount = 0

func inboxExpect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

/// Same presentation gate interface; never observes or changes the real session.
final class PresentationAvailability {
    private(set) var canPresent = false
    private var onChange: ((Bool) -> Void)?
    init() { precondition(Thread.isMainThread) }
    func start(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        onChange(canPresent)
    }
    func stop() { onChange = nil }
    func setAvailability(_ available: Bool) {
        precondition(Thread.isMainThread)
        canPresent = available
        onChange?(available)
    }
}

/// No NSWindow exists in this stub. It lets the real AppDelegate exercise
/// visible, unavailable, suspended and explicitly dismissed presentations.
final class FullScreenAlertController {
    static var creationCount = 0
    static var presentationCount = 0
    static var suspensionCount = 0
    static var canCreate = true
    static var presentationSucceeds = true
    private let responseHandler: (Bool) -> Void
    private let dismissHandler: (() -> Void)?
    private var finished = false
    private(set) var isPresented = false

    init?(message: WireMessage, responseHandler: @escaping (Bool) -> Void,
          dismissHandler: (() -> Void)? = nil) {
        guard Self.canCreate else { return nil }
        self.responseHandler = responseHandler
        self.dismissHandler = dismissHandler
        Self.creationCount += 1
    }
    @discardableResult
    func present() -> Bool {
        guard !finished else { return false }
        Self.presentationCount += 1
        isPresented = Self.presentationSucceeds
        return isPresented
    }
    func suspend() {
        guard !finished else { return }
        Self.suspensionCount += 1
        finished = true
        isPresented = false
    }
    func simulateEscape() {
        guard !finished else { return }
        finished = true
        isPresented = false
        dismissHandler?()
    }
}

/// An un-ordered window with injectable visibility. This tests the actual
/// production view visibility checks without showing a window or taking focus.
final class InboxReadableWindow: NSWindow {
    var simulatedReadable = false
    override var isKeyWindow: Bool { simulatedReadable }
    override var isVisible: Bool { simulatedReadable }
    override var occlusionState: NSWindow.OcclusionState { simulatedReadable ? [.visible] : [] }
}
