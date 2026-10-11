import AppKit

@MainActor
final class MouseInteractionOverlayController {
    private let panel: MouseInteractionOverlayPanel
    private let overlayView: MouseInteractionOverlayView

    init() {
        overlayView = MouseInteractionOverlayView(frame: .zero)
        panel = MouseInteractionOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenNone]
        panel.contentView = overlayView
    }

    /// Both the preview frame and viewport use AX/CG top-left global coordinates.
    func render(_ preview: MouseInteractionPreview, viewport: CGRect, draggedWindowID: UInt32?) {
        guard viewport.width > 0, viewport.height > 0,
              !viewport.isInfinite, !viewport.isNull,
              let primaryScreen = NSScreen.screens.first else {
            hide()
            return
        }
        if case .none = preview {
            hide()
            return
        }

        // NSScreen.main follows focus; only the primary screen defines the global flip.
        let frame = CGRect(
            x: viewport.minX,
            y: primaryScreen.frame.maxY - viewport.maxY,
            width: viewport.width,
            height: viewport.height
        )
        panel.setFrame(frame, display: false)
        overlayView.render(preview, viewport: viewport)
        switch preview {
        case .swap:
            guard let draggedWindowID,
                  let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, draggedWindowID) as? [[String: Any]],
                  let level = windows.first?[kCGWindowLayer as String] as? Int else {
                hide()
                return
            }
            // A floating panel would cover the source regardless of relative order.
            panel.level = NSWindow.Level(rawValue: level)
            panel.order(.below, relativeTo: Int(draggedWindowID))
        case .scroll:
            panel.level = .floating
            panel.orderFrontRegardless()
        case .none:
            break
        }
        panel.displayIfNeeded()
    }

    func hide() {
        panel.orderOut(nil)
        overlayView.render(.none, viewport: .zero)
    }
}

@MainActor
private final class MouseInteractionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Can also be mounted directly over a fixture; its bounds represent the AX viewport.
@MainActor
final class MouseInteractionOverlayView: NSView {
    private var preview: MouseInteractionPreview = .none
    private var viewport: CGRect = .zero
    private let swapGlass = NSGlassEffectView(frame: .zero)
    private let capsule = NSGlassEffectView(frame: .zero)
    private let capsuleChrome = MouseInteractionCapsuleChrome(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.masksToBounds = true
        // Choose translucent glass explicitly, rather than the regular system style.
        swapGlass.style = .clear
        swapGlass.cornerRadius = 10
        swapGlass.isHidden = true
        addSubview(swapGlass)
        capsule.style = .clear
        capsule.cornerRadius = 22
        capsule.isHidden = true
        capsuleChrome.autoresizingMask = [.width, .height]
        capsule.contentView = capsuleChrome
        addSubview(capsule)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshColors),
            name: NSColor.systemColorsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func render(_ preview: MouseInteractionPreview, viewport: CGRect) {
        self.preview = preview
        self.viewport = viewport
        if case .swap = preview {
            swapGlass.isHidden = false
        } else {
            swapGlass.isHidden = true
        }
        if case let .scroll(direction, canScroll) = preview {
            capsule.isHidden = false
            capsuleChrome.direction = direction
            capsuleChrome.canScroll = canScroll
        } else {
            capsule.isHidden = true
        }
        needsLayout = true
        refreshColors()
    }

    override func layout() {
        super.layout()
        if case let .swap(_, frame) = preview {
            // Keep the complete window geometry; clip at the viewport, not the glass edge.
            swapGlass.frame = CGRect(
                x: bounds.minX + frame.minX - viewport.minX,
                y: bounds.minY + viewport.maxY - frame.maxY,
                width: frame.width,
                height: frame.height
            )
        }
        guard case let .scroll(direction, _) = preview else { return }
        let inset: CGFloat = 12
        let width = min(64, max(0, bounds.width - inset * 2))
        let height = min(44, max(0, bounds.height - inset * 2))
        let x = direction == .left ? bounds.minX + inset : bounds.maxX - inset - width
        capsule.frame = CGRect(x: x, y: bounds.midY - height / 2, width: width, height: height)
        capsuleChrome.frame = capsule.bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    @objc private func refreshColors() {
        let accentColor = MiriTheme.Palette.adaptiveSystemAccentColor(for: effectiveAppearance)
        swapGlass.tintColor = accentColor.withAlphaComponent(0.10)
        capsule.tintColor = accentColor.withAlphaComponent(capsuleChrome.canScroll ? 0.12 : 0.04)
        capsuleChrome.accentColor = accentColor
        capsuleChrome.needsDisplay = true
    }
}

@MainActor
private final class MouseInteractionCapsuleChrome: NSView {
    var direction: MouseScrollDirection = .left
    var canScroll = true
    var accentColor = NSColor.controlAccentColor

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let sign: CGFloat = direction == .left ? -1 : 1
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let tip = NSPoint(x: center.x + sign * 9, y: center.y)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: center.x - sign * 9, y: center.y))
        arrow.line(to: tip)
        arrow.move(to: NSPoint(x: center.x + sign * 2, y: center.y + 7))
        arrow.line(to: tip)
        arrow.line(to: NSPoint(x: center.x + sign * 2, y: center.y - 7))
        arrow.lineWidth = 2.5
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        accentColor.withAlphaComponent(canScroll ? 1 : 0.55).setStroke()
        arrow.stroke()
    }
}
