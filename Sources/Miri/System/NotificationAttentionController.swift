import AppKit
import ApplicationServices
import Foundation

struct NotificationApplication: Hashable, Sendable {
    let name: String
    let bundleID: String
}

/// A bounded, read-only snapshot of Notification Center's accessibility surface.
/// Message text is used for source attribution and identity, then discarded.
struct NotificationAXNode: @unchecked Sendable {
    let element: AXUIElement
    var role = "AXGroup"
    var subrole = ""
    var identifier = ""
    var text = ""
    var description = ""
    var children: [NotificationAXNode] = []
}

private struct NotificationBannerIdentity: Hashable {
    let element: AXUIElement
    let requestID: String?
    let contentHash: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.contentHash == rhs.contentHash else { return false }
        if let requestID = lhs.requestID { return requestID == rhs.requestID }
        return rhs.requestID == nil && CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(contentHash)
        if let requestID { hasher.combine(requestID) }
        else { hasher.combine(CFHash(element)) }
    }
}

struct NotificationAttentionState {
    private(set) var bundleIDs = Set<String>()
    private var seen = Set<NotificationBannerIdentity>()
    private var primed = false

    /// The first complete scan is a baseline, not a replay of existing banners.
    @discardableResult
    mutating func observe(
        _ nodes: [NotificationAXNode],
        applications: [NotificationApplication],
        focusedBundleIDs: Set<String>
    ) -> Bool {
        var live = Set<NotificationBannerIdentity>()
        let before = bundleIDs

        func normalized(_ name: String) -> String {
            let scalars = name.unicodeScalars.filter { $0.properties.generalCategory != .format }
            return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let sourcesByName = Dictionary(grouping: applications, by: { normalized($0.name) })

        func accept(_ node: NotificationAXNode) -> Bool {
            var fields: [String: [String]] = [:]
            var imageLabels: [String] = []
            func collect(_ child: NotificationAXNode) {
                if child.role == "AXStaticText", !child.text.isEmpty {
                    fields[child.identifier, default: []].append(child.text)
                } else if child.role == "AXImage", !child.description.isEmpty {
                    imageLabels.append(child.description)
                }
                for descendant in child.children { collect(descendant) }
            }
            collect(node)
            let titles = fields["title", default: []]
            let headers = fields["header", default: []]
            let subtitles = fields["subtitle", default: []]
            let bodies = fields["body", default: []]
            let unlabelled = fields["", default: []]
            let message: [String]
            if titles.count == 1, headers.count <= 1, subtitles.count <= 1, bodies.count <= 1 {
                message = titles + subtitles + bodies
            } else if titles.isEmpty, headers.isEmpty, (2...3).contains(unlabelled.count) {
                message = unlabelled
            } else {
                return false
            }

            var labels = headers
            if labels.isEmpty {
                let messageLabels = Set(message.map(normalized))
                labels = imageLabels.filter { !messageLabels.contains(normalized($0)) }
                // The formatted card description places the app before its
                // exact message fields. Do not guess by splitting at commas.
                let description = normalized(node.description)
                let suffix = ", " + normalized(message.joined(separator: ", "))
                for name in sourcesByName.keys where description == name + suffix {
                    labels.append(name)
                }
            }
            let sources = Set(labels.flatMap { sourcesByName[normalized($0), default: []].map(\.bundleID) })
            var hash = Hasher()
            for part in headers + message { hash.combine(part) }
            let requestID = node.identifier.range(
                of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
                options: .regularExpression
            ).map { String(node.identifier[$0]) }
            let identity = NotificationBannerIdentity(element: node.element, requestID: requestID, contentHash: hash.finalize())
            live.insert(identity)
            let arrived = seen.insert(identity).inserted
            if primed, arrived, sources.count == 1, let source = sources.first, !focusedBundleIDs.contains(source) {
                bundleIDs.insert(source)
            }
            return true
        }

        func stack(_ node: NotificationAXNode) {
            if accept(node) { return }
            for child in node.children { stack(child) }
        }

        func walk(_ node: NotificationAXNode) {
            switch node.subrole {
            case "AXNotificationCenterBanner", "AXNotificationCenterAlert":
                _ = accept(node)
            case "AXNotificationCenterBannerStack", "AXNotificationCenterAlertStack":
                stack(node)
            default:
                for child in node.children { walk(child) }
            }
        }
        for node in nodes { walk(node) }
        primed = true
        if seen.count > 512 { seen = live }
        return before != bundleIDs
    }

    @discardableResult
    mutating func focus(_ bundleID: String) -> Bool {
        bundleIDs.remove(bundleID) != nil
    }

    mutating func resetBaseline() {
        seen.removeAll()
        primed = false
    }
}

/// Watches UI changes rather than polling. It never opens, closes or moves a
/// native notification, and retains only app attention and banner identities.
@MainActor
final class NotificationAttentionController {
    private let axOperations: AXOperationController
    private let applications: () -> [NotificationApplication]
    private let emit: (AppEvent) -> Void
    private(set) var state = NotificationAttentionState()
    private var observer: AXObserver?
    private var pid: pid_t?
    private var running = false
    private var generation: UInt64 = 0
    private var pendingScan: DispatchWorkItem?
    private var reading = false
    private var rescan = false
    private var focusedDuringRead = Set<String>()

    init(
        axOperations: AXOperationController,
        applications: @escaping () -> [NotificationApplication],
        emit: @escaping (AppEvent) -> Void
    ) {
        self.axOperations = axOperations
        self.applications = applications
        self.emit = emit
    }

    deinit {
        MainActor.assumeIsolated { detach() }
    }

    func start() {
        running = true
        attach()
    }

    func applicationLifecycleChanged(_ app: NSRunningApplication) {
        if app.bundleIdentifier == "com.apple.notificationcenterui" { attach() }
    }

    func applicationActivated(_ app: NSRunningApplication) {
        // NSWorkspace reports a real activation even if a quick visit has
        // already ended by the time its event reaches the coordinator.
        guard let bundleID = app.bundleIdentifier else { return }
        acknowledgeApplication(bundleID)
    }

    func acknowledgeApplication(_ bundleID: String) {
        if reading { focusedDuringRead.insert(bundleID) }
        if state.focus(bundleID) { emit(.windows(.notificationAttentionChanged)) }
    }

    func acceptSnapshot(_ nodes: [NotificationAXNode], focusedBundleIDs: Set<String>) {
        if state.observe(nodes, applications: applications(), focusedBundleIDs: focusedBundleIDs) {
            emit(.windows(.notificationAttentionChanged))
        }
    }

    private func attach(attempt: Int = 0) {
        guard running else { return }
        let nextPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            .first(where: { !$0.isTerminated })?.processIdentifier
        guard pid != nextPID || (observer == nil && attempt > 0) else { return }
        detach()
        guard let nextPID else { return }
        pid = nextPID
        let requested = generation
        let events = [kAXWindowCreatedNotification, kAXLayoutChangedNotification,
                      kAXUIElementDestroyedNotification, kAXFocusedWindowChangedNotification]
        axOperations.registerObserver(
            pid: nextPID, notifications: events, coalescingKey: "notification-observer",
            callback: notificationAttentionAXCallback, refcon: Unmanaged.passUnretained(self).toOpaque()
        ) { [weak self] result in
            guard let self, self.running, self.generation == requested else { return }
            guard let registration = result.value, registration.notificationErrors.count < events.count else {
                if attempt < 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + (result.retryAfter ?? 1)) { [weak self] in
                        guard let self, self.generation == requested else { return }
                        self.attach(attempt: attempt + 1)
                    }
                }
                return
            }
            self.observer = registration.observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes)
            self.scan()
        }
    }

    func scheduleScan() {
        guard running, observer != nil else { return }
        if reading { rescan = true; return }
        guard pendingScan == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingScan = nil
            self.scan()
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func scan() {
        guard running, observer != nil, !reading, let pid else { return }
        reading = true
        focusedDuringRead.removeAll()
        let requested = generation
        axOperations.readNotificationCenter(pid: pid) { [weak self] result in
            guard let self, self.generation == requested else { return }
            self.reading = false
            if let nodes = result.value {
                var focused = self.focusedDuringRead
                if let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { focused.insert(current) }
                self.acceptSnapshot(nodes, focusedBundleIDs: focused)
            }
            if self.rescan { self.rescan = false; self.scheduleScan() }
        }
    }

    private func detach() {
        generation &+= 1
        pendingScan?.cancel()
        pendingScan = nil
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        pid = nil
        reading = false
        rescan = false
        focusedDuringRead.removeAll()
        state.resetBaseline()
    }

    func stop() {
        running = false
        detach()
        let changed = !state.bundleIDs.isEmpty
        state = NotificationAttentionState()
        if changed { emit(.windows(.notificationAttentionChanged)) }
    }

    fileprivate func notificationChanged() {
        emit(.windows(.notificationCenterChanged))
    }
}

private func notificationAttentionAXCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let controller = Unmanaged<NotificationAttentionController>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { controller.notificationChanged() }
}
