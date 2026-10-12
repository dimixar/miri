import AppKit

enum WorkspaceBoundaryDirection: Int {
    case up = -1
    case down = 1
}

@MainActor
final class WorkspaceBoundaryFeedbackController {
    private let panel: WorkspaceBoundaryFeedbackPanel
    private let feedbackView = WorkspaceBoundaryFeedbackView(frame: .zero)
    private var animationTimer: Timer?
    private var generation = 0

    init() {
        panel = WorkspaceBoundaryFeedbackPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("miri.workspace-boundary-feedback")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenNone]
        panel.contentView = feedbackView
    }

    func render(direction: WorkspaceBoundaryDirection, targetWorkspace: Int, progress: CGFloat, on screen: NSScreen) {
        stopAnimation()
        feedbackView.alphaValue = 1
        let size = feedbackView.render(direction: direction, targetWorkspace: targetWorkspace, progress: progress)
        let visible = screen.visibleFrame
        panel.setFrame(CGRect(
            x: visible.midX - size.width / 2,
            y: direction == .up ? visible.maxY - 12 - size.height : visible.minY + 12,
            width: size.width,
            height: size.height
        ), display: false)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
    }

    func cancel() {
        guard panel.isVisible else { return }
        let initialExpansion = feedbackView.expansion
        let initialAlpha = feedbackView.alphaValue
        animate(duration: 0.30) { [weak self] elapsed in
            guard let self else { return }
            let shrink = min(1, elapsed / 0.15)
            self.feedbackView.setExpansion(initialExpansion * (1 - Self.smooth(shrink)))
            self.feedbackView.alphaValue = initialAlpha * (1 - max(0, (elapsed - 0.15) / 0.15))
        }
    }

    func complete() {
        guard panel.isVisible else { return }
        feedbackView.setExpansion(1)
        let initialAlpha = feedbackView.alphaValue
        animate(duration: 0.20) { [weak self] elapsed in
            self?.feedbackView.alphaValue = initialAlpha * (1 - elapsed / 0.20)
        }
    }

    func hide() {
        stopAnimation()
        panel.orderOut(nil)
        feedbackView.alphaValue = 0
        feedbackView.setExpansion(0)
    }

    private func stopAnimation() {
        generation += 1
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func animate(duration: TimeInterval, update: @escaping @MainActor (CGFloat) -> Void) {
        stopAnimation()
        let token = generation
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                guard self.generation == token else { return }
                let elapsed = min(duration, ProcessInfo.processInfo.systemUptime - start)
                update(CGFloat(elapsed))
                if elapsed >= duration { self.hide() }
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    fileprivate static func smooth(_ value: CGFloat) -> CGFloat {
        value * value * (3 - 2 * value)
    }
}

@MainActor
private final class WorkspaceBoundaryFeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Mount directly in native rendering fixtures; render returns the fixed outer size.
@MainActor
final class WorkspaceBoundaryFeedbackView: NSView {
    private let glass = NSGlassEffectView(frame: .zero)
    private let icon = NSImageView(frame: .zero)
    private let workspaceLabel = NSTextField(labelWithString: "")
    private var initialWidth: CGFloat = 76
    private var accentColor = NSColor.controlAccentColor
    private(set) var expansion: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        glass.style = .clear
        let content = NSView(frame: .zero)
        glass.contentView = content
        addSubview(glass)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        workspaceLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        workspaceLabel.textColor = .labelColor
        for view in [icon, workspaceLabel] { content.addSubview(view) }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshColors),
            name: NSColor.systemColorsDidChangeNotification,
            object: nil
        )
        refreshColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @discardableResult
    func render(direction: WorkspaceBoundaryDirection, targetWorkspace: Int, progress: CGFloat) -> NSSize {
        icon.image = NSImage(
            systemSymbolName: direction == .up ? "chevron.up" : "chevron.down",
            accessibilityDescription: direction == .up ? "Previous workspace" : "Next workspace"
        )
        workspaceLabel.stringValue = String(targetWorkspace)
        initialWidth = max(76, ceil(workspaceLabel.intrinsicContentSize.width) + 54)
        setAccessibilityLabel("Workspace \(targetWorkspace)")
        let clamped = progress.isFinite ? min(1, max(0, progress)) : 0
        setExpansion(WorkspaceBoundaryFeedbackController.smooth(clamped))
        return NSSize(width: initialWidth + 44, height: 68)
    }

    fileprivate func setExpansion(_ value: CGFloat) {
        expansion = value
        needsLayout = true
        needsDisplay = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let width = initialWidth + 40 * expansion
        let height: CGFloat = 40 + 24 * expansion
        glass.frame = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        glass.cornerRadius = height / 2
        let labelSize = workspaceLabel.intrinsicContentSize
        let groupWidth = 18 + 8 + labelSize.width
        icon.frame = CGRect(x: (width - groupWidth) / 2, y: (height - 18) / 2, width: 18, height: 18)
        workspaceLabel.frame = CGRect(x: icon.frame.maxX + 8, y: (height - labelSize.height) / 2, width: labelSize.width, height: labelSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        outline.lineWidth = 1.5
        accentColor.withAlphaComponent(0.45).setStroke()
        outline.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    @objc private func refreshColors() {
        accentColor = MiriTheme.Palette.adaptiveSystemAccentColor(for: effectiveAppearance)
        glass.tintColor = accentColor.withAlphaComponent(0.12)
        icon.contentTintColor = accentColor
        needsDisplay = true
    }
}
