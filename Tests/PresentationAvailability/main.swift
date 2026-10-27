import AppKit

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

// Every combination must remain blocked if any independent condition blocks
// presentation, including a wake/unlock arriving while another blocker remains.
for bits in 0..<32 {
    var state = PresentationAvailabilityState()
    state.sessionIsActive = bits & 1 == 0
    state.sessionIsLocked = bits & 2 != 0
    state.screensAreAwake = bits & 4 == 0
    state.systemIsAwake = bits & 8 == 0
    state.hasScreens = bits & 16 == 0
    expect(state.canPresent == (bits == 0), "Presentation blocker combination \(bits) failed")
}

_ = NSApplication.shared
let availability = PresentationAvailability()
var initialCallbacks = 0
availability.start { _ in
    expect(Thread.isMainThread, "Availability changes must arrive on the main thread")
    initialCallbacks += 1
}
expect(initialCallbacks == 1, "Start must publish initial availability once")
availability.stop()
availability.start { _ in initialCallbacks += 1 }
expect(initialCallbacks == 2, "Restart must publish a fresh snapshot")
availability.stop()

let message = WireMessage(id: UUID(), sender: "测试设备", text: "测试消息", sentAt: Date(),
                          kind: "alert", senderInstanceID: "test", relatedMessageID: nil)

func key(_ code: UInt16, repeating: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: code == 53 ? "\u{1b}" : "\r",
                    charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "\r",
                    isARepeat: repeating, keyCode: code)!
}
for (code, expected) in [(UInt16(36), true), (UInt16(76), true), (UInt16(53), false)] {
    var responses: [Bool] = []
    let alert = FullScreenAlertController(message: message, responseHandler: { responses.append($0) })!
    let window = alert.window!
    expect(!alert.isPresented, "Construction must not present a window")
    expect(window.performKeyEquivalent(with: key(code, repeating: true)), "Repeated response keys must be consumed")
    expect(responses.isEmpty, "Key repeat must not respond")
    expect(window.performKeyEquivalent(with: key(code)), "Response key must be handled")
    window.keyDown(with: key(code))
    window.cancelOperation(nil)
    expect(responses == [expected], "Return/Enter/Escape must respond once with the correct result")
    expect(!alert.present(), "A handled alert must not reappear")
}
for accepted in [true, false] {
    var responses: [Bool] = []
    let alert = FullScreenAlertController(message: message, responseHandler: { responses.append($0) })!
    alert.perform(NSSelectorFromString(accepted ? "acceptMessage" : "rejectMessage"))
    alert.window?.cancelOperation(nil)
    expect(responses == [accepted], "Buttons must use the same exactly-once response path")
}
do {
    var responses: [Bool] = []
    let alert = FullScreenAlertController(message: message, responseHandler: { responses.append($0) })!
    let window = alert.window!
    window.cancelOperation(nil)
    expect(responses == [false], "Cancel operation must reject, not silently dismiss")
}
do {
    var responses: [Bool] = []
    let alert = FullScreenAlertController(message: message, responseHandler: { responses.append($0) })!
    let window = alert.window!
    alert.suspend()
    window.cancelOperation(nil)
    window.keyDown(with: key(36))
    expect(!alert.present() && responses.isEmpty, "Lock/sleep suspension must not accept or reject")
}
print("PASS: presentation gates; Return/Enter accepts; Escape rejects; repeated keys ignored; responses exactly once; suspension sends no response")
