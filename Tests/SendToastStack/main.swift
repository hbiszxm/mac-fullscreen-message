import AppKit

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
func expect(_ value: @autoclosure () -> Bool, _ reason: String) { precondition(value(), reason) }
func card(_ name: String, accepted: Bool = true, message: String = "") -> SendToastView {
    SendToastView(message: message, recipients: name, failures: 0,
                  titleOverride: name, detailOverride: "全屏消息回执", responseAccepted: accepted)
}
var callbacks: [() -> Void] = []
var delays: [TimeInterval] = []
var presented: [NSPanel] = []
let frame = NSRect(x: 100, y: 200, width: 1200, height: 800)
let stack = SendToastStack(animated: false, screenFrame: { frame }, schedule: { delay, callback in
    delays.append(delay); callbacks.append(callback)
}, present: { presented.append($0) })
stack.show(card("小刘 已收到"))
stack.show(card("小王 已拒绝", accepted: false))
stack.show(card("小张 已收到", message: "不同高度的消息\n第二行内容"))
expect(stack.visiblePanels.count == 3 && presented.count == 3, "Every response must remain visible")
expect(delays == [5, 5, 5], "Each banner gets its own five-second timer")
func checkFrames(_ panels: [NSPanel], in frame: NSRect) {
    for (index, panel) in panels.enumerated() {
        expect(frame.contains(panel.frame), "Every banner must fit on the chosen screen")
        expect(panel.frame.maxX == frame.maxX - 24, "One right-aligned column")
        if index > 0 {
            expect(panels[index - 1].frame.minY - panel.frame.maxY == 10, "Distinct heights must retain a ten-point gap")
        }
    }
}
checkFrames(stack.visiblePanels, in: frame)
let first = stack.visiblePanels[0], third = stack.visiblePanels[2]
callbacks[1]()
expect(stack.visiblePanels.count == 2 && stack.visiblePanels[0] === first && stack.visiblePanels[1] === third, "Expiry removes only its own response")
checkFrames(stack.visiblePanels, in: frame)
callbacks[0](); callbacks[2]()
expect(stack.visiblePanels.isEmpty, "All responses disappear after their own timers")

var queuedCallbacks: [() -> Void] = []
let smallFrame = NSRect(x: -1200, y: 0, width: 1000, height: 185)
let queue = SendToastStack(animated: false, screenFrame: { smallFrame }, schedule: { delay, callback in
    expect(delay == 5, "Queued banners must get the full display duration")
    queuedCallbacks.append(callback)
}, present: { _ in })
for i in 0..<5 { queue.show(card("设备 \(i)")) }
expect(queue.visiblePanels.count == 2 && queue.waitingPanels.count == 3, "Overflow must queue instead of overlapping or leaving the screen")
expect(queuedCallbacks.count == 2, "Waiting time must not consume display duration")
let next = queue.waitingPanels.first!
queuedCallbacks[0]()
expect(queue.visiblePanels.last === next && queue.waitingPanels.count == 2, "Overflow must enter in arrival order")
expect(queuedCallbacks.count == 3, "Timer starts when the queued banner is presented")
checkFrames(queue.visiblePanels, in: smallFrame)
var index = 1
while index < queuedCallbacks.count { queuedCallbacks[index](); index += 1 }
expect(queue.visiblePanels.isEmpty && queue.waitingPanels.isEmpty, "Burst must fully drain without losing a response")
print("PASS: five-second independent expiry, ordered non-overlapping variable-height column, reflow, and overflow FIFO with fresh timers")
