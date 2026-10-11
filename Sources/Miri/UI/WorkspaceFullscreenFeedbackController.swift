import AppKit

@MainActor
final class WorkspaceFullscreenFeedbackController {
    private let panel: WorkspaceFullscreenFeedbackPanel
    private let feedbackView = WorkspaceFullscreenFeedbackView(frame: .zero)
    private var dismissalTimer: Timer?

    init() {
        panel = WorkspaceFullscreenFeedbackPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("miri.workspace-fullscreen-feedback")
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

    func show(_ message: String, on screen: NSScreen) {
        dismissalTimer?.invalidate()
        let size = feedbackView.setMessage(message)
        let visible = screen.visibleFrame
        panel.setFrame(CGRect(
            x: visible.midX - size.width / 2,
            y: visible.maxY - 12 - size.height,
            width: size.width,
            height: size.height
        ), display: false)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        dismissalTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func hide() {
        dismissalTimer?.invalidate()
        dismissalTimer = nil
        panel.orderOut(nil)
    }
}

@MainActor
private final class WorkspaceFullscreenFeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WorkspaceFullscreenFeedbackView: NSGlassEffectView {
    private let messageLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        style = .clear
        cornerRadius = 22
        let content = NSView(frame: .zero)
        contentView = content
        icon.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Workspace fullscreen")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        messageLabel.textColor = .labelColor
        for view in [icon, messageLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            messageLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            messageLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
        ])
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

    func setMessage(_ message: String) -> NSSize {
        messageLabel.stringValue = message
        return NSSize(width: ceil(messageLabel.intrinsicContentSize.width) + 68, height: 44)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    @objc private func refreshColors() {
        let accentColor = MiriTheme.Palette.adaptiveSystemAccentColor(for: effectiveAppearance)
        tintColor = accentColor.withAlphaComponent(0.12)
        icon.contentTintColor = accentColor
    }
}
