import AppKit

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stateProvider: () -> StatusMenuViewState
    private let actionSink: (UIAction) -> Void
    private let menu = NSMenu()
    private let workspaceItem = NSMenuItem(title: "Workspace: —", action: nil, keyEquivalent: "")
    private let focusedItem = NSMenuItem(title: "Focused: —", action: nil, keyEquivalent: "")
    private let widthItem = NSMenuItem(title: "Width: —", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Grant Accessibility Access…", action: nil, keyEquivalent: "")
    private let permissionSeparator = NSMenuItem.separator()
    private let rescanItem = NSMenuItem(title: "Rescan Windows", action: #selector(rescanWindows), keyEquivalent: "")
    private var workspaceMenuItems: [NSMenuItem] = []
    private var lastWorkspaceBarSignature: WorkspaceBarRenderSignature?
    private var workspaceBarRefreshScheduled = false
    private var iconCache: [String: NSImage] = [:]
    private lazy var fallbackIcon = NSWorkspace.shared.icon(for: .application)

    init(stateProvider: @escaping () -> StatusMenuViewState, actionSink: @escaping (UIAction) -> Void) {
        self.stateProvider = stateProvider
        self.actionSink = actionSink
        super.init()
        configureMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(workspaceBarNeedsRefresh(_:)),
            name: .miriWorkspaceBarNeedsRefresh,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemColorsDidChange(_:)),
            name: NSColor.systemColorsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(permissionsDidChange(_:)),
            name: .miriPermissionsDidChange,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemColorsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared
        )
        if let button = statusItem.button {
            let observer = StatusBarAppearanceObserverView(frame: .zero)
            observer.onAppearanceChange = { [weak self] in
                self?.invalidateWorkspaceBarAppearance()
            }
            button.addSubview(observer)
        }
        refreshWorkspaceBar(force: true)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func configureMenu() {
        statusItem.button?.title = "Miri"
        statusItem.button?.imagePosition = .imageOnly
        menu.delegate = self

        workspaceItem.isEnabled = false
        focusedItem.isEnabled = false
        widthItem.isEnabled = false

        menu.addItem(workspaceItem)
        menu.addItem(focusedItem)
        menu.addItem(widthItem)
        menu.addItem(.separator())
        menu.addItem(permissionItem)
        menu.addItem(permissionSeparator)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Restart Onboarding…", action: #selector(restartOnboarding), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: ""))
        menu.addItem(rescanItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Miri", action: #selector(quitMiri), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }

        statusItem.menu = menu
        refreshPermissionItem()
    }

    func menuWillOpen(_ menu: NSMenu) {
        let state = stateProvider()
        let status = state.status

        if state.onboardingActive {
            workspaceItem.title = "Welcome to Miri"
            focusedItem.title = "Setup is waiting for you"
            widthItem.title = "Window management has not started"
        } else if state.permissions.accessibility == .granted {
            workspaceItem.title = "Workspace: \(status.workspace) of \(status.workspaceCount)"
            focusedItem.title = "Focused: \(status.focusedWindow)"
            widthItem.title = status.widthPercent.map { "Width: \($0)%" } ?? "Width: —"
        } else {
            workspaceItem.title = "Miri Setup"
            focusedItem.title = "Window management is paused"
            widthItem.title = "Accessibility access is required"
        }
        refreshPermissionItem(state.permissions)
        refreshWorkspaceMenuItems()
        refreshWorkspaceBar(force: true)
    }

    private func refreshWorkspaceMenuItems() {
        for item in workspaceMenuItems {
            menu.removeItem(item)
        }
        workspaceMenuItems.removeAll()

        let state = stateProvider()
        guard !state.onboardingActive, state.permissions.accessibility == .granted else { return }
        let barStatus = state.workspaceBar
        guard !barStatus.workspaceSummaries.isEmpty else {
            return
        }

        let header = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
        header.isEnabled = false
        workspaceMenuItems.append(header)
        for workspace in barStatus.workspaceSummaries {
            let marker = workspace.isActive ? "✓ " : "  "
            let apps = workspace.appNames.prefix(4).joined(separator: ", ")
            let suffix = workspace.appNames.count > 4 ? ", +\(workspace.appNames.count - 4)" : ""
            let contents = workspace.appNames.isEmpty ? "Empty" : "\(apps)\(suffix)"
            let item = NSMenuItem(title: "\(marker)Workspace \(workspace.workspace): \(contents)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = workspace.lastFocusedWindow.map { icon(for: $0) }
            workspaceMenuItems.append(item)
        }
        workspaceMenuItems.append(.separator())

        let insertionIndex = min(3, menu.items.count)
        for (offset, item) in workspaceMenuItems.enumerated() {
            menu.insertItem(item, at: insertionIndex + offset)
        }
    }

    @objc private func workspaceBarNeedsRefresh(_ notification: Notification) {
        scheduleWorkspaceBarRefresh()
    }

    @objc private func systemColorsDidChange(_ notification: Notification) {
        invalidateWorkspaceBarAppearance()
    }

    @objc private func permissionsDidChange(_ notification: Notification) {
        refreshPermissionItem()
    }

    private func refreshPermissionItem(_ permissions: MiriPermissionStatus? = nil) {
        let state = stateProvider()
        let permissions = permissions ?? state.permissions
        let snapshotAnimationsConfigured = (state.config.animationStrategy
            ?? MiriConfig.fallback.animationStrategy
            ?? .snapshot) == .snapshot
        if state.onboardingActive {
            permissionItem.title = "Continue Miri Setup…"
            permissionItem.action = #selector(continueOnboarding)
            permissionItem.target = self
            permissionItem.isHidden = false
            permissionSeparator.isHidden = false
            rescanItem.isEnabled = false
            return
        }
        switch permissions.accessibility {
        case .missing:
            permissionItem.title = "Grant Accessibility Access…"
            permissionItem.action = #selector(requestAccessibilityPermission)
            permissionItem.isHidden = false
            permissionSeparator.isHidden = false
            rescanItem.isEnabled = false
        case .restartRequired:
            permissionItem.title = "Restart Miri to Finish Setup"
            permissionItem.action = #selector(restartMiri)
            permissionItem.isHidden = false
            permissionSeparator.isHidden = false
            rescanItem.isEnabled = false
        case .granted:
            if snapshotAnimationsConfigured, permissions.screenRecording == .restartRequired {
                permissionItem.title = "Restart Miri to Enable Animations"
                permissionItem.action = #selector(restartMiri)
                permissionItem.isHidden = false
                permissionSeparator.isHidden = false
            } else {
                permissionItem.isHidden = true
                permissionSeparator.isHidden = true
            }
            rescanItem.isEnabled = true
        }
        permissionItem.target = self
    }

    private func invalidateWorkspaceBarAppearance() {
        lastWorkspaceBarSignature = nil
        scheduleWorkspaceBarRefresh()
    }

    private func scheduleWorkspaceBarRefresh() {
        guard !workspaceBarRefreshScheduled else {
            return
        }
        workspaceBarRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            workspaceBarRefreshScheduled = false
            refreshWorkspaceBar(force: false)
        }
    }

    private func refreshWorkspaceBar(force: Bool) {
        let state = stateProvider()
        let barStatus = state.workspaceBar
        let config = state.config
        let signature = WorkspaceBarRenderSignature(status: barStatus, config: config)
        guard force || signature != lastWorkspaceBarSignature else {
            return
        }
        lastWorkspaceBarSignature = signature
        statusItem.button?.title = ""
        statusItem.button?.image = drawWorkspaceBar(barStatus, config: config)
    }

    private func drawWorkspaceBar(_ status: MiriWorkspaceBarStatus, config: MiriConfig) -> NSImage {
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        var renderedImage: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            renderedImage = renderWorkspaceBar(status, config: config, appearance: appearance)
        }
        return renderedImage ?? NSImage()
    }

    private func renderWorkspaceBar(
        _ status: MiriWorkspaceBarStatus,
        config: MiriConfig,
        appearance: NSAppearance
    ) -> NSImage {
        let maxIcons = config.workspaceBarVisibleIconCount ?? MiriConfig.fallback.workspaceBarVisibleIconCount ?? 3
        let iconSize: CGFloat = 16
        let iconBox: CGFloat = 20
        let iconInset = (iconBox - iconSize) / 2
        let centerStyle = config.workspaceBarCenterStyle ?? MiriConfig.fallback.workspaceBarCenterStyle ?? .delimiter
        let activeStyle = config.workspaceBarActiveStyle ?? MiriConfig.fallback.workspaceBarActiveStyle ?? .braces
        let configuredBorderOutset = CGFloat(config.workspaceBarCenterBorderOutset ?? MiriConfig.fallback.workspaceBarCenterBorderOutset ?? 0)
        let centerBorderOutset = centerStyle == .delimiter ? 0 : configuredBorderOutset
        let activeBorderOutset = activeStyle.hasBorder ? configuredBorderOutset : 0
        let verticalOutset = max(centerBorderOutset, activeBorderOutset)
        let centerBorderThickness = CGFloat(config.workspaceBarCenterBorderThickness ?? MiriConfig.fallback.workspaceBarCenterBorderThickness ?? 1)
        let height: CGFloat = 22 + verticalOutset * 2
        let paddingX: CGFloat = 5
        let textGap: CGFloat = 5
        let font = Self.workspaceLabelFont(weight: .semibold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let useCustomColors = config.workspaceBarUseCustomColors
            ?? MiriConfig.fallback.workspaceBarUseCustomColors
            ?? false
        let systemAccentColor = adaptiveSystemAccentColor(for: appearance)
        let delimiterColor = useCustomColors
            ? highlightColor(config.workspaceBarDelimiterColor ?? MiriConfig.fallback.workspaceBarDelimiterColor)
            : systemAccentColor
        let focusedWindowColor = useCustomColors
            ? highlightColor(config.workspaceBarHighlightColor ?? MiriConfig.fallback.workspaceBarHighlightColor)
            : systemAccentColor
        let separatorAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: delimiterColor,
        ]
        let count = status.windows.count
        let focused = status.focusedIndex.flatMap { count.indicesContains($0) ? $0 : nil }
        let range: Range<Int>
        if let focused, count > 0 {
            let visibleCount = min(maxIcons, count)
            var start = focused - visibleCount / 2
            start = max(0, min(start, count - visibleCount))
            range = start..<(start + visibleCount)
        } else {
            range = 0..<min(maxIcons, count)
        }

        let leftOverflow = range.lowerBound
        let rightOverflow = max(0, count - range.upperBound)
        let allWorkspaceSummaries = status.workspaceSummaries
        let activeSummaryIndex = allWorkspaceSummaries.firstIndex(where: \.isActive) ?? 0
        let workspaceSummaryStart = max(0, min(activeSummaryIndex - 4, max(0, allWorkspaceSummaries.count - 9)))
        let workspaceSummaryEnd = min(allWorkspaceSummaries.count, workspaceSummaryStart + 9)
        let workspaceSummaries = allWorkspaceSummaries[workspaceSummaryStart..<workspaceSummaryEnd]
        let usesDelimiters = centerStyle == .delimiter
        let overflowStyle = config.workspaceBarOverflowStyle ?? MiriConfig.fallback.workspaceBarOverflowStyle ?? .plusCount
        let leftText = overflowText(count: leftOverflow, side: .left, style: overflowStyle)
        let rightText = overflowText(count: rightOverflow, side: .right, style: overflowStyle)
        let showFullscreen = config.workspaceBarShowFullscreen ?? MiriConfig.fallback.workspaceBarShowFullscreen ?? true
        let fullscreenGroups = showFullscreen ? groupedFullscreenWindows(status.fullscreenWindows) : []
        let fullscreenSeparatorText = usesDelimiters && !fullscreenGroups.isEmpty && !workspaceSummaries.isEmpty ? "|" : nil
        let fullscreenMarkerText = fullscreenGroups.isEmpty ? nil : "⛶"

        func textWidth(_ text: String?) -> CGFloat {
            guard let text else { return 0 }
            return ceil((text as NSString).size(withAttributes: textAttrs).width)
        }

        func runWidth(_ run: WorkspaceLabelRun?) -> CGFloat {
            guard let run else { return 0 }
            return ceil((run.text as NSString).size(withAttributes: run.attributes).width)
        }

        func workspaceLabelWidth(_ run: WorkspaceLabelRun, style: WorkspaceBarActiveStyle, isActive: Bool) -> CGFloat {
            let borderPadding: CGFloat = isActive && style.hasBorder ? 4 + configuredBorderOutset : 0
            return runWidth(run) + borderPadding * 2
        }

        let iconCount = CGFloat(range.count)
        let centerPadding: CGFloat = centerStyle == .delimiter ? 0 : 3 + centerBorderOutset
        let centerStripWidth = iconCount * iconBox + (range.isEmpty ? 0 : centerPadding * 2)
        let activeExpansionWidth = (leftText == nil ? 0 : textGap + textWidth(leftText))
            + (range.isEmpty ? 0 : textGap + centerStripWidth)
            + (rightText == nil ? 0 : textGap + textWidth(rightText))
        let workspaceStripWidth = workspaceSummaries.reduce(CGFloat(0)) { total, summary in
            let label = workspaceLabelRun(workspace: summary.workspace, isActive: summary.isActive, style: activeStyle)
            let contentWidth: CGFloat
            if summary.isActive {
                contentWidth = activeExpansionWidth
            } else {
                contentWidth = summary.lastFocusedWindow == nil ? 0 : iconBox
            }
            return total
                + (total == 0 ? 0 : textGap)
                + workspaceLabelWidth(label, style: activeStyle, isActive: summary.isActive)
                + contentWidth
        }
        let fullscreenStripWidth = fullscreenGroups.reduce(CGFloat(0)) { total, group in
            let label = "\(group.workspace)"
            let entryWidth = textWidth(label) + CGFloat(group.windows.count) * iconBox + 2
            return total + (total == 0 ? 0 : textGap) + entryWidth
        }
        let width = paddingX * 2
            + workspaceStripWidth
            + (fullscreenSeparatorText == nil ? 0 : textGap + textWidth(fullscreenSeparatorText))
            + (fullscreenMarkerText == nil ? 0 : textGap + textWidth(fullscreenMarkerText))
            + (fullscreenStripWidth == 0 ? 0 : textGap + fullscreenStripWidth)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.isTemplate = false
        image.lockFocus()
        defer { image.unlockFocus() }

        var x = paddingX
        let yText: CGFloat = 2 + verticalOutset
        let yIcon: CGFloat = (height - iconSize) / 2
        let yIconBox: CGFloat = (height - iconBox) / 2
        var firstWorkspace = true
        for summary in workspaceSummaries {
            if !firstWorkspace { x += textGap }
            firstWorkspace = false
            let label = workspaceLabelRun(workspace: summary.workspace, isActive: summary.isActive, style: activeStyle)
            drawWorkspaceLabel(
                label,
                at: &x,
                yText: yText,
                yIconBox: yIconBox,
                style: activeStyle,
                isActive: summary.isActive,
                borderOutset: configuredBorderOutset,
                borderThickness: centerBorderThickness,
                color: delimiterColor
            )

            if !summary.isActive, let window = summary.lastFocusedWindow {
                icon(for: window).draw(
                    in: NSRect(x: x + iconInset, y: yIcon, width: iconSize, height: iconSize),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                x += iconBox
                continue
            }
            guard summary.isActive else {
                continue
            }

            if let leftText {
                x += textGap
                (leftText as NSString).draw(at: CGPoint(x: x, y: yText), withAttributes: textAttrs)
                x += textWidth(leftText)
            }

            if !range.isEmpty {
                x += textGap
                let centerRect = NSRect(
                    x: x + centerBorderThickness / 2,
                    y: yIconBox - centerBorderOutset + centerBorderThickness / 2,
                    width: centerStripWidth - centerBorderThickness,
                    height: iconBox + centerBorderOutset * 2 - centerBorderThickness
                )
                switch centerStyle {
                case .delimiter:
                    break
                case .border:
                    delimiterColor.withAlphaComponent(0.85).setStroke()
                    let path = NSBezierPath(roundedRect: centerRect, xRadius: 5, yRadius: 5)
                    path.lineWidth = centerBorderThickness
                    path.stroke()
                case .filledBorder:
                    centerFillColor(delimiterColor).setFill()
                    let path = NSBezierPath(roundedRect: centerRect, xRadius: 5, yRadius: 5)
                    path.fill()
                    delimiterColor.withAlphaComponent(0.65).setStroke()
                    path.lineWidth = centerBorderThickness
                    path.stroke()
                }
                x += centerPadding

                for index in range {
                    let window = status.windows[index]
                    let isFocused = index == focused
                    let box = NSRect(x: x, y: yIconBox, width: iconBox, height: iconBox)
                    if isFocused {
                        let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.62 : 0.42
                        focusedWindowColor.withAlphaComponent(alpha).setFill()
                        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
                    }

                    icon(for: window).draw(
                        in: NSRect(x: x + iconInset, y: yIcon, width: iconSize, height: iconSize),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1
                    )
                    x += iconBox
                }
                x += centerPadding
            }

            if let rightText {
                x += textGap
                (rightText as NSString).draw(at: CGPoint(x: x, y: yText), withAttributes: textAttrs)
                x += textWidth(rightText)
            }
        }

        if let fullscreenSeparatorText {
            x += textGap
            (fullscreenSeparatorText as NSString).draw(at: CGPoint(x: x, y: yText), withAttributes: separatorAttrs)
            x += textWidth(fullscreenSeparatorText)
        }

        if let fullscreenMarkerText {
            x += textGap
            (fullscreenMarkerText as NSString).draw(at: CGPoint(x: x, y: yText), withAttributes: textAttrs)
            x += textWidth(fullscreenMarkerText)
        }

        if !fullscreenGroups.isEmpty {
            x += textGap
        }

        var firstFullscreenGroup = true
        for group in fullscreenGroups {
            if !firstFullscreenGroup { x += textGap }
            firstFullscreenGroup = false
            let label = "\(group.workspace)"
            (label as NSString).draw(at: CGPoint(x: x, y: yText), withAttributes: textAttrs)
            x += textWidth(label)
            x += 2
            for window in group.windows {
                icon(for: window).draw(
                    in: NSRect(x: x + iconInset, y: yIcon, width: iconSize, height: iconSize),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                x += iconBox
            }
        }

        return image
    }

    private struct WorkspaceLabelRun {
        let text: String
        let attributes: [NSAttributedString.Key: Any]
    }

    private struct FullscreenWorkspaceGroup {
        let workspace: Int
        var windows: [MiriWorkspaceBarWindow]
    }

    private struct WorkspaceBarRenderSignature: Equatable {
        let status: MiriWorkspaceBarStatus
        let useCustomColors: Bool?
        let highlightColor: String?
        let visibleIconCount: Int?
        let overflowStyle: WorkspaceBarOverflowStyle?
        let showFullscreen: Bool?
        let activeStyle: WorkspaceBarActiveStyle?
        let centerStyle: WorkspaceBarCenterStyle?
        let delimiterColor: String?
        let centerBorderOutset: Int?
        let centerBorderThickness: Int?

        init(status: MiriWorkspaceBarStatus, config: MiriConfig) {
            self.status = status
            useCustomColors = config.workspaceBarUseCustomColors
            highlightColor = config.workspaceBarHighlightColor
            visibleIconCount = config.workspaceBarVisibleIconCount
            overflowStyle = config.workspaceBarOverflowStyle
            showFullscreen = config.workspaceBarShowFullscreen
            activeStyle = config.workspaceBarActiveStyle
            centerStyle = config.workspaceBarCenterStyle
            delimiterColor = config.workspaceBarDelimiterColor
            centerBorderOutset = config.workspaceBarCenterBorderOutset
            centerBorderThickness = config.workspaceBarCenterBorderThickness
        }
    }

    private static func workspaceLabelFont(weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 14, weight: weight)
    }

    private func drawWorkspaceLabel(
        _ run: WorkspaceLabelRun,
        at x: inout CGFloat,
        yText: CGFloat,
        yIconBox: CGFloat,
        style: WorkspaceBarActiveStyle,
        isActive: Bool,
        borderOutset: CGFloat,
        borderThickness: CGFloat,
        color: NSColor
    ) {
        let textWidth = ceil((run.text as NSString).size(withAttributes: run.attributes).width)
        let borderPadding: CGFloat = isActive && style.hasBorder ? 4 + borderOutset : 0
        let labelWidth = textWidth + borderPadding * 2

        if isActive && style.hasBorder {
            let rect = NSRect(
                x: x + borderThickness / 2,
                y: yIconBox - borderOutset + borderThickness / 2,
                width: labelWidth - borderThickness,
                height: 20 + borderOutset * 2 - borderThickness
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            if style == .filledOutline {
                centerFillColor(color).setFill()
                path.fill()
            }
            color.withAlphaComponent(style == .filledOutline ? 0.65 : 0.85).setStroke()
            path.lineWidth = borderThickness
            path.stroke()
        }

        (run.text as NSString).draw(at: CGPoint(x: x + borderPadding, y: yText), withAttributes: run.attributes)
        x += labelWidth
    }

    private func workspaceLabelRun(workspace: Int, isActive: Bool, style: WorkspaceBarActiveStyle) -> WorkspaceLabelRun {
        let baseFont = Self.workspaceLabelFont(weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ]

        guard isActive else {
            return WorkspaceLabelRun(text: "\(workspace)", attributes: attributes)
        }

        switch style {
        case .braces:
            return WorkspaceLabelRun(text: "{\(workspace)}", attributes: attributes)
        case .filledPointer:
            return WorkspaceLabelRun(text: "▶\(workspace)", attributes: attributes)
        case .filledDot:
            return WorkspaceLabelRun(text: "●\(workspace)", attributes: attributes)
        case .squareBrackets:
            return WorkspaceLabelRun(text: "[\(workspace)]", attributes: attributes)
        case .angleBrackets:
            return WorkspaceLabelRun(text: "<\(workspace)>", attributes: attributes)
        case .outline, .filledOutline:
            return WorkspaceLabelRun(text: "\(workspace)", attributes: attributes)
        }
    }

    private func groupedFullscreenWindows(_ windows: [MiriWorkspaceBarFullscreenWindow]) -> [FullscreenWorkspaceGroup] {
        var groups: [FullscreenWorkspaceGroup] = []
        for fullscreen in windows {
            if let index = groups.firstIndex(where: { $0.workspace == fullscreen.workspace }) {
                groups[index].windows.append(fullscreen.window)
            } else {
                groups.append(FullscreenWorkspaceGroup(workspace: fullscreen.workspace, windows: [fullscreen.window]))
            }
        }
        return groups
    }

    private enum OverflowSide {
        case left
        case right
    }

    private func overflowText(count: Int, side: OverflowSide, style: WorkspaceBarOverflowStyle) -> String? {
        guard count > 0 else { return nil }
        switch style {
        case .plusCount:
            return "+\(count)"
        case .dotsCount:
            return "…\(count)"
        case .chevron:
            return side == .left ? "‹" : "›"
        case .none:
            return nil
        }
    }

    private func highlightColor(_ name: String?) -> NSColor {
        switch name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "green": return .systemGreen
        case "mint": return .systemMint
        case "teal": return .systemTeal
        case "cyan": return .systemCyan
        case "blue": return .systemBlue
        case "indigo": return .systemIndigo
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "gray", "grey": return .systemGray
        case let hex? where hex.hasPrefix("#"):
            return colorFromHex(hex) ?? .systemYellow
        default:
            return .systemYellow
        }
    }

    private func adaptiveSystemAccentColor(for appearance: NSAppearance) -> NSColor {
        guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else {
            return NSColor.controlAccentColor
        }

        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let targetLuminance: CGFloat = isDark ? 0.52 : 0.24
        let accentLuminance = relativeLuminance(of: accent)
        if isDark ? accentLuminance >= targetLuminance : accentLuminance <= targetLuminance {
            return accent
        }

        let fallbackEndpoint = isDark ? NSColor.white : NSColor.black
        let endpoint = NSColor.labelColor.usingColorSpace(.sRGB)
            ?? fallbackEndpoint.usingColorSpace(.sRGB)
            ?? fallbackEndpoint
        var lowerFraction: CGFloat = 0
        var upperFraction: CGFloat = 1

        for _ in 0..<12 {
            let fraction = (lowerFraction + upperFraction) / 2
            guard let candidate = accent.blended(withFraction: fraction, of: endpoint)?.usingColorSpace(.sRGB) else {
                break
            }
            let candidateLuminance = relativeLuminance(of: candidate)
            let reachedTarget = isDark
                ? candidateLuminance >= targetLuminance
                : candidateLuminance <= targetLuminance
            if reachedTarget {
                upperFraction = fraction
            } else {
                lowerFraction = fraction
            }
        }

        return accent.blended(withFraction: upperFraction, of: endpoint) ?? accent
    }

    private func relativeLuminance(of color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            return 0
        }

        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearized(rgb.redComponent)
            + 0.7152 * linearized(rgb.greenComponent)
            + 0.0722 * linearized(rgb.blueComponent)
    }

    private func centerFillColor(_ color: NSColor) -> NSColor {
        let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.32 : 0.18
        return color.withAlphaComponent(alpha)
    }

    private func colorFromHex(_ hex: String) -> NSColor? {
        let trimmed = String(hex.dropFirst())
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xff) / 255
        let g = CGFloat((value >> 8) & 0xff) / 255
        let b = CGFloat(value & 0xff) / 255
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }

    private func icon(for window: MiriWorkspaceBarWindow) -> NSImage {
        guard let bundleID = window.bundleID, !bundleID.isEmpty else {
            return fallbackIcon
        }
        if let cached = iconCache[bundleID] {
            return cached
        }

        let icon: NSImage
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let appIcon = app.icon
        {
            icon = appIcon
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = fallbackIcon
        }
        iconCache[bundleID] = icon
        return icon
    }

    @objc private func openSettings() {
        actionSink(.showSettings)
    }

    @objc private func continueOnboarding() {
        actionSink(.showSettings)
    }

    @objc private func requestAccessibilityPermission() {
        actionSink(.requestAccessibilityPermission)
    }

    @objc private func restartMiri() {
        actionSink(.restart)
    }

    @objc private func restartOnboarding() {
        let alert = NSAlert()
        alert.messageText = "Restart onboarding?"
        alert.informativeText = "Miri will restart, pause window management, and begin setup again using your current configuration as the starting point. Any unsaved Settings changes will be lost."
        alert.addButton(withTitle: "Restart Onboarding")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        actionSink(.restartOnboarding)
    }

    @objc private func openConfig() {
        actionSink(.openConfig)
    }

    @objc private func reloadConfig() {
        actionSink(.reloadConfig)
    }

    @objc private func rescanWindows() {
        actionSink(.rescanWindows)
    }

    @objc private func quitMiri() {
        actionSink(.quit)
    }
}

@MainActor
private final class StatusBarAppearanceObserverView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

private extension Int {
    func indicesContains(_ index: Int) -> Bool {
        index >= 0 && index < self
    }
}

private extension WorkspaceBarActiveStyle {
    var hasBorder: Bool {
        self == .outline || self == .filledOutline
    }
}
