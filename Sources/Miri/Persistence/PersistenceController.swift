import Foundation

struct PersistenceConfiguration: Equatable {
    let enabled: Bool
    let layoutStateURL: URL
    let logicalSpaceAutosaveInterval: TimeInterval
    let restoreOnExit: Bool

    init(config: MiriConfig) {
        enabled = config.persistLayout ?? true
        if let statePath = config.statePath, !statePath.isEmpty {
            layoutStateURL = URL(fileURLWithPath: NSString(string: statePath).expandingTildeInPath)
        } else {
            let stateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
                .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local")
                    .appendingPathComponent("state")
            layoutStateURL = stateHome
                .appendingPathComponent("miri", isDirectory: true)
                .appendingPathComponent("layout.json")
        }
        logicalSpaceAutosaveInterval = TimeInterval((config.logicalSpaceAutosaveIntervalMinutes ?? 30) * 60)
        restoreOnExit = config.restoreOnExit ?? true
    }
}

/// Owns persistence file locations, restore documents, timers, and the crash
/// cleanup process. Timers only emit due events; the coordinator supplies a
/// fresh immutable snapshot when it handles that event.
@MainActor
final class PersistenceController {
    private let emit: (PersistenceEvent) -> Void
    private var configuration: PersistenceConfiguration
    private var layoutDebounceTimer: DispatchSourceTimer?
    private var logicalSpaceAutosaveTimer: DispatchSourceTimer?
    private var cleanupWatcher: Process?

    private(set) var layoutSnapshot: PersistentLayoutSnapshot?
    private(set) var needsLayoutRestore = true
    private var logicalSpaceSnapshot: PersistentLogicalSpaceSnapshot?
    private(set) var needsLogicalSpaceRestore = true
    private(set) var pendingLogicalSpaceContexts: [PersistentLogicalSpaceContext] = []

    private let restoreStateURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("miri-\(ProcessInfo.processInfo.processIdentifier).restore.json")

    init(configuration: PersistenceConfiguration, emit: @escaping (PersistenceEvent) -> Void) {
        self.configuration = configuration
        self.emit = emit
        loadRestorationDocuments()
    }

    private var logicalSpaceStateURL: URL {
        configuration.layoutStateURL.deletingLastPathComponent().appendingPathComponent("logical-spaces.json")
    }

    func start() {
        schedulePeriodicLogicalSpaceAutosave()
        if configuration.restoreOnExit {
            startCleanupWatcher()
        }
    }

    func reconfigure(_ next: PersistenceConfiguration) {
        let previous = configuration
        configuration = next
        if previous.logicalSpaceAutosaveInterval != next.logicalSpaceAutosaveInterval
            || previous.enabled != next.enabled
        {
            schedulePeriodicLogicalSpaceAutosave()
        }
        if previous.restoreOnExit != next.restoreOnExit {
            next.restoreOnExit ? startCleanupWatcher() : stopCleanupWatcher(removeRestoreFile: true)
        }
        if previous.layoutStateURL != next.layoutStateURL || previous.enabled != next.enabled {
            loadRestorationDocuments()
        }
        if !next.enabled {
            writeLayout(nil)
            writeLogicalSpaces(nil)
        }
    }

    func stopTimers() {
        layoutDebounceTimer?.cancel()
        layoutDebounceTimer = nil
        logicalSpaceAutosaveTimer?.cancel()
        logicalSpaceAutosaveTimer = nil
    }

    func stopCleanupWatcher(removeRestoreFile: Bool) {
        cleanupWatcher?.terminate()
        cleanupWatcher = nil
        if removeRestoreFile {
            try? FileManager.default.removeItem(at: restoreStateURL)
        }
    }

    func scheduleLayoutAutosave() {
        layoutDebounceTimer?.cancel()
        layoutDebounceTimer = nil
        guard configuration.enabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(300), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self, weak timer] in
            timer?.cancel()
            self?.layoutDebounceTimer = nil
            self?.emit(.autosaveDue(kind: .layout))
        }
        layoutDebounceTimer = timer
        timer.resume()
    }

    func schedulePeriodicLogicalSpaceAutosave() {
        logicalSpaceAutosaveTimer?.cancel()
        logicalSpaceAutosaveTimer = nil
        guard configuration.enabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = max(60, Int(configuration.logicalSpaceAutosaveInterval.rounded()))
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval), leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            self?.emit(.autosaveDue(kind: .logicalSpaces))
        }
        logicalSpaceAutosaveTimer = timer
        timer.resume()
    }

    func writeLayout(_ snapshot: PersistentLayoutSnapshot?) {
        write(snapshot, to: configuration.layoutStateURL, kind: .layout)
    }

    func writeLogicalSpaces(_ snapshot: PersistentLogicalSpaceSnapshot?) {
        write(snapshot, to: logicalSpaceStateURL, kind: .logicalSpaces)
    }

    func writeRestoreSnapshot(_ snapshot: RestoreSnapshot?) {
        guard configuration.restoreOnExit, let snapshot else {
            removeFile(at: restoreStateURL, kind: .exitRestoration)
            return
        }
        write(snapshot, to: restoreStateURL, kind: .exitRestoration, requirePersistenceEnabled: false)
    }

    func removeRestoreSnapshot() {
        try? FileManager.default.removeItem(at: restoreStateURL)
    }

    func finishLayoutRestore() {
        needsLayoutRestore = false
    }

    func takeLogicalSpaceRestoreSnapshot() -> PersistentLogicalSpaceSnapshot? {
        guard needsLogicalSpaceRestore else { return nil }
        needsLogicalSpaceRestore = false
        return logicalSpaceSnapshot
    }

    func replacePendingLogicalSpaceContexts(_ contexts: [PersistentLogicalSpaceContext]) {
        pendingLogicalSpaceContexts = contexts
    }

    func removePendingLogicalSpaceContext(id: Int) {
        pendingLogicalSpaceContexts.removeAll { $0.id == id }
    }

    private func loadRestorationDocuments() {
        needsLayoutRestore = true
        needsLogicalSpaceRestore = true
        pendingLogicalSpaceContexts = []
        guard configuration.enabled else {
            layoutSnapshot = nil
            logicalSpaceSnapshot = nil
            return
        }
        layoutSnapshot = read(PersistentLayoutSnapshot.self, at: configuration.layoutStateURL).flatMap {
            (1...2).contains($0.version) ? $0 : nil
        }
        logicalSpaceSnapshot = read(PersistentLogicalSpaceSnapshot.self, at: logicalSpaceStateURL).flatMap(Self.sanitize)
    }

    private func startCleanupWatcher() {
        guard cleanupWatcher?.isRunning != true, let executableURL = currentExecutableURL() else {
            return
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--cleanup-watch",
            "\(ProcessInfo.processInfo.processIdentifier)",
            restoreStateURL.path,
        ]
        if let null = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = null
            process.standardError = null
        }
        do {
            try process.run()
            cleanupWatcher = process
        } catch {
            fputs("miri: failed to start cleanup watcher: \(error)\n", stderr)
        }
    }

    private func read<Value: Decodable>(_ type: Value.Type, at url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<Value: Encodable>(
        _ value: Value?,
        to url: URL,
        kind: PersistenceEvent.SnapshotKind,
        requirePersistenceEnabled: Bool = true
    ) {
        guard (!requirePersistenceEnabled || configuration.enabled), let value else {
            removeFile(at: url, kind: kind)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: [.atomic])
            emit(.writeCompleted(kind: kind))
        } catch {
            emit(.writeFailed(kind: kind, reason: error.localizedDescription))
        }
    }

    private func removeFile(at url: URL, kind: PersistenceEvent.SnapshotKind) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            emit(.writeCompleted(kind: kind))
        } catch {
            emit(.writeFailed(kind: kind, reason: error.localizedDescription))
        }
    }

    private static func sanitize(_ snapshot: PersistentLogicalSpaceSnapshot) -> PersistentLogicalSpaceSnapshot? {
        var seen = Set<Int>()
        let contexts = snapshot.contexts.filter { $0.id >= 0 && seen.insert($0.id).inserted }
        guard snapshot.version == 1, !contexts.isEmpty else { return nil }
        let maxID = contexts.map(\.id).max() ?? 0
        let activeID = contexts.contains { $0.id == snapshot.activeContextID }
            ? snapshot.activeContextID
            : contexts[0].id
        return PersistentLogicalSpaceSnapshot(
            version: 1,
            activeContextID: activeID,
            nextContextID: max(maxID + 1, snapshot.nextContextID, 0),
            contexts: contexts
        )
    }
}
