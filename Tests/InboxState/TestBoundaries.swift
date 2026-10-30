import AppKit
import Network

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
    let senderDisplayName: String
    private let responseHandler: (Bool) -> Void
    private var finished = false
    private(set) var isPresented = false

    init?(message: WireMessage, senderDisplayName: String? = nil, responseHandler: @escaping (Bool) -> Void) {
        guard Self.canCreate else { return nil }
        self.senderDisplayName = senderDisplayName ?? message.sender
        self.responseHandler = responseHandler
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
        responseHandler(false)
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

var inboxTestResponses: [(UUID, Bool)] = []
func inboxTestRespond(to message: WireMessage, accepted: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
    inboxTestResponses.append((message.id, accepted))
    completion(.success(()))
}

struct InboxTestSend {
    let text: String
    let id: UUID
    let endpoint: NWEndpoint
    let completion: (Result<Void, Error>) -> Void
}
var inboxTestSends: [InboxTestSend] = []
func inboxTestSend(text: String, messageID: UUID, to endpoint: NWEndpoint,
                   completion: @escaping (Result<Void, Error>) -> Void) {
    inboxTestSends.append(InboxTestSend(text: text, id: messageID, endpoint: endpoint, completion: completion))
}
func inboxTestToast(message: String, recipients: String, failures: Int) {}
