import AppKit
import Darwin
import Foundation

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--cleanup-watch" {
    guard let parentPID = pid_t(CommandLine.arguments[2]), parentPID > 0 else {
        fputs("miri: invalid cleanup watcher parent pid\n", stderr)
        exit(2)
    }
    CleanupWatcher.run(parentPID: parentPID, snapshotPath: CommandLine.arguments[3])
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let miri = Miri()
app.delegate = miri
let statusMenu = StatusMenuController(miri: miri)
_ = statusMenu
miri.start()
app.run()
