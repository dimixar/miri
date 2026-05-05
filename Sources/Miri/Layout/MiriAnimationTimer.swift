import CoreVideo
import Foundation

final class AnimationTimer: @unchecked Sendable {
    private var dispatchTimer: DispatchSourceTimer?
    private var displayLink: CVDisplayLink?
    private let lock = NSLock()
    private var cancelled = false
    private var pendingMainFrame = false
    private var lastFrameTime: Double = 0
    private let minimumFrameInterval: Double
    private let onFrame: @Sendable () -> Void

    init(preferredFPS: Int, onFrame: @escaping @Sendable () -> Void) {
        self.minimumFrameInterval = preferredFPS > 0 ? 1.0 / Double(preferredFPS) : 0
        self.onFrame = onFrame

        if !startDisplayLink() {
            startDispatchTimer(preferredFPS: preferredFPS)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let link = displayLink
        let timer = dispatchTimer
        displayLink = nil
        dispatchTimer = nil
        lock.unlock()

        if let link {
            CVDisplayLinkStop(link)
        }
        timer?.cancel()
    }

    private func startDisplayLink() -> Bool {
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else {
            return false
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: CVDisplayLinkOutputCallback = { _, _, outputTime, _, _, context in
            guard let context else {
                return kCVReturnSuccess
            }
            let timer = Unmanaged<AnimationTimer>.fromOpaque(context).takeUnretainedValue()
            timer.displayLinkFrame(outputTime: outputTime.pointee)
            return kCVReturnSuccess
        }

        guard CVDisplayLinkSetOutputCallback(link, callback, context) == kCVReturnSuccess,
              CVDisplayLinkStart(link) == kCVReturnSuccess
        else {
            CVDisplayLinkStop(link)
            return false
        }

        displayLink = link
        return true
    }

    private func displayLinkFrame(outputTime: CVTimeStamp) {
        let frameTime: Double
        if outputTime.videoTimeScale > 0 {
            frameTime = Double(outputTime.videoTime) / Double(outputTime.videoTimeScale)
        } else {
            frameTime = CFAbsoluteTimeGetCurrent()
        }

        lock.lock()
        if cancelled || pendingMainFrame {
            lock.unlock()
            return
        }
        if minimumFrameInterval > 0,
           lastFrameTime > 0,
           frameTime - lastFrameTime < minimumFrameInterval * 0.85
        {
            lock.unlock()
            return
        }
        lastFrameTime = frameTime
        pendingMainFrame = true
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            lock.lock()
            let shouldRun = !cancelled
            pendingMainFrame = false
            lock.unlock()

            if shouldRun {
                onFrame()
            }
        }
    }

    private func startDispatchTimer(preferredFPS: Int) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let frameIntervalMS = max(1, Int((1000.0 / Double(max(preferredFPS, 1))).rounded()))
        timer.schedule(deadline: .now(), repeating: .milliseconds(frameIntervalMS), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            lock.lock()
            let shouldRun = !cancelled
            lock.unlock()
            if shouldRun {
                onFrame()
            }
        }
        dispatchTimer = timer
        timer.resume()
    }
}
