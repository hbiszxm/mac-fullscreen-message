#!/usr/bin/env python3
"""Render anonymous README examples from the production AppKit views.

No window is presented, no service is started, and production preferences are
never opened. Temporary source copies only inject fixture data and a renderer.
Run on macOS: python3 scripts/render-readme-previews.py
"""
from pathlib import Path
import plistlib
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs" / "images"
OUTPUT.mkdir(parents=True, exist_ok=True)

MENU_FIXTURE = r'''
    func readmeMenuView() -> NSView {
        let fixtures = [
            Peer(id: "readme-design", name: "设计组 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1), instanceID: "readme-design"),
            Peer(id: "readme-ops", name: "运营组 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1), instanceID: "readme-ops")
        ]
        peers = fixtures
        selectedPopoverPeerIDs = Set(fixtures.map(\.id))
        lastStatus = "已就绪，等待消息"
        customMessages = []
        menuMessageView.string = "十分钟后开会"
        temporaryChatTranscript.setAttributedString(readmeTranscript())
        rebuildStatusPopover()
        inlineChat.onSend = nil
        inlineChat.onRead = nil
        inlineChat.setUnreadCount(3)
        readmeReveal(inlineChat)
        return statusPopover.contentViewController!.view
    }
'''

RENDERER = r'''
import AppKit

let fixtureDefaults = UserDefaults(suiteName: "cn.local.fullscreen-message.readme.fixtures")!

func readmeTranscript() -> NSAttributedString {
    let value = NSMutableAttributedString(string: "")
    for (sender, text, incoming) in [
        ("设计组 Mac", "方案已经更新，可以一起看一下。", true),
        ("我", "好的，现在看。", false)
    ] {
        value.append(NSAttributedString(string: "\(sender)　", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: incoming ? NSColor.systemBlue : NSColor.systemGreen
        ]))
        value.append(NSAttributedString(string: "\(text)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor
        ]))
    }
    return value
}

func readmeReveal(_ view: NSView) {
    if let privacy = view as? PrivacyChatView { privacy.keyboardActive = true }
    view.subviews.forEach(readmeReveal)
}

// Offscreen windows provide the AppKit layout context; none are ordered front.
var retainedWindows: [NSWindow] = []
func host(_ view: NSView, size: NSSize) {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = view
    window.setContentSize(size)
    view.frame = NSRect(origin: .zero, size: size)
    retainedWindows.append(window)
    view.layoutSubtreeIfNeeded()
}

func capture(_ view: NSView) -> NSImage {
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    let image = NSImage(size: view.bounds.size)
    image.addRepresentation(rep)
    return image
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
}
let ink = color(0.08, 0.14, 0.24)
let secondary = color(0.36, 0.43, 0.54)

func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = ink) {
    (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}

func roundedImage(_ image: NSImage, rect: NSRect, radius: CGFloat = 24, shadow: Bool = true) {
    NSGraphicsContext.saveGraphicsState()
    if shadow {
        let shadow = NSShadow()
        shadow.shadowColor = color(0.23, 0.33, 0.49).withAlphaComponent(0.20)
        shadow.shadowBlurRadius = 34
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    image.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}

func card(_ filename: String, draw: () -> Void) {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1000,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGradient(colors: [color(0.94, 0.96, 0.99), color(0.87, 0.92, 0.98)])!
        .draw(in: NSRect(x: 0, y: 0, width: 1600, height: 1000), angle: -25)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let target = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(filename)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: target)
    print("Rendered \(target.path) (1600 × 1000)")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.appearance = NSAppearance(named: .aqua)
fixtureDefaults.removePersistentDomain(forName: "cn.local.fullscreen-message.readme.fixtures")
let delegate = AppDelegate()
let menu = delegate.readmeMenuView()
host(menu, size: menu.frame.size)
readmeReveal(menu)
let menuImage = capture(menu)

let chat = InlineChatView(frame: NSRect(x: 0, y: 0, width: 358, height: 157))
chat.setRecipients(["设计组 Mac", "运营组 Mac"])
chat.setTranscript(readmeTranscript())
chat.setUnreadCount(3)
host(chat, size: NSSize(width: 358, height: 157))
readmeReveal(chat)
let chatImage = capture(chat)

let logoView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 25))
let logo = NSImageView(frame: NSRect(x: 6, y: 2, width: 27, height: 20))
logo.image = StatusItemLogo.templateImage(unreadCount: 3)
logoView.addSubview(logo)
let badge = StatusUnreadBadgeView(frame: logoView.bounds)
badge.unreadCount = 3
logoView.addSubview(badge)
host(logoView, size: logoView.frame.size)
let logoImage = capture(logoView)

card("menu-chat.png") {
    let scale: CGFloat = 1.14
    let menuSize = NSSize(width: menu.frame.width * scale, height: menu.frame.height * scale)
    let menuRect = NSRect(x: 90, y: (1000 - menuSize.height) / 2 - 4, width: menuSize.width, height: menuSize.height)
    roundedImage(menuImage, rect: menuRect, radius: 22)
    label("菜单栏与临时会话", x: 640, y: 758, size: 44, weight: .semibold)
    label("选择电脑，发送提醒，随手聊两句。", x: 642, y: 700, size: 25, color: secondary)

    let pill = NSRect(x: 642, y: 602, width: 184, height: 58)
    NSColor.white.withAlphaComponent(0.80).setFill()
    NSBezierPath(roundedRect: pill, xRadius: 16, yRadius: 16).fill()
    logoImage.draw(in: NSRect(x: 662, y: 611, width: 64, height: 40))
    label("未读提醒", x: 732, y: 617, size: 19, weight: .medium)

    let detail = NSRect(x: 618, y: 152, width: 890, height: 410)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0.23, 0.33, 0.49).withAlphaComponent(0.13)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
    NSBezierPath(roundedRect: detail, xRadius: 24, yRadius: 24).fill()
    NSGraphicsContext.restoreGraphicsState()
    chatImage.draw(in: NSRect(x: 648, y: 176, width: 830, height: 830 * 157 / 358))
    label("界面示例", x: 644, y: 95, size: 19, color: secondary)
}

let message = WireMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                          sender: "设计组 Mac", text: "开会啦", sentAt: Date(timeIntervalSince1970: 1790215200),
                          kind: "alert", senderInstanceID: "readme-design", relatedMessageID: nil)
let alert = FullScreenAlertController(message: message, responseHandler: { _ in })!
let alertView = alert.window!.contentView!
alert.window!.appearance = NSAppearance(named: .darkAqua)
alertView.layoutSubtreeIfNeeded()
let alertImage = capture(alertView)
card("fullscreen-alert.png") {
    label("全屏提醒", x: 72, y: 919, size: 32, weight: .semibold)
    label("界面示例", x: 1413, y: 927, size: 19, color: secondary)
    roundedImage(alertImage, rect: NSRect(x: 64, y: 62, width: 1472, height: 828), radius: 26)
}
fixtureDefaults.removePersistentDomain(forName: "cn.local.fullscreen-message.readme.fixtures")
'''


with tempfile.TemporaryDirectory(prefix="fullscreen-readme-") as temporary:
    working = Path(temporary)
    app = working / "ReadmePreview.app"
    executable = app / "Contents" / "MacOS" / "ReadmePreview"
    executable.parent.mkdir(parents=True)
    info = plistlib.loads((ROOT / "Resources" / "Info.plist").read_bytes())
    info.update(CFBundleIdentifier="cn.local.fullscreen-message.readme", CFBundleExecutable="ReadmePreview")
    (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))

    sources = []
    for path in sorted((ROOT / "Sources").glob("*.swift")):
        if path.name == "main.swift":
            continue
        source = path.read_text().replace("UserDefaults.standard", "fixtureDefaults")
        if path.name == "AppDelegate.swift":
            source = source.replace("import AppKit", "import AppKit\nimport Network", 1)
            start = source.index("    func applicationDidFinishLaunching(")
            end = source.index("    func applicationWillTerminate(", start)
            source = source[:start] + MENU_FIXTURE + "\n" + source[end:]
            source = source.replace("(statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800", "CGFloat(1000)")
        if path.name == "FullScreenAlert.swift":
            source = source.replace("let screens = NSScreen.screens", "let screens = Array(NSScreen.screens.prefix(1))")
            source = source.replace("contentRect: screen.frame", "contentRect: NSRect(x: 0, y: 0, width: 1440, height: 810)")
            source = source.replace("window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))", "window.level = .normal")
        destination = working / path.name
        destination.write_text(source)
        sources.append(destination)
    main = working / "main.swift"
    main.write_text(RENDERER)
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-O",
        *map(str, sources), str(main), "-o", str(executable),
        "-framework", "AppKit", "-framework", "Network", "-framework", "ServiceManagement",
    ], check=True)
    subprocess.run([str(executable), str(OUTPUT)], check=True, timeout=30)
