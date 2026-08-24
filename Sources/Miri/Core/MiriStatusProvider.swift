import AppKit
import Foundation

extension Notification.Name {
    static let miriWorkspaceBarNeedsRefresh = Notification.Name("MiriWorkspaceBarNeedsRefresh")
}

extension Miri {
    func notifyWorkspaceBarNeedsRefresh() {
        NotificationCenter.default.post(name: .miriWorkspaceBarNeedsRefresh, object: self)
    }

    func currentStatusMenuViewState() -> StatusMenuViewState {
        StatusMenuViewState(
            status: currentStatus(),
            workspaceBar: currentWorkspaceBarStatus(),
            config: configStore.effectiveConfig
        )
    }

    func currentWorkspaceBarStatus() -> MiriWorkspaceBarStatus {
        let snapshot = windowManagement.snapshot()
        guard snapshot.workspaces.indices.contains(snapshot.activeWorkspace) else {
            return MiriWorkspaceBarStatus(
                workspace: snapshot.activeWorkspace + 1,
                focusedIndex: nil,
                windows: [],
                workspaceSummaries: [],
                fullscreenWindows: fullscreenWorkspaceBarWindows()
            )
        }

        let workspace = snapshot.workspaces[snapshot.activeWorkspace]
        return MiriWorkspaceBarStatus(
            workspace: snapshot.activeWorkspace + 1,
            focusedIndex: workspace.columns.isEmpty ? nil : workspace.activeColumn,
            windows: workspace.columns.map(workspaceBarWindow),
            workspaceSummaries: workspaceSummaries(snapshot: snapshot),
            fullscreenWindows: fullscreenWorkspaceBarWindows()
        )
    }

    func workspaceSummaries() -> [MiriWorkspaceSummary] {
        workspaceSummaries(snapshot: windowManagement.snapshot())
    }

    func workspaceSummaries(snapshot: WorkspaceModelSnapshot) -> [MiriWorkspaceSummary] {
        snapshot.workspaces.enumerated().map { index, workspace in
            let focusedWindow: MiriWorkspaceBarWindow?
            if workspace.columns.isEmpty {
                focusedWindow = nil
            } else {
                let focusedIndex = min(max(workspace.activeColumn, 0), workspace.columns.count - 1)
                focusedWindow = workspaceBarWindow(workspace.columns[focusedIndex])
            }
            let appNames = Array(NSOrderedSet(array: workspace.columns.map(\.appName))) as? [String] ?? workspace.columns.map(\.appName)
            return MiriWorkspaceSummary(
                workspace: index + 1,
                isActive: index == snapshot.activeWorkspace,
                lastFocusedWindow: focusedWindow,
                appNames: appNames
            )
        }
    }

    func workspaceBarWindow(_ window: ManagedWindow) -> MiriWorkspaceBarWindow {
        MiriWorkspaceBarWindow(bundleID: window.bundleID, appName: window.appName, title: window.title)
    }

    func fullscreenWorkspaceBarWindows() -> [MiriWorkspaceBarFullscreenWindow] {
        windowManagement.fullscreenWindowStates.values
            .sorted {
                if $0.workspace != $1.workspace {
                    return $0.workspace < $1.workspace
                }
                if $0.column != $1.column {
                    return $0.column < $1.column
                }
                if $0.appName != $1.appName {
                    return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .map { state in
                MiriWorkspaceBarFullscreenWindow(
                    workspace: state.workspace + 1,
                    window: MiriWorkspaceBarWindow(
                        bundleID: state.bundleID,
                        appName: state.appName,
                        title: state.title
                    )
                )
            }
    }

    func currentStatus() -> MiriStatus {
        let snapshot = windowManagement.snapshot()
        let workspaceCount = max(1, snapshot.workspaces.count)
        guard snapshot.workspaces.indices.contains(snapshot.activeWorkspace) else {
            return MiriStatus(
                workspace: snapshot.activeWorkspace + 1,
                workspaceCount: workspaceCount,
                focusedWindow: "None",
                widthPercent: nil
            )
        }
        let workspace = snapshot.workspaces[snapshot.activeWorkspace]
        guard workspace.columns.indices.contains(workspace.activeColumn) else {
            return MiriStatus(
                workspace: snapshot.activeWorkspace + 1,
                workspaceCount: workspaceCount,
                focusedWindow: "None",
                widthPercent: nil
            )
        }
        let window = workspace.columns[workspace.activeColumn]

        let title = window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)"
        return MiriStatus(
            workspace: snapshot.activeWorkspace + 1,
            workspaceCount: workspaceCount,
            focusedWindow: title,
            widthPercent: Int((widthRatio(for: window) * 100).rounded())
        )
    }

    func openConfigFromMenuImplementation() {
        NSWorkspace.shared.open(configStore.destinationURL)
    }

    func reloadFromMenuImplementation() {
        _ = reloadConfigIfNeeded(force: true, reportFailure: true)
    }

    @MainActor func showSettingsFromMenuImplementation() {
        let apps = availableRuleApps()
        if let settingsWindowController {
            settingsWindowController.refresh(config: configStore.documentConfig, availableApps: apps)
            settingsWindowController.showWindow(nil)
            settingsWindowController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = SettingsWindowController(
            config: configStore.documentConfig,
            availableApps: apps,
            actionSink: { [weak self] action in self?.enqueue(.ui(action)) }
        )
        settingsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func saveConfigFromSettingsImplementation(
        _ updatedConfig: MiriConfig,
        closeOnSuccess: Bool
    ) {
        switch configStore.save(updatedConfig) {
        case .saved(let destination):
            applyConfigChange(source: destination)
            enqueue(.config(.saved(destination: destination)))
            settingsWindowController?.presentSaveSuccess(closeOnSuccess: closeOnSuccess)
        case .failed(let reason):
            enqueue(.config(.saveFailed(reason: reason)))
            settingsWindowController?.presentSaveFailure(reason: reason)
        }
    }

    func availableRuleApps() -> [RuleAppInfo] {
        let windowApps = (tiledWindows() + windowManagement.floatingWindows).compactMap { window -> RuleAppInfo? in
            guard let bundleID = window.bundleID, !bundleID.isEmpty else {
                return nil
            }
            return RuleAppInfo(bundleID: bundleID, appName: window.appName)
        }

        let fallbackRunningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RuleAppInfo? in
                guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else {
                    return nil
                }
                return RuleAppInfo(bundleID: bundleID, appName: app.localizedName ?? bundleID)
            }

        let apps = windowApps.isEmpty ? fallbackRunningApps : windowApps
        var seen = Set<String>()
        return apps.filter { seen.insert($0.bundleID).inserted }.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    func scheduleReconciliationTimer() {
        windowManagement.observation.configurePeriodicTimer(
            enabled: sessionController.isLayoutTrackingAllowed,
            interval: windowReconciliationInterval
        )
    }

    @discardableResult
    func reloadConfigIfNeeded(force: Bool = false, reportFailure: Bool = false) -> Bool {
        switch configStore.reloadCurrentSource(force: force) {
        case .unchanged:
            return false
        case .failed(let reason):
            fputs("miri: config reload failed; keeping previous config: \(reason)\n", stderr)
            enqueue(.config(.reloadFailed(reason: reason)))
            if reportFailure {
                MainActor.assumeIsolated {
                    let alert = NSAlert()
                    alert.messageText = "Could not reload Miri config"
                    alert.informativeText = reason
                    alert.runModal()
                }
            }
            return false
        case .reloaded(let source):
            applyConfigChange(source: source)
            enqueue(.config(.loaded(source: source)))
            return true
        }
    }

    private func applyConfigChange(source: URL) {
        // Reconfiguration order is deliberate: capacity first, then input,
        // persistence policy/timers, reconciliation timers, and finally model
        // discovery plus layout projection.
        reconcileWorkspaceCapacity()
        inputController.configure(configStore.effectiveConfig)
        inputController.install(backend: keyboardShortcutBackend)
        persistenceController.reconfigure(PersistenceConfiguration(config: configStore.effectiveConfig))
        scheduleReconciliationTimer()
        syncActiveRescanTimer()
        print("miri: reloaded config \(source.path), \(inputController.commandCount) keybindings")
        requestReconciliation(
            .all(adoptFocused: false, source: .userInterface, reason: "config-changed")
        )
        projectLayout(focusActiveWindow: false)
    }

}
