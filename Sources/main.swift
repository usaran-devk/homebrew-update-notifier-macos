import AppKit
import Combine

/// Entry point for the Homebrew Update Notifier application.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
