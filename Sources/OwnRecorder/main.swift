import AppKit
import Foundation

if CommandLine.arguments.contains("--migrate-records") {
    RecordsMigrator.migrateIfNeeded()
    Thread.sleep(forTimeInterval: 0.3)
    exit(EXIT_SUCCESS)
}

// Entry point for the menu bar daemon.
// NSApplication.run() starts the Cocoa run loop; AppDelegate handles everything else.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
