import AppKit
import Darwin
import Foundation

let axTimeoutError = configureAXMessagingTimeout()
if axTimeoutError != .success {
    fputs("miri: failed to configure Accessibility messaging timeout (error \(axTimeoutError.rawValue))\n", stderr)
}

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
let statusMenu = StatusMenuController(
    stateProvider: { [weak miri] in
        miri?.currentStatusMenuViewState() ?? StatusMenuViewState(
            status: MiriStatus(workspace: 1, workspaceCount: 1, focusedWindow: "None", widthPercent: nil),
            workspaceBar: MiriWorkspaceBarStatus(
                workspace: 1,
                focusedIndex: nil,
                windows: [],
                workspaceSummaries: [],
                fullscreenWindows: []
            ),
            config: .fallback,
            permissions: MiriPermissionStatus(accessibility: .missing, screenRecording: .missing),
            onboardingActive: false
        )
    },
    actionSink: { [weak miri] action in miri?.enqueue(.ui(action)) }
)
_ = statusMenu
miri.start()
app.run()
