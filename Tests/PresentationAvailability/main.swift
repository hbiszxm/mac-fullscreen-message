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
var responses: [Bool] = []
var dismissals = 0
if let alert = FullScreenAlertController(message: message, responseHandler: { responses.append($0) },
                                        dismissHandler: { dismissals += 1 }) {
    expect(!alert.isPresented, "Constructing a controller must not present it")
    alert.perform(NSSelectorFromString("acceptMessage"))
    alert.perform(NSSelectorFromString("rejectMessage"))
    alert.perform(NSSelectorFromString("dismiss"))
    expect(responses == [true], "A response must be delivered only once")
    expect(dismissals == 0, "A response must not also invoke the Escape callback")
}
if let alert = FullScreenAlertController(message: message, responseHandler: { responses.append($0) },
                                        dismissHandler: { dismissals += 1 }) {
    alert.perform(NSSelectorFromString("dismiss"))
    alert.perform(NSSelectorFromString("dismiss"))
    alert.perform(NSSelectorFromString("acceptMessage"))
    expect(dismissals == 1 && responses == [true], "Escape must mark read once without responding")
}
if let alert = FullScreenAlertController(message: message, responseHandler: { responses.append($0) },
                                        dismissHandler: { dismissals += 1 }) {
    alert.suspend()
    alert.perform(NSSelectorFromString("dismiss"))
    alert.perform(NSSelectorFromString("acceptMessage"))
    expect(!alert.present(), "Suspended controllers must not present stale windows again")
    expect(dismissals == 1 && responses == [true], "Suspension must retain the unread message without any response")
}

print("展示条件：锁屏、非活动会话、屏幕/系统休眠、无屏幕组合均通过；响应、ESC、挂起回调一次性验证通过（未展示窗口或锁屏）")
