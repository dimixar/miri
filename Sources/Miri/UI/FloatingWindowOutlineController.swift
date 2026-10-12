import AppKit

@MainActor
final class FloatingWindowOutlineController {
    private var targets: [UInt32: pid_t] = [:]
    private var panels: [UInt32: FloatingWindowOutlinePanel] = [:]
    private var timer: Timer?
    private var thickness: CGFloat = 2

    deinit {
        MainActor.assumeIsolated { hide() }
    }

    func update(windows: [ManagedWindow], enabled: Bool, thickness: Int) {
        guard enabled else {
            hide()
            return
        }
        self.thickness = CGFloat(min(max(thickness, 1), 10))
        targets = Dictionary(windows.compactMap { window in
            window.windowID.map { ($0, window.pid) }
        }, uniquingKeysWith: { first, _ in first })
        for id in Array(panels.keys) where targets[id] == nil {
            panels.removeValue(forKey: id)?.close()
        }
        guard !targets.isEmpty else {
            hide()
            return
        }
        refresh()
        if timer == nil {
            // Follow native dragging and stacking without AX IPC. Poll only while
            // manually floated outlines exist; never run an idle global watcher.
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 1.0 / 60
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        targets.removeAll()
        for panel in panels.values { panel.close() }
        panels.removeAll()
    }

    private func refresh() {
        guard let primaryScreen = NSScreen.screens.first,
              let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            for panel in panels.values { panel.orderOut(nil) }
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        var rendered = Set<UInt32>()
        for info in visible {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  targets[id] == pid,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let level = info[kCGWindowLayer as String] as? Int,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }
            var frame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame),
                  frame.width > 0, frame.height > 0 else { continue }
            let panel = panels[id] ?? FloatingWindowOutlinePanel()
            panels[id] = panel
            let appKitFrame = CGRect(
                x: frame.minX, y: primaryScreen.frame.maxY - frame.maxY,
                width: frame.width, height: frame.height
            ).insetBy(dx: -thickness, dy: -thickness)
            let sizeChanged = panel.frame.size != appKitFrame.size
            if sizeChanged || now - panel.lastRadiusRefresh >= 1 {
                panel.cornerRadius = SkyLight.shared.cornerRadius(for: id) ?? 10
                panel.lastRadiusRefresh = now
            }
            panel.outlineView.configure(cornerRadius: panel.cornerRadius, thickness: thickness)
            if panel.frame != appKitFrame { panel.setFrame(appKitFrame, display: true) }
            panel.level = NSWindow.Level(rawValue: level)
            // The rim sits outside the target. Ordering below it lets higher
            // windows occlude the outline rather than drawing through them.
            panel.order(.below, relativeTo: Int(id))
            rendered.insert(id)
        }
        for (id, panel) in panels where !rendered.contains(id) { panel.orderOut(nil) }
    }
}

@MainActor
private final class FloatingWindowOutlinePanel: NSPanel {
    let outlineView = FloatingWindowOutlineView(frame: .zero)
    var cornerRadius: CGFloat = 10
    var lastRadiusRefresh: CFAbsoluteTime = 0

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        identifier = NSUserInterfaceItemIdentifier("miri.manual-floating-outline")
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenNone]
        contentView = outlineView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingWindowOutlineView: NSView {
    private let glass = NSGlassEffectView(frame: .zero)
    private let rimMask = CAShapeLayer()
    private let edge = CAShapeLayer()
    private var cornerRadius: CGFloat = 10
    private var thickness: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        glass.style = .clear
        glass.cornerRadius = 12
        glass.wantsLayer = true
        rimMask.fillRule = .evenOdd
        glass.layer?.mask = rimMask
        addSubview(glass)
        edge.fillColor = NSColor.clear.cgColor
        edge.lineWidth = 0.5
        layer?.addSublayer(edge)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshColors), name: NSColor.systemColorsDidChangeNotification, object: nil
        )
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(cornerRadius: CGFloat, thickness: CGFloat) {
        guard self.cornerRadius != cornerRadius || self.thickness != thickness else { return }
        self.cornerRadius = cornerRadius
        self.thickness = thickness
        needsLayout = true
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let outerRadius = cornerRadius + thickness
        glass.cornerRadius = outerRadius
        rimMask.frame = glass.bounds
        let path = CGMutablePath()
        path.addRoundedRect(in: glass.bounds, cornerWidth: outerRadius, cornerHeight: outerRadius)
        path.addRoundedRect(in: glass.bounds.insetBy(dx: thickness, dy: thickness), cornerWidth: cornerRadius, cornerHeight: cornerRadius)
        rimMask.path = path
        edge.frame = bounds
        edge.path = CGPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), cornerWidth: outerRadius - 0.25, cornerHeight: outerRadius - 0.25, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    @objc private func refreshColors() {
        let accent = MiriTheme.Palette.adaptiveSystemAccentColor(for: effectiveAppearance)
        glass.tintColor = accent.withAlphaComponent(0.12)
        edge.strokeColor = accent.withAlphaComponent(0.55).cgColor
    }
}
