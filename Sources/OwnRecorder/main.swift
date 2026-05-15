import AppKit

// Entry point for the menu bar daemon.
// NSApplication.run() starts the Cocoa run loop; AppDelegate handles everything else.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
