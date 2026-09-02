import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func saveActiveLogicalSpaceContext() {
        windowManagement.saveActiveContext(signature: currentLogicalSpaceSignature())
    }

    func loadLogicalSpaceContext(_ context: LogicalSpaceContext) {
        windowManagement.activateContext(context)
        layoutController.resetTracking()
        reconcileWorkspaceCapacity()
    }

    func currentLogicalSpaceSignature() -> Set<UInt32> {
        Set(allWindows().compactMap(\.windowID))
    }

    func discoveredSignature(_ discovered: [ManagedWindow]) -> Set<UInt32> {
        Set(discovered.compactMap(\.windowID))
    }

    func handlePendingLogicalSpaceSwitch(discovered: [ManagedWindow]) -> Bool {
        guard windowManagement.consumePendingLogicalSpaceSwitch() else { return false }

        let visibleSignature = discoveredSignature(discovered)
        let bufferedVisibleIDs = visibleSignature.intersection(Set(windowManagement.spaceBufferedWindows.keys))
        let context = bestLogicalSpaceContext(for: visibleSignature, bufferedVisibleIDs: bufferedVisibleIDs, discovered: discovered)
        loadLogicalSpaceContext(context)
        debugLog(
            "logical macOS space activated id=\(context.id) visible=\(visibleSignature.count) buffered=\(bufferedVisibleIDs.count) known=\(context.signature.count)"
        )
        return true
    }

    func bestLogicalSpaceContext(
        for visibleSignature: Set<UInt32>,
        bufferedVisibleIDs: Set<UInt32>,
        discovered: [ManagedWindow]
    ) -> LogicalSpaceContext {
        if visibleSignature.isEmpty,
           let empty = windowManagement.logicalSpaceContexts.first(where: {
               $0.signature.isEmpty && $0.id != windowManagement.activeLogicalSpaceContextID
           })
        {
            return empty
        }

        let anchorSignature = visibleSignature.subtracting(bufferedVisibleIDs)
        if let match = bestLogicalSpaceContextMatching(anchorSignature) {
            return match
        }
        if bufferedVisibleIDs.isEmpty, let match = bestLogicalSpaceContextMatching(visibleSignature) {
            return match
        }
        if let promoted = promotePendingPersistentLogicalSpaceContext(for: visibleSignature, discovered: discovered) {
            return promoted
        }

        let context = windowManagement.makeContext(signature: visibleSignature)
        debugLog(
            "logical macOS space created id=\(context.id) visible=\(visibleSignature.count) buffered=\(bufferedVisibleIDs.count)"
        )
        return context
    }

    func bestLogicalSpaceContextMatching(_ signature: Set<UInt32>) -> LogicalSpaceContext? {
        guard !signature.isEmpty else {
            return nil
        }
        var best: (context: LogicalSpaceContext, score: Int)?
        for context in windowManagement.logicalSpaceContexts {
            let score = context.signature.intersection(signature).count
            if score > 0, best == nil || score > best!.score {
                best = (context, score)
            }
        }
        return best?.context
    }

    func likelyFullscreenExitSettle(discovered: [ManagedWindow]) -> Bool {
        guard discoveredSignature(discovered).isEmpty,
              !windowManagement.fullscreenWindowStates.isEmpty
        else {
            return false
        }
        let now = CFAbsoluteTimeGetCurrent()
        return fullscreenSpaceChangeGuardIsActive() || now < fullscreenTransitionGuardUntil
    }

    func likelyBulkTransientDisappearance(discovered: [ManagedWindow]) -> Bool {
        let existing = allWindows().filter { $0.windowID != nil }
        guard existing.count >= 3 else {
            return false
        }
        let discoveredIDs = discoveredSignature(discovered)
        let missing = existing.filter { window in
            guard let windowID = window.windowID else {
                return false
            }
            return !discoveredIDs.contains(windowID)
        }
        guard missing.count >= 3 || Double(missing.count) / Double(existing.count) >= 0.5 else {
            return false
        }
        let transientMissing = missing.filter { window in
            guard let windowID = window.windowID,
                  let runningApp = NSRunningApplication(processIdentifier: window.pid)
            else {
                return false
            }
            return !runningApp.isHidden
                && !window.isMinimized
                && cgWindowExists(windowID)
                && !cgWindowIsOnScreen(windowID)
        }
        return transientMissing.count == missing.count
    }

    func bufferWindowInUnknownSpaceIfNeeded(_ window: ManagedWindow) -> Bool {
        guard windowAppearsInUnknownSpace(window), let windowID = window.windowID else { return false }

        windowManagement.buffer(BufferedSpaceWindow(
            window: window,
            sourceContextID: windowManagement.activeLogicalSpaceContextID
        ), windowID: windowID)
        debugLog(
            "buffering window in unknown macOS space app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' title='\(window.title)' id=\(windowID) sourceContext=\(windowManagement.activeLogicalSpaceContextID)"
        )
        removeWindow(window, preferRightFocus: true)
        return true
    }

    func windowAppearsInUnknownSpace(_ window: ManagedWindow) -> Bool {
        guard let windowID = window.windowID,
              let runningApp = NSRunningApplication(processIdentifier: window.pid)
        else { return false }
        return !runningApp.isHidden
            && !window.isMinimized
            && cgWindowExists(windowID)
            && !cgWindowIsOnScreen(windowID)
    }

    func consumeBufferedWindowIfNeeded(_ window: ManagedWindow) {
        guard let windowID = window.windowID,
              let buffered = windowManagement.takeBufferedWindow(windowID: windowID)
        else {
            return
        }
        if buffered.sourceContextID != windowManagement.activeLogicalSpaceContextID,
           let source = windowManagement.logicalSpaceContexts.first(where: { $0.id == buffered.sourceContextID })
        {
            removeWindowID(windowID, from: source)
        }
        debugLog(
            "restoring buffered window into logical macOS space id=\(windowManagement.activeLogicalSpaceContextID) sourceContext=\(buffered.sourceContextID) app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' title='\(window.title)' id=\(windowID)"
        )
    }

    func removeWindowID(_ windowID: UInt32, from context: LogicalSpaceContext) {
        windowManagement.removeWindowID(windowID, from: context)
    }

    func activeContextHasBufferedSourceWindows() -> Bool {
        windowManagement.spaceBufferedWindows.values.contains {
            $0.sourceContextID == windowManagement.activeLogicalSpaceContextID
        }
    }

    func cgWindowExists(_ windowID: UInt32) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]] else {
            return false
        }
        return !list.isEmpty
    }

    func cgWindowIsOnScreen(_ windowID: UInt32) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { info in
            if let number = info[kCGWindowNumber as String] as? UInt32 {
                return number == windowID
            }
            if let number = info[kCGWindowNumber as String] as? Int {
                return UInt32(number) == windowID
            }
            return false
        }
    }
}
