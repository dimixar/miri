import CoreGraphics
import Foundation

struct LayoutEngineSettings {
    var focusAlignment: FocusAlignment
    var innerGap: CGFloat
    var parkedSliverWidth: CGFloat
    var physicalPixelScale: CGFloat
}

struct LayoutEngineWindow {
    var window: ManagedWindow
    var widthRatio: CGFloat
    var renderedOutsets: (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat)
}

struct LayoutEngineWorkspace {
    var columns: [LayoutEngineWindow]
    var activeColumn: Int
    var scrollOffset: CGFloat?
}

struct LayoutEngineInput {
    var workspaces: [LayoutEngineWorkspace]
    var state: LayoutState
    var viewport: CGRect
    var settings: LayoutEngineSettings
    var parkHidden: Bool
}

/// Pure geometry and projection. The engine receives a complete immutable view
/// of the model and never reads coordinator or WindowServer state.
enum LayoutEngine {
    static func project(_ input: LayoutEngineInput) -> [LayoutItem] {
        let activeWorkspace = min(
            max(input.state.activeWorkspace, 0),
            max(input.workspaces.count - 1, 0)
        )
        var result: [LayoutItem] = []

        for (workspaceIndex, workspace) in input.workspaces.enumerated() {
            let activeColumn = resolvedActiveColumn(
                workspace,
                workspaceIndex: workspaceIndex,
                state: input.state
            )
            let scrollOffset = input.state.scrollOffsets.indices.contains(workspaceIndex)
                ? input.state.scrollOffsets[workspaceIndex]
                : workspace.scrollOffset
            let strip = stripFrames(
                workspace: workspace,
                viewport: input.viewport,
                activeColumn: activeColumn,
                preferredScrollOffset: scrollOffset,
                settings: input.settings
            )
            let rowOffset = CGFloat(workspaceIndex - activeWorkspace) * input.viewport.height

            for (columnIndex, column) in workspace.columns.enumerated() {
                var projected = strip[columnIndex]
                projected.origin.y += rowOffset
                projected = visualFrame(projected, viewport: input.viewport, settings: input.settings)
                let visible = projected.intersects(input.viewport)
                let frame: CGRect
                if visible || !input.parkHidden {
                    frame = projected
                } else {
                    let beforeActive = workspaceIndex == activeWorkspace
                        ? columnIndex < activeColumn
                        : workspaceIndex < activeWorkspace
                    frame = parkedFrame(
                        column: column,
                        viewport: input.viewport,
                        beforeActive: beforeActive,
                        settings: input.settings
                    )
                }
                result.append(LayoutItem(window: column.window, frame: frame, visible: visible))
            }
        }

        return result
    }

    static func stripMetrics(
        workspace: LayoutEngineWorkspace,
        viewport: CGRect
    ) -> (origins: [CGFloat], widths: [CGFloat]) {
        var virtualX: CGFloat = 0
        var origins: [CGFloat] = []
        var widths: [CGFloat] = []
        for column in workspace.columns {
            origins.append(virtualX)
            let width = viewport.width * column.widthRatio
            widths.append(width)
            virtualX += width
        }
        return (origins, widths)
    }

    static func stripFrames(
        workspace: LayoutEngineWorkspace,
        viewport: CGRect,
        activeColumn: Int,
        preferredScrollOffset: CGFloat?,
        settings: LayoutEngineSettings
    ) -> [CGRect] {
        guard !workspace.columns.isEmpty else { return [] }
        let metrics = stripMetrics(workspace: workspace, viewport: viewport)
        let offset = resolveScrollOffset(
            metrics: metrics,
            activeColumn: activeColumn,
            viewport: viewport,
            focusAlignment: settings.focusAlignment,
            preferredScrollOffset: preferredScrollOffset
        )
        return workspace.columns.indices.map { index in
            CGRect(
                x: viewport.minX + metrics.origins[index] - offset,
                y: viewport.minY,
                width: metrics.widths[index],
                height: viewport.height
            )
        }
    }

    static func visualFrame(
        _ frame: CGRect,
        viewport: CGRect,
        settings: LayoutEngineSettings
    ) -> CGRect {
        guard settings.innerGap > 0 else {
            return alignToPhysicalPixels(frame, scale: settings.physicalPixelScale)
        }
        let gap = min(settings.innerGap / max(settings.physicalPixelScale, 1), frame.width * 2 / 3)
        var minX = frame.minX + gap / 2
        var maxX = frame.maxX - gap / 2
        if abs(frame.minX - viewport.minX) < 0.001 { minX = frame.minX }
        if abs(frame.maxX - viewport.maxX) < 0.001 { maxX = frame.maxX }
        return alignToPhysicalPixels(
            CGRect(x: minX, y: frame.minY, width: max(0, maxX - minX), height: frame.height),
            scale: settings.physicalPixelScale
        )
    }

    static func maxHorizontalCameraOffset(
        metrics: (origins: [CGFloat], widths: [CGFloat]),
        viewport: CGRect,
        focusAlignment: FocusAlignment
    ) -> CGFloat {
        guard !metrics.widths.isEmpty, metrics.origins.count == metrics.widths.count else { return 0 }
        let contentWidth = zip(metrics.origins, metrics.widths).map(+).max() ?? viewport.width
        let lastOffset = alignedScrollOffset(
            metrics: metrics,
            activeColumn: metrics.widths.count - 1,
            viewport: viewport,
            focusAlignment: focusAlignment,
            preferredScrollOffset: nil
        ) ?? 0
        return max(0, contentWidth - viewport.width, lastOffset)
    }

    /// Resolves alignment before ordinary strip bounds: centering a boundary
    /// window, or fitting its neighbor, can legitimately need a negative offset.
    static func resolveScrollOffset(
        metrics: (origins: [CGFloat], widths: [CGFloat]),
        activeColumn: Int,
        viewport: CGRect,
        focusAlignment: FocusAlignment,
        preferredScrollOffset: CGFloat?,
        revealActiveColumn: Bool = false
    ) -> CGFloat {
        guard viewport.width > 0,
              metrics.origins.count == metrics.widths.count,
              metrics.widths.indices.contains(activeColumn) else {
            return 0
        }
        if let offset = alignedScrollOffset(
            metrics: metrics,
            activeColumn: activeColumn,
            viewport: viewport,
            focusAlignment: focusAlignment,
            preferredScrollOffset: preferredScrollOffset
        ) {
            return offset
        }

        let columnMinX = metrics.origins[activeColumn]
        let columnMaxX = columnMinX + metrics.widths[activeColumn]
        var offset = preferredScrollOffset ?? max(0, columnMaxX - viewport.width)
        if revealActiveColumn {
            if columnMinX < offset {
                offset = columnMinX
            } else if columnMaxX > offset + viewport.width {
                offset = columnMaxX - viewport.width
            }
        }
        // A smart pair may extend the camera beyond ordinary strip bounds.
        // Focusing its visible narrow member must not snap that view to an edge.
        if focusAlignment == .centeredSmart,
           columnMinX >= offset,
           columnMaxX <= offset + viewport.width {
            return offset
        }
        return min(max(offset, 0), maxHorizontalCameraOffset(
            metrics: metrics,
            viewport: viewport,
            focusAlignment: focusAlignment
        ))
    }

    private static func alignedScrollOffset(
        metrics: (origins: [CGFloat], widths: [CGFloat]),
        activeColumn: Int,
        viewport: CGRect,
        focusAlignment: FocusAlignment,
        preferredScrollOffset: CGFloat?
    ) -> CGFloat? {
        guard focusAlignment != .default else { return nil }
        let width = metrics.widths[activeColumn]
        let centeredOffset = centeredScrollOffset(
            columnMinX: metrics.origins[activeColumn],
            columnWidth: width,
            viewport: viewport
        )
        if focusAlignment == .centered || metrics.widths.count == 1 { return centeredOffset }
        guard width >= viewport.width / 2 else { return nil }

        // Column slots already include their inner gaps. Allow only arithmetic
        // roundoff here, so an exact fit survives fractional width ratios.
        let tolerance = max(viewport.width, 1) * CGFloat.ulpOfOne * 8
        let referenceOffset = preferredScrollOffset ?? centeredOffset
        let candidates = [activeColumn - 1, activeColumn + 1].compactMap { index -> (
            index: Int, width: CGFloat, lowerOffset: CGFloat, upperOffset: CGFloat, movement: CGFloat
        )? in
            guard metrics.widths.indices.contains(index) else { return nil }
            let pairMinX = min(metrics.origins[activeColumn], metrics.origins[index])
            let pairMaxX = max(
                metrics.origins[activeColumn] + width,
                metrics.origins[index] + metrics.widths[index]
            )
            guard pairMaxX - pairMinX <= viewport.width + tolerance else { return nil }
            let lowerOffset = min(pairMaxX - viewport.width, pairMinX)
            let upperOffset = pairMinX
            let nearestOffset = min(max(referenceOffset, lowerOffset), upperOffset)
            return (index, metrics.widths[index], lowerOffset, upperOffset, abs(nearestOffset - referenceOffset))
        }.sorted { lhs, rhs in
            if lhs.width != rhs.width { return lhs.width < rhs.width }
            if lhs.movement != rhs.movement { return lhs.movement < rhs.movement }
            return lhs.index < rhs.index
        }

        guard let neighbor = candidates.first else { return centeredOffset }
        if let preferredScrollOffset,
           preferredScrollOffset >= neighbor.lowerOffset,
           preferredScrollOffset <= neighbor.upperOffset {
            return preferredScrollOffset
        }
        return min(max(centeredOffset, neighbor.lowerOffset), neighbor.upperOffset)
    }

    static func centeredScrollOffset(columnMinX: CGFloat, columnWidth: CGFloat, viewport: CGRect) -> CGFloat {
        columnMinX + columnWidth / 2 - viewport.width / 2
    }

    static func alignToPhysicalPixels(_ frame: CGRect, scale: CGFloat) -> CGRect {
        let scale = max(scale, 1)
        let minX = (frame.minX * scale).rounded() / scale
        let minY = (frame.minY * scale).rounded() / scale
        let maxX = (frame.maxX * scale).rounded() / scale
        let maxY = (frame.maxY * scale).rounded() / scale
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private static func resolvedActiveColumn(
        _ workspace: LayoutEngineWorkspace,
        workspaceIndex: Int,
        state: LayoutState
    ) -> Int {
        guard !workspace.columns.isEmpty else { return 0 }
        let value = state.activeColumns.indices.contains(workspaceIndex)
            ? state.activeColumns[workspaceIndex]
            : workspace.activeColumn
        return min(max(value, 0), workspace.columns.count - 1)
    }

    private static func parkedFrame(
        column: LayoutEngineWindow,
        viewport: CGRect,
        beforeActive: Bool,
        settings: LayoutEngineSettings
    ) -> CGRect {
        let width = viewport.width * column.widthRatio
        let sliver = max(0, settings.parkedSliverWidth) / max(settings.physicalPixelScale, 1)
        var frame = CGRect(x: viewport.minX, y: viewport.minY, width: width, height: viewport.height)
        frame.origin.x = beforeActive
            ? viewport.minX - width - column.renderedOutsets.right + sliver
            : viewport.maxX + column.renderedOutsets.left - sliver
        frame.origin.y = viewport.maxY + column.renderedOutsets.top - sliver
        return frame
    }
}
