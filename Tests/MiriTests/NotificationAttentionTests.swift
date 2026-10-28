import AppKit
import ApplicationServices
import XCTest
@testable import miri

final class NotificationAttentionTests: XCTestCase {
    private let apps = [NotificationApplication(name: "Chat", bundleID: "test.chat"),
                        NotificationApplication(name: "Mail", bundleID: "test.mail")]

    func testFocusAcknowledgesArrivalsWithoutReplayingVisibleBanners() {
        var state = NotificationAttentionState()
        let existing = banner(app: "Chat"), next = banner(app: "Chat")
        XCTAssertFalse(state.observe([existing], applications: apps, focusedBundleIDs: []))
        XCTAssertTrue(state.bundleIDs.isEmpty)
        XCTAssertTrue(state.observe([existing, next], applications: apps, focusedBundleIDs: []))
        XCTAssertEqual(state.bundleIDs, ["test.chat"])
        XCTAssertTrue(state.focus("test.chat"))
        XCTAssertFalse(state.observe([existing, next], applications: apps, focusedBundleIDs: []))
        XCTAssertTrue(state.bundleIDs.isEmpty)
        XCTAssertTrue(state.observe([banner(app: "Chat")], applications: apps, focusedBundleIDs: []))
        XCTAssertEqual(state.bundleIDs, ["test.chat"])
    }

    func testForegroundAndAppsAcknowledgedDuringReadStayClear() {
        var state = NotificationAttentionState()
        state.observe([], applications: apps, focusedBundleIDs: [])
        let chat = banner(app: "Chat"), mail = banner(app: "Mail")
        state.observe([chat, mail], applications: apps, focusedBundleIDs: ["test.chat"])
        XCTAssertEqual(state.bundleIDs, ["test.mail"])
        state.observe([chat, mail], applications: apps, focusedBundleIDs: [])
        XCTAssertEqual(state.bundleIDs, ["test.mail"], "Leaving the foreground does not make an old banner new")
        state.focus("test.mail")
        state.observe([banner(app: "Chat"), banner(app: "Mail")], applications: apps, focusedBundleIDs: ["test.chat", "test.mail"])
        XCTAssertTrue(state.bundleIDs.isEmpty, "A late read must not recreate already acknowledged attention")
    }

    func testStackedNotificationCardsKeepAppsIndependentAndSurviveExpiry() {
        var state = NotificationAttentionState()
        state.observe([], applications: apps, focusedBundleIDs: [])
        let stack = NotificationAXNode(element: AXUIElementCreateApplication(90),
                                       subrole: "AXNotificationCenterBannerStack",
                                       children: [banner(app: "Chat"), banner(app: "Mail")])
        state.observe([stack], applications: apps, focusedBundleIDs: [])
        XCTAssertEqual(state.bundleIDs, ["test.chat", "test.mail"])
        state.focus("test.chat")
        state.observe([], applications: apps, focusedBundleIDs: [])
        XCTAssertEqual(state.bundleIDs, ["test.mail"], "Native banner expiry does not acknowledge the other app")
        state.resetBaseline()
        state.observe([banner(app: "Chat")], applications: apps, focusedBundleIDs: [])
        XCTAssertEqual(state.bundleIDs, ["test.mail"], "Reattaching establishes a baseline but keeps pending attention")
    }

    func testReconstructedNativeCardsDoNotRelightAcknowledgedAttention() {
        var state = NotificationAttentionState()
        state.observe([], applications: apps, focusedBundleIDs: [])
        let request = UUID().uuidString
        var original = banner(app: "Chat", id: request)
        state.observe([original], applications: apps, focusedBundleIDs: [])
        state.focus("test.chat")
        let rebuilt = banner(app: "Chat", id: request, pid: 2001)
        state.observe([rebuilt], applications: apps, focusedBundleIDs: [])
        XCTAssertTrue(state.bundleIDs.isEmpty)
        original.children[2].text = "A different message"
        state.observe([original], applications: apps, focusedBundleIDs: [])
        XCTAssertEqual(state.bundleIDs, ["test.chat"])
    }

    func testSourceAttributionUsesExactLabelsAndRejectsAmbiguityAndWidgets() {
        var state = NotificationAttentionState()
        let commaApp = NotificationApplication(name: "Chat, Inc.", bundleID: "test.comma")
        let sources = apps + [commaApp]
        state.observe([], applications: sources, focusedBundleIDs: [])
        var formatted = banner(app: "Chat, Inc.")
        formatted.children.removeFirst()
        formatted.description = "Chat, Inc., Sender, Hello"
        state.observe([formatted], applications: sources, focusedBundleIDs: [])
        XCTAssertEqual(state.bundleIDs, ["test.comma"])

        var image = banner(app: "Chat")
        image.children[0] = NotificationAXNode(element: AXUIElementCreateApplication(91), role: "AXImage", description: "\u{200E}Chat")
        state.observe([image], applications: sources, focusedBundleIDs: [])
        XCTAssertEqual(state.bundleIDs, ["test.comma", "test.chat"])

        state.focus("test.chat")
        state.observe([banner(app: "Chat")], applications: sources + [NotificationApplication(name: "Chat", bundleID: "other.chat")], focusedBundleIDs: [])
        var widget = banner(app: "Mail")
        widget.subrole = ""
        state.observe([widget, banner(app: "Cha")], applications: sources, focusedBundleIDs: [])
        XCTAssertEqual(state.bundleIDs, ["test.comma"])
    }

    @MainActor
    func testWorkspaceAttentionIncludesHiddenColumnsSharedAppsAndFullscreenWindows() throws {
        let miri = Miri()
        miri.windowManagement.ensureWorkspaceExists(2)
        let first = miri.windowManagement.workspaces[0]
        let second = miri.windowManagement.workspaces[1]
        let third = miri.windowManagement.workspaces[2]
        let chat = window(app: "Chat", bundleID: "test.chat", pid: 1001)
        let mail = window(app: "Mail", bundleID: "test.mail", pid: 1002)
        first.columns = [Column(windows: [window(app: "Other", bundleID: "test.other", pid: 1003)]),
                         Column(windows: [chat, mail])]
        first.activeColumn = 0
        second.columns = [Column(windows: [window(app: "Chat", bundleID: "test.chat", pid: 1004)])]
        third.columns = []
        let fullscreen = window(app: "Mail", bundleID: "test.mail", pid: 1005)
        miri.windowManagement.rememberFullscreenOSState(FullscreenOSWindowState(
            identity: PersistentWindowIdentity(bundleID: fullscreen.bundleID, appName: fullscreen.appName, title: fullscreen.title), element: fullscreen.element,
            pid: fullscreen.pid, windowID: 55, bundleID: fullscreen.bundleID, appName: fullscreen.appName,
            title: fullscreen.title, workspace: 2, column: 0, leftNeighborID: nil, rightNeighborID: nil,
            leftNeighbor: nil, rightNeighbor: nil, widthRatio: 0.5, wasActive: false
        ))
        let attention = miri.notificationAttentionController
        attention.acceptSnapshot([], focusedBundleIDs: [])
        attention.acceptSnapshot([banner(app: "Chat"), banner(app: "Mail")], focusedBundleIDs: [])
        var status = miri.currentWorkspaceBarStatus()
        XCTAssertEqual(status.workspaceSummaries.map(\.needsAttention), [true, true, true])
        XCTAssertEqual(status.columns[0].map(\.needsAttention), [false])
        XCTAssertEqual(status.columns[1].map(\.needsAttention), [true, true])
        XCTAssertTrue(try XCTUnwrap(status.fullscreenWindows.first).window.needsAttention)

        attention.acknowledgeApplication("test.chat")
        status = miri.currentWorkspaceBarStatus()
        XCTAssertEqual(status.workspaceSummaries.map(\.needsAttention), [true, false, true])
        XCTAssertEqual(status.columns[1].map(\.needsAttention), [false, true])
        attention.acknowledgeApplication("test.mail")
        XCTAssertEqual(miri.currentWorkspaceBarStatus().workspaceSummaries.map(\.needsAttention), [false, false, false])
        attention.acceptSnapshot([banner(app: "Chat")], focusedBundleIDs: [])
        attention.stop()
        XCTAssertEqual(miri.currentWorkspaceBarStatus().workspaceSummaries.map(\.needsAttention), [false, false, false])
    }

    @MainActor
    func testRendererKeepsUnderlinesInsideOutlinesAndMatchesTextAppearanceWithoutResizing() throws {
        _ = NSApplication.shared
        func makeStatus(chatAttention: Bool, mailAttention: Bool) -> MiriWorkspaceBarStatus {
            let chat = MiriWorkspaceBarWindow(bundleID: nil, appName: "Chat", title: "Chat", needsAttention: chatAttention)
            let mail = MiriWorkspaceBarWindow(bundleID: nil, appName: "Mail", title: "Mail", needsAttention: mailAttention)
            return MiriWorkspaceBarStatus(
                workspace: 1, focusedIndex: nil, columns: [[chat, mail]],
                workspaceSummaries: [
                    MiriWorkspaceSummary(workspace: 1, isActive: true, isWorkspaceFullscreen: false,
                                         lastFocusedWindow: chat, appNames: ["Chat", "Mail"], lastFocusedColumn: [chat, mail], needsAttention: chatAttention || mailAttention),
                    MiriWorkspaceSummary(workspace: 2, isActive: false, isWorkspaceFullscreen: false,
                                         lastFocusedWindow: mail, appNames: ["Mail"], lastFocusedColumn: [mail], needsAttention: mailAttention),
                ], fullscreenWindows: []
            )
        }
        var status = makeStatus(chatAttention: true, mailAttention: true)
        var config = MiriConfig.fallback
        let controller = StatusMenuController(stateProvider: {
            StatusMenuViewState(status: MiriStatus(workspace: 1, workspaceCount: 2, focusedWindow: "Chat", widthPercent: nil),
                                workspaceBar: status, config: config,
                                permissions: MiriPermissionStatus(accessibility: .granted, screenRecording: .missing), onboardingActive: false)
        }, actionSink: { _ in })
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            for outset in [0, 5] {
                config.workspaceBarActiveStyle = outset == 0 ? .filledPointer : .outline
                config.workspaceBarCenterStyle = outset == 0 ? .border : .filledBorder
                config.workspaceBarCenterBorderOutset = outset
                config.workspaceBarCenterBorderThickness = 1
                status = makeStatus(chatAttention: true, mailAttention: true)
                let pending = controller.drawWorkspaceBar(status, config: config, appearance: appearance)
                status = makeStatus(chatAttention: true, mailAttention: false)
                let remaining = controller.drawWorkspaceBar(status, config: config, appearance: appearance)
                status = makeStatus(chatAttention: false, mailAttention: false)
                let clear = controller.drawWorkspaceBar(status, config: config, appearance: appearance)
                XCTAssertEqual(try underlineCount(pending, comparedTo: clear, appearance: appearance), 4,
                               "Two workspace numbers, one stacked column, one inactive column")
                XCTAssertEqual(try underlineCount(remaining, comparedTo: clear, appearance: appearance), 2)
                XCTAssertEqual(try underlineCount(clear, comparedTo: clear, appearance: appearance), 0)
                XCTAssertEqual(clear.size, remaining.size, "Attention must not resize or vertically shift the bar")
                XCTAssertEqual(clear.size, pending.size)
            }
        }
    }

    @MainActor
    private func underlineCount(_ image: NSImage, comparedTo clear: NSImage, appearance: NSAppearance) throws -> Int {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let baseline = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(clear.tiffRepresentation)))
        var labelColor: NSColor?
        appearance.performAsCurrentDrawingAppearance { labelColor = NSColor.labelColor.usingColorSpace(.deviceRGB) }
        let foreground = try XCTUnwrap(labelColor)
        var changedRows: [Int: [Int]] = [:]
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let background = try XCTUnwrap(baseline.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let difference = abs(color.alphaComponent - background.alphaComponent)
                    + abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if difference > 0.05 {
                    changedRows[x, default: []].append(y)
                    let bottom = CGFloat(bitmap.pixelsHigh - y - 1) * image.size.height / CGFloat(bitmap.pixelsHigh)
                    XCTAssertGreaterThan(bottom, 2, "Underlines must sit inside the outlines with a gap above their bottom borders")
                }
            }
        }
        let columns = changedRows.keys.sorted()
        let starts = columns.filter { changedRows[$0 - 1] == nil }
        for start in starts {
            var end = start
            while changedRows[end + 1] != nil { end += 1 }
            let middle = (start + end) / 2
            var bestColorError = CGFloat.infinity
            for y in changedRows[middle, default: []] {
                let color = try XCTUnwrap(bitmap.colorAt(x: middle, y: y)?.usingColorSpace(.deviceRGB))
                let background = try XCTUnwrap(baseline.colorAt(x: middle, y: y)?.usingColorSpace(.deviceRGB))
                // The adaptive label color can be translucent over a filled outline.
                let alpha = foreground.alphaComponent + background.alphaComponent * (1 - foreground.alphaComponent)
                func composite(_ front: CGFloat, _ back: CGFloat) -> CGFloat {
                    (front * foreground.alphaComponent + back * background.alphaComponent * (1 - foreground.alphaComponent)) / alpha
                }
                let error = abs(color.redComponent - composite(foreground.redComponent, background.redComponent))
                    + abs(color.greenComponent - composite(foreground.greenComponent, background.greenComponent))
                    + abs(color.blueComponent - composite(foreground.blueComponent, background.blueComponent))
                    + abs(color.alphaComponent - alpha)
                bestColorError = min(bestColorError, error)
            }
            XCTAssertLessThan(bestColorError, 0.03, "Each underline must use the same adaptive color as workspace text")
        }
        return starts.count
    }

    private func banner(app: String, id: String = UUID().uuidString, pid: pid_t = 2000) -> NotificationAXNode {
        let root = AXUIElementCreateApplication(pid)
        return NotificationAXNode(element: root, subrole: "AXNotificationCenterBanner", identifier: "request.\(id)", children: [
            NotificationAXNode(element: root, role: "AXStaticText", identifier: "header", text: app),
            NotificationAXNode(element: root, role: "AXStaticText", identifier: "title", text: "Sender"),
            NotificationAXNode(element: root, role: "AXStaticText", identifier: "body", text: "Hello"),
        ])
    }

    @MainActor private func window(app: String, bundleID: String, pid: pid_t) -> ManagedWindow {
        ManagedWindow(element: AXUIElementCreateApplication(pid), pid: pid, windowID: nil,
                      bundleID: bundleID, appName: app, title: app)
    }
}
