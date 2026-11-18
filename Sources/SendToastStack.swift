import AppKit

/// FIFO banners share one column; overflow waits until a full five-second slot is free.
final class SendToastStack {
    static let displayDuration: TimeInterval = 5
    private let margin: CGFloat = 24
    private let spacing: CGFloat = 10
    private let screenFrame: () -> NSRect
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let present: (NSPanel) -> Void
    private let animated: Bool
    private var batchFrame: NSRect?
    private var dismissing = Set<ObjectIdentifier>()
    private(set) var visiblePanels: [NSPanel] = []
    private(set) var waitingPanels: [NSPanel] = []

    init(animated: Bool = true,
         screenFrame: @escaping () -> NSRect = {
             (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
         },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         },
         present: @escaping (NSPanel) -> Void = { $0.orderFrontRegardless() }) {
        self.animated = animated
        self.screenFrame = screenFrame
        self.schedule = schedule
        self.present = present
    }

    func show(_ card: SendToastView) {
        if batchFrame == nil { batchFrame = screenFrame() }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: card.frame.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = card
        card.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
        waitingPanels.append(panel)
        fillAvailableSpace()
    }

    private func fillAvailableSpace() {
        guard let frame = batchFrame else { return }
        var bottom = visiblePanels.last?.frame.minY ?? (frame.maxY - margin + spacing)
        while let panel = waitingPanels.first {
            let y = bottom - spacing - panel.frame.height
            guard y >= frame.minY + margin || visiblePanels.isEmpty else { break }
            waitingPanels.removeFirst()
            visiblePanels.append(panel)
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - margin, y: y))
            panel.alphaValue = animated ? 0 : 1
            present(panel)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    panel.animator().alphaValue = 1
                }
            }
            schedule(Self.displayDuration) { [weak self, weak panel] in
                guard let panel else { return }
                self?.dismiss(panel)
            }
            bottom = y
        }
    }

    private func dismiss(_ panel: NSPanel) {
        let id = ObjectIdentifier(panel)
        guard visiblePanels.contains(where: { $0 === panel }), dismissing.insert(id).inserted else { return }
        let finish = { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.orderOut(nil)
            self.visiblePanels.removeAll { $0 === panel }
            self.dismissing.remove(id)
            self.reflow()
            self.fillAvailableSpace()
            if self.visiblePanels.isEmpty && self.waitingPanels.isEmpty { self.batchFrame = nil }
        }
        if animated {
            // Reserve its slot until fade-out ends, so the next banner cannot overlap it.
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: finish)
        } else {
            finish()
        }
    }

    private func reflow() {
        guard let frame = batchFrame else { return }
        var y = frame.maxY - margin
        for panel in visiblePanels {
            y -= panel.frame.height
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - margin, y: y))
            y -= spacing
        }
    }
}
