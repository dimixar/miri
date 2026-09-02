import AppKit
import CoreGraphics

extension Miri {
    func visualFrame(_ frame: CGRect, viewport: CGRect) -> CGRect {
        guard innerGap > 0 else {
            return alignToPhysicalPixels(frame, viewport: viewport)
        }

        let gap = min(
            points(forPhysicalPixels: innerGap, in: viewport),
            frame.width * 2 / 3
        )
        var minX = frame.minX + gap / 2
        var maxX = frame.maxX - gap / 2

        // Inner gaps belong only between columns. A column edge that lands on
        // the viewport edge must not add another half-gap to the outer gap.
        if abs(frame.minX - viewport.minX) < 0.001 {
            minX = frame.minX
        }
        if abs(frame.maxX - viewport.maxX) < 0.001 {
            maxX = frame.maxX
        }

        let visual = CGRect(
            x: minX,
            y: frame.minY,
            width: max(0, maxX - minX),
            height: frame.height
        )
        return alignToPhysicalPixels(visual, viewport: viewport)
    }

    func insetViewport(_ viewport: CGRect, by inset: CGFloat) -> CGRect {
        guard inset > 0 else {
            return viewport
        }

        let insetPoints = points(forPhysicalPixels: inset, in: viewport)
        let safeInset = min(insetPoints, viewport.width / 3, viewport.height / 3)
        return alignToPhysicalPixels(
            viewport.insetBy(dx: safeInset, dy: safeInset),
            viewport: viewport
        )
    }

    func stripFrames(
        for workspace: Workspace,
        viewport: CGRect,
        activeColumn: Int,
        scrollOffset preferredScrollOffset: CGFloat?
    ) -> [CGRect] {
        guard !workspace.columns.isEmpty else {
            return []
        }

        let metrics = stripMetrics(for: workspace, viewport: viewport)
        let scrollOffset: CGFloat
        if metrics.widths.indices.contains(activeColumn),
           metrics.origins.indices.contains(activeColumn),
           shouldCenterColumn(width: metrics.widths[activeColumn], viewport: viewport)
        {
            scrollOffset = centeredScrollOffset(
                columnMinX: metrics.origins[activeColumn],
                columnWidth: metrics.widths[activeColumn],
                viewport: viewport
            )
        } else {
            if let preferredScrollOffset {
                scrollOffset = min(
                    max(preferredScrollOffset, 0),
                    maxHorizontalCameraOffset(for: workspace, viewport: viewport)
                )
            } else {
                scrollOffset = defaultScrollOffset(
                    metrics: metrics,
                    activeColumn: activeColumn,
                    viewport: viewport
                )
            }
        }
        return workspace.columns.indices.map { index in
            CGRect(
                x: viewport.minX + metrics.origins[index] - scrollOffset,
                y: viewport.minY,
                width: metrics.widths[index],
                height: viewport.height
            )
        }
    }

    func stripMetrics(for workspace: Workspace, viewport: CGRect) -> (origins: [CGFloat], widths: [CGFloat]) {
        var virtualX: CGFloat = 0
        var origins: [CGFloat] = []
        var widths: [CGFloat] = []

        for window in workspace.columns {
            origins.append(virtualX)
            let width = viewport.width * widthRatio(for: window)
            widths.append(width)
            virtualX += width
        }

        return (origins, widths)
    }

    func revealActiveColumnIfNeeded(in workspace: Workspace, viewport: CGRect) {
        guard !workspace.columns.isEmpty,
              workspace.columns.indices.contains(workspace.activeColumn),
              viewport.width > 0
        else {
            windowManagement.setScrollOffset(nil, in: workspace)
            return
        }

        let metrics = stripMetrics(for: workspace, viewport: viewport)
        guard metrics.origins.indices.contains(workspace.activeColumn),
              metrics.widths.indices.contains(workspace.activeColumn)
        else {
            windowManagement.setScrollOffset(nil, in: workspace)
            return
        }

        let currentOffset = horizontalCameraOffset(for: workspace, viewport: viewport)
        let columnMinX = metrics.origins[workspace.activeColumn]
        let columnMaxX = columnMinX + metrics.widths[workspace.activeColumn]
        if shouldCenterColumn(width: metrics.widths[workspace.activeColumn], viewport: viewport) {
            windowManagement.setScrollOffset(centeredScrollOffset(
                columnMinX: columnMinX,
                columnWidth: metrics.widths[workspace.activeColumn],
                viewport: viewport
            ), in: workspace)
            return
        }

        var targetOffset = currentOffset

        if columnMinX < currentOffset {
            targetOffset = columnMinX
        } else if columnMaxX > currentOffset + viewport.width {
            targetOffset = columnMaxX - viewport.width
        }

        let maxOffset = maxHorizontalCameraOffset(for: workspace, viewport: viewport)
        targetOffset = min(max(targetOffset, 0), maxOffset)
        windowManagement.setScrollOffset(targetOffset, in: workspace)
    }

    func horizontalCameraOffset(for workspace: Workspace, viewport: CGRect) -> CGFloat {
        let metrics = stripMetrics(for: workspace, viewport: viewport)
        let activeColumn = min(max(workspace.activeColumn, 0), max(workspace.columns.count - 1, 0))
        if metrics.origins.indices.contains(activeColumn),
           metrics.widths.indices.contains(activeColumn),
           shouldCenterColumn(width: metrics.widths[activeColumn], viewport: viewport)
        {
            return centeredScrollOffset(
                columnMinX: metrics.origins[activeColumn],
                columnWidth: metrics.widths[activeColumn],
                viewport: viewport
            )
        }

        if let scrollOffset = workspace.scrollOffset {
            return min(max(scrollOffset, 0), maxHorizontalCameraOffset(for: workspace, viewport: viewport))
        }

        return defaultScrollOffset(metrics: metrics, activeColumn: activeColumn, viewport: viewport)
    }

    func maxHorizontalCameraOffset(for workspace: Workspace, viewport: CGRect) -> CGFloat {
        guard !workspace.columns.isEmpty else {
            return 0
        }

        let metrics = stripMetrics(for: workspace, viewport: viewport)
        let contentWidth = zip(metrics.origins, metrics.widths)
            .map { $0.0 + $0.1 }
            .max() ?? viewport.width
        let lastColumnOffset = defaultScrollOffset(
            metrics: metrics,
            activeColumn: workspace.columns.count - 1,
            viewport: viewport
        )
        return max(0, contentWidth - viewport.width, lastColumnOffset)
    }

    func defaultScrollOffset(
        metrics: (origins: [CGFloat], widths: [CGFloat]),
        activeColumn: Int,
        viewport: CGRect
    ) -> CGFloat {
        guard metrics.origins.indices.contains(activeColumn),
              metrics.widths.indices.contains(activeColumn)
        else {
            return 0
        }

        switch focusAlignment {
        case .centered:
            return centeredScrollOffset(
                columnMinX: metrics.origins[activeColumn],
                columnWidth: metrics.widths[activeColumn],
                viewport: viewport
            )
        case .centeredSmart where metrics.widths[activeColumn] > viewport.width / 2:
            return centeredScrollOffset(
                columnMinX: metrics.origins[activeColumn],
                columnWidth: metrics.widths[activeColumn],
                viewport: viewport
            )
        case .default, .centeredSmart:
            return max(0, metrics.origins[activeColumn] + metrics.widths[activeColumn] - viewport.width)
        }
    }

    func shouldCenterColumn(width: CGFloat, viewport: CGRect) -> Bool {
        switch focusAlignment {
        case .default:
            return false
        case .centered:
            return true
        case .centeredSmart:
            return width > viewport.width / 2
        }
    }

    func centeredScrollOffset(columnMinX: CGFloat, columnWidth: CGFloat, viewport: CGRect) -> CGFloat {
        columnMinX + columnWidth / 2 - viewport.width / 2
    }

    func parkedFrame(for window: ManagedWindow, viewport: CGRect, beforeActive: Bool) -> CGRect {
        let width = viewport.width * widthRatio(for: window)
        let sliver = parkedSliverPoints(for: viewport)
        let visualOutsets = renderedOutsets(for: window)
        var frame = CGRect(x: viewport.minX, y: viewport.minY, width: width, height: viewport.height)
        frame.origin.x = beforeActive
            ? viewport.minX - width - visualOutsets.right + sliver
            : viewport.maxX + visualOutsets.left - sliver
        frame.origin.y = viewport.maxY + visualOutsets.top - sliver
        return frame
    }

    func parkedSliverPoints(for viewport: CGRect) -> CGFloat {
        let pixelWidth = max(0, parkedSliverWidth)
        return points(forPhysicalPixels: pixelWidth, in: viewport)
    }

    func screenContaining(_ rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayBounds(displayID).contains(center)
        }
    }

    func points(forPhysicalPixels pixels: CGFloat, in viewport: CGRect) -> CGFloat {
        let screen = screenContaining(viewport) ?? NSScreen.main
        let scale = max(screen?.backingScaleFactor ?? 1, 1)
        return pixels / scale
    }

    func alignToPhysicalPixels(_ frame: CGRect, viewport: CGRect) -> CGRect {
        let screen = screenContaining(viewport) ?? NSScreen.main
        let scale = max(screen?.backingScaleFactor ?? 1, 1)
        let minX = (frame.minX * scale).rounded() / scale
        let minY = (frame.minY * scale).rounded() / scale
        let maxX = (frame.maxX * scale).rounded() / scale
        let maxY = (frame.maxY * scale).rounded() / scale
        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    func renderedOutsets(for window: ManagedWindow) -> (
        left: CGFloat,
        right: CGFloat,
        top: CGFloat,
        bottom: CGFloat
    ) {
        if let shadow = SkyLight.shared.shadowParameters(for: window.windowID),
           shadow.density > 0,
           shadow.standardDeviation > 0
        {
            // WindowServer's shadow texture has finite support at roughly
            // three standard deviations from its offset origin.
            let radius = ceil(shadow.standardDeviation * 3)
            return (
                left: max(0, radius - shadow.offsetX),
                right: max(0, radius + shadow.offsetX),
                top: max(0, radius - shadow.offsetY),
                bottom: max(0, radius + shadow.offsetY)
            )
        }

        guard let windowID = window.windowID,
              let renderedBounds = cgWindowBounds(windowID: windowID)
        else {
            return (0, 0, 0, 0)
        }
        let id = ObjectIdentifier(window)
        guard let logicalFrame = layoutController.appliedFrames[id]
                ?? layoutController.presentationFrames[id]
                ?? layoutController.requestedFrames[id],
              logicalFrame.width > 0,
              renderedBounds.width > 0,
              abs(logicalFrame.midX - renderedBounds.midX) <= 128,
              abs(logicalFrame.midY - renderedBounds.midY) <= 128,
              abs(logicalFrame.width - renderedBounds.width) <= 256,
              abs(logicalFrame.height - renderedBounds.height) <= 256
        else {
            return (0, 0, 0, 0)
        }

        let left = min(max(logicalFrame.minX - renderedBounds.minX, 0), 128)
        let right = min(max(renderedBounds.maxX - logicalFrame.maxX, 0), 128)
        let top = min(max(logicalFrame.minY - renderedBounds.minY, 0), 128)
        let bottom = min(max(renderedBounds.maxY - logicalFrame.maxY, 0), 128)
        return (left, right, top, bottom)
    }

    func cgWindowBounds(windowID: UInt32) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let info = list.first,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary
        else {
            return nil
        }

        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect) else {
            return nil
        }
        return rect
    }

    func currentViewport() -> CGRect {
        guard let screen = NSScreen.main else {
            return insetViewport(CGDisplayBounds(CGMainDisplayID()), by: outerGap)
        }

        let visible = screen.visibleFrame
        let screenFrame = screen.frame
        let axY = screenFrame.maxY - visible.maxY
        let viewport = CGRect(x: visible.minX, y: axY, width: visible.width, height: visible.height)
        return insetViewport(viewport, by: outerGap)
    }

}
