import CoreGraphics
import Foundation

struct LayoutEngineSettings: Sendable {
    var focusAlignment: FocusAlignment
    var innerGap: CGFloat
    var parkedSliverWidth: CGFloat
    var physicalPixelScale: CGFloat
}

struct LayoutEngineWindow: Sendable {
    var window: ManagedWindow
    var widthRatio: CGFloat
    var renderedOutsets: (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat)
}

struct LayoutEngineWorkspace: Sendable {
    var columns: [LayoutEngineWindow]
    var activeColumn: Int
    var scrollOffset: CGFloat?
}

struct LayoutEngineInput: Sendable {
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
        let offset: CGFloat
        if metrics.widths.indices.contains(activeColumn),
           metrics.origins.indices.contains(activeColumn),
           shouldCenterColumn(width: metrics.widths[activeColumn], viewport: viewport, settings: settings) {
            offset = centeredScrollOffset(
                columnMinX: metrics.origins[activeColumn],
                columnWidth: metrics.widths[activeColumn],
                viewport: viewport
            )
        } else if let preferredScrollOffset {
            offset = min(
                max(preferredScrollOffset, 0),
                maxHorizontalCameraOffset(workspace: workspace, viewport: viewport, settings: settings)
            )
        } else {
            offset = defaultScrollOffset(
                metrics: metrics,
                activeColumn: activeColumn,
                viewport: viewport,
                settings: settings
            )
        }
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
        workspace: LayoutEngineWorkspace,
        viewport: CGRect,
        settings: LayoutEngineSettings
    ) -> CGFloat {
        guard !workspace.columns.isEmpty else { return 0 }
        let metrics = stripMetrics(workspace: workspace, viewport: viewport)
        let contentWidth = zip(metrics.origins, metrics.widths).map(+).max() ?? viewport.width
        let lastOffset = defaultScrollOffset(
            metrics: metrics,
            activeColumn: workspace.columns.count - 1,
            viewport: viewport,
            settings: settings
        )
        return max(0, contentWidth - viewport.width, lastOffset)
    }

    static func defaultScrollOffset(
        metrics: (origins: [CGFloat], widths: [CGFloat]),
        activeColumn: Int,
        viewport: CGRect,
        settings: LayoutEngineSettings
    ) -> CGFloat {
        guard metrics.origins.indices.contains(activeColumn), metrics.widths.indices.contains(activeColumn) else {
            return 0
        }
        switch settings.focusAlignment {
        case .centered:
            return centeredScrollOffset(columnMinX: metrics.origins[activeColumn], columnWidth: metrics.widths[activeColumn], viewport: viewport)
        case .centeredSmart where metrics.widths[activeColumn] > viewport.width / 2:
            return centeredScrollOffset(columnMinX: metrics.origins[activeColumn], columnWidth: metrics.widths[activeColumn], viewport: viewport)
        case .default, .centeredSmart:
            return max(0, metrics.origins[activeColumn] + metrics.widths[activeColumn] - viewport.width)
        }
    }

    static func shouldCenterColumn(width: CGFloat, viewport: CGRect, settings: LayoutEngineSettings) -> Bool {
        switch settings.focusAlignment {
        case .default: return false
        case .centered: return true
        case .centeredSmart: return width > viewport.width / 2
        }
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
