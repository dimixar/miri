import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Best-effort restoration used by the standalone cleanup watcher after its
/// parent has exited. Target-app AX work is grouped by owner PID and runs on
/// independent queues so one unhealthy application cannot delay the others.
enum WindowRestoration {
    private static let overallTimeout: TimeInterval = 3.0

    static func restore(_ snapshot: RestoreSnapshot) {
        var records = snapshot.restorationRecords
        guard !records.isEmpty else { return }

        let ownerPIDs = cgOwnerPIDs(windowIDs: Set(records.map(\.windowID)))
        for index in records.indices where records[index].ownerPID == nil {
            records[index].ownerPID = ownerPIDs[records[index].windowID]
        }

        normalizeCompositorState(records: records)
        guard AXIsProcessTrusted() else { return }

        let tiledByPID = tiledWindowIDsByPID(records)
        guard !tiledByPID.isEmpty else { return }

        let deadline = CFAbsoluteTimeGetCurrent() + overallTimeout
        let group = DispatchGroup()
        for (pid, windowIDs) in tiledByPID {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = AXCleanupTransport.restoreTiledFrames(
                    pid: pid,
                    windowIDs: windowIDs,
                    frame: snapshot.viewport.cgRect,
                    deadline: deadline
                )
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + overallTimeout)
    }

    static func tiledWindowIDsByPID(
        _ records: [RestoreWindowRecord]
    ) -> [pid_t: Set<UInt32>] {
        var result: [pid_t: Set<UInt32>] = [:]
        for record in records where record.kind == .tiled {
            guard let pid = record.ownerPID else { continue }
            result[pid, default: []].insert(record.windowID)
        }
        return result
    }

    private static func normalizeCompositorState(records: [RestoreWindowRecord]) {
        let normalLevel = Int32(CGWindowLevelForKey(.normalWindow))
        for record in records {
            if let bounds = cgWindowBounds(windowID: record.windowID) {
                let normalTransform = CGAffineTransform(
                    translationX: -bounds.minX,
                    y: -bounds.minY
                )
                _ = SkyLight.shared.setTransform(normalTransform, for: record.windowID)
            }
            _ = SkyLight.shared.setLevel(normalLevel, for: record.windowID)
        }
    }

    private static func cgOwnerPIDs(windowIDs: Set<UInt32>) -> [UInt32: pid_t] {
        guard !windowIDs.isEmpty,
              let entries = CGWindowListCopyWindowInfo(
                [.optionAll],
                CGWindowID(0)
              ) as? [[String: Any]]
        else { return [:] }

        var owners: [UInt32: pid_t] = [:]
        for entry in entries {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let owner = entry[kCGWindowOwnerPID as String] as? NSNumber
            else { continue }
            let windowID = number.uint32Value
            guard windowIDs.contains(windowID) else { continue }
            owners[windowID] = pid_t(owner.int32Value)
        }
        return owners
    }

    private static func cgWindowBounds(windowID: UInt32) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowID)
        ) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary
        else { return nil }

        var rect = CGRect.zero
        return CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect) ? rect : nil
    }
}

enum CleanupWatcher {
    static func run(parentPID: pid_t, snapshotPath: String) -> Never {
        while true {
            if kill(parentPID, 0) == -1 && errno == ESRCH {
                if FileManager.default.fileExists(atPath: snapshotPath) {
                    restore(snapshotPath: snapshotPath)
                    try? FileManager.default.removeItem(atPath: snapshotPath)
                }
                exit(0)
            }

            usleep(250_000)
        }
    }

    private static func restore(snapshotPath: String) {
        let url = URL(fileURLWithPath: snapshotPath)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(RestoreSnapshot.self, from: data)
        else { return }

        WindowRestoration.restore(snapshot)
    }
}
