import CoreGraphics
import ScreenCaptureKit

struct WindowSnapshotRequest: Hashable, Sendable {
    let windowID: UInt32
    let pid: pid_t
}

enum WindowSnapshotFailure: Error, Sendable {
    case missingWindow
    case captureFailed(String)
    case cancelled
}

typealias WindowSnapshotResult = Result<CGImage, WindowSnapshotFailure>

@MainActor
protocol WindowSnapshotCapturing {
    func capture(_ requests: [WindowSnapshotRequest]) async -> [WindowSnapshotRequest: WindowSnapshotResult]
}

/// One enumeration per batch, followed by a bounded number of independent
/// window captures. Nothing is streamed or written to disk.
@MainActor
final class WindowSnapshotCapturer: WindowSnapshotCapturing {
    func capture(_ requests: [WindowSnapshotRequest]) async -> [WindowSnapshotRequest: WindowSnapshotResult] {
        guard !requests.isEmpty, !Task.isCancelled else { return [:] }

        let content: SCShareableContent
        do {
            // Parked columns must be included, not just the visible desktop.
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            return Dictionary(uniqueKeysWithValues: Set(requests).map {
                ($0, .failure(.captureFailed(error.localizedDescription)))
            })
        }
        guard !Task.isCancelled else { return [:] }

        let windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        return await WindowSnapshotBatch.capture(requests) { request in
            guard let window = windows[request.windowID],
                  window.owningApplication?.processID == request.pid
            else { return .failure(.missingWindow) }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = Self.configuration(for: filter)
            // Extract the image at the callback boundary rather than moving the
            // mutable SCScreenshotOutput object between isolation domains.
            return await withCheckedContinuation { continuation in
                SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration) { output, error in
                    if let error {
                        continuation.resume(returning: .failure(.captureFailed(error.localizedDescription)))
                    } else if let image = output?.sdrImage {
                        continuation.resume(returning: .success(image))
                    } else {
                        continuation.resume(returning: .failure(.captureFailed("no SDR image returned")))
                    }
                }
            }
        }
    }

    static func configuration(for filter: SCContentFilter) -> SCScreenshotConfiguration {
        configuration(contentSize: filter.contentRect.size, pixelScale: CGFloat(filter.pointPixelScale))
    }

    static func configuration(contentSize: CGSize, pixelScale: CGFloat) -> SCScreenshotConfiguration {
        let configuration = SCScreenshotConfiguration()
        let scale = max(pixelScale, 1)
        configuration.width = max(1, Int(ceil(contentSize.width * scale)))
        configuration.height = max(1, Int(ceil(contentSize.height * scale)))
        configuration.showsCursor = false
        configuration.ignoreShadows = true
        // Each layer represents exactly one managed window, not its popups.
        configuration.includeChildWindows = false
        configuration.dynamicRange = .sdr
        configuration.displayIntent = .local
        configuration.fileURL = nil
        return configuration
    }
}

@MainActor
enum WindowSnapshotBatch {
    static func capture(
        _ requests: [WindowSnapshotRequest],
        maxConcurrentCaptures: Int = 3,
        capture: @escaping @MainActor (WindowSnapshotRequest) async -> WindowSnapshotResult
    ) async -> [WindowSnapshotRequest: WindowSnapshotResult] {
        guard !Task.isCancelled else { return [:] }
        var seen = Set<WindowSnapshotRequest>()
        var remaining = requests.filter { seen.insert($0).inserted }.makeIterator()

        return await withTaskGroup(of: (WindowSnapshotRequest, WindowSnapshotResult).self) { group in
            for _ in 0..<max(1, maxConcurrentCaptures) {
                guard let request = remaining.next() else { break }
                group.addTask {
                    guard !Task.isCancelled else { return (request, .failure(.cancelled)) }
                    return (request, await capture(request))
                }
            }

            var results: [WindowSnapshotRequest: WindowSnapshotResult] = [:]
            for await (request, result) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
                results[request] = result
                if let next = remaining.next() {
                    group.addTask {
                        guard !Task.isCancelled else { return (next, .failure(.cancelled)) }
                        return (next, await capture(next))
                    }
                }
            }
            return results
        }
    }
}
