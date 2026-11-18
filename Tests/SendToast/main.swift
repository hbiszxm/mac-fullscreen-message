import AppKit

_ = NSApplication.shared
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    for accepted in [true, false] {
        let title = accepted ? "小刘 已收到" : "小刘 已拒绝"
        let card = SendToastView(message: "上班", recipients: "小刘", failures: 0,
                                 titleOverride: title, detailOverride: "全屏消息回执", responseAccepted: accepted)
        card.appearance = NSAppearance(named: appearance)
        card.layoutSubtreeIfNeeded()
        let views = descendants(card)
        let label = views.compactMap { $0 as? NSTextField }.first { $0.stringValue == title }!
        let icon = views.compactMap { $0 as? NSImageView }.first!
        let color: NSColor = accepted ? .systemGreen : .systemRed
        expect(label.textColor == color && icon.contentTintColor == color, "Receipt title and icon must both use the correct color")
        expect(card.frame.height <= 100 && card.frame.height >= 58, "Receipt must retain compact notification layout")
        expect(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "上班" }, "Receipt must show the original message")
    }
}
let failed = SendToastView(message: "上班", recipients: "小刘", failures: 1)
expect(descendants(failed).compactMap { $0 as? NSImageView }.first?.contentTintColor == .systemOrange,
       "Transport failures must remain distinct from an explicit rejection")
print("PASS: alias receipt titles, green acceptance/red rejection, original message, compact light/dark layout and orange transport errors")
