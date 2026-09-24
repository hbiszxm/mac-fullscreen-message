import AppKit

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
defer { inboxTestDefaults.removePersistentDomain(forName: inboxTestSuiteName) }
inboxExpect(Thread.isMainThread, "Run inbox integration checks on the main thread")
let delegate = AppDelegate()
delegate.runInboxStateTests()
