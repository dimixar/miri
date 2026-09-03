import AppKit
import QuartzCore

private enum SettingsCategory: Int, CaseIterable {
    case general
    case layout
    case animations
    case workspaceBar
    case shortcuts
    case rules
    case advanced

    var title: String {
        switch self {
        case .general: "General"
        case .layout: "Layout"
        case .animations: "Animations"
        case .workspaceBar: "Workspace Bar"
        case .shortcuts: "Shortcuts"
        case .rules: "Window Rules"
        case .advanced: "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Permissions and everyday behavior."
        case .layout: "Choose how windows, columns, and workspaces are arranged."
        case .animations: "Control movement style and snapshot performance."
        case .workspaceBar: "Tune the menu bar workspace indicator."
        case .shortcuts: "Configure global keyboard control."
        case .rules: "Choose how specific apps and windows are managed."
        case .advanced: "Recovery, reconciliation, and diagnostic settings."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .layout: "rectangle.3.group.fill"
        case .animations: "sparkles"
        case .workspaceBar: "menubar.rectangle"
        case .shortcuts: "keyboard.fill"
        case .rules: "list.bullet.rectangle"
        case .advanced: "wrench.and.screwdriver.fill"
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private typealias SettingsRow = (title: String, detail: String?, control: NSView)

    private let actionSink: (UIAction) -> Void
    private var sourceConfig: MiriConfig
    private var draft: MiriConfig
    private var availableApps: [RuleAppInfo]
    private var permissions: MiriPermissionStatus
    private var selectedCategory: SettingsCategory = .general
    private var pages: [SettingsCategory: NSView] = [:]
    private var currentPage: NSView?
    private var isDirty = false
    private var selectedAnimationStrategy: AnimationStrategy

    private let sidebarTable = NSTableView()
    private let pageHost = NSView()
    private let pageIcon = NSImageView()
    private let pageTitleLabel = NSTextField(labelWithString: "")
    private let pageSubtitleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let rulesTable = NSTableView()
    private let activeRescanBundleTable = NSTableView()
    private var layoutChoiceButtons: [MiriSettingsChoiceButton] = []
    private var animationChoiceButtons: [MiriSettingsChoiceButton] = []
    private weak var animationPreviewHost: NSView?
    private weak var ruleTitleMatchHelpLabel: NSTextField?
    private weak var keyboardShortcutBackendHelpLabel: NSTextField?
    private weak var workspaceBarCustomColorControls: NSView?
    private weak var animationAdvancedControls: NSView?
    private weak var animationPermissionView: NSView?
    private weak var animationPermissionStatusLabel: NSTextField?
    private weak var animationPermissionButton: NSButton?
    private weak var accessibilityStatusLabel: NSTextField?
    private weak var accessibilityPermissionButton: NSButton?
    private weak var generalScreenRecordingStatusLabel: NSTextField?
    private weak var generalScreenRecordingButton: NSButton?
    private weak var duplicateRuleButton: NSButton?
    private weak var moveRuleUpButton: NSButton?
    private weak var moveRuleDownButton: NSButton?
    private weak var deleteRuleButton: NSButton?
    private weak var deleteActiveRescanButton: NSButton?

    private var controls: [String: NSControl] = [:]

    init(
        config: MiriConfig,
        availableApps: [RuleAppInfo],
        permissions: MiriPermissionStatus,
        actionSink: @escaping (UIAction) -> Void
    ) {
        self.actionSink = actionSink
        self.sourceConfig = config
        self.draft = config
        self.availableApps = availableApps
        self.permissions = permissions
        self.selectedAnimationStrategy = config.animationStrategy
            ?? MiriConfig.fallback.animationStrategy
            ?? .snapshot

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Miri Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 840, height: 600)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("MiriSettingsWindow")
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        let wasVisible = window?.isVisible == true
        super.showWindow(sender)
        guard !wasVisible, let window else { return }
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func refresh(config: MiriConfig, availableApps: [RuleAppInfo], permissions: MiriPermissionStatus) {
        sourceConfig = config
        draft = config
        self.availableApps = availableApps
        self.permissions = permissions
        selectedAnimationStrategy = config.animationStrategy
            ?? MiriConfig.fallback.animationStrategy
            ?? .snapshot
        rebuildPages()
        setDirty(false)
    }

    func updatePermissions(_ permissions: MiriPermissionStatus) {
        self.permissions = permissions
        updatePermissionUI()
        updateAnimationPermissionUI()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !isDirty || confirmDiscardChanges()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let backdrop = MiriBackdropView(animated: false)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backdrop)

        let card = NSVisualEffectView()
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 24
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(sidebar)

        let brandIcon = NSImageView(image: NSImage(systemSymbolName: "rectangle.3.group.fill", accessibilityDescription: nil) ?? NSImage())
        brandIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 25, weight: .semibold)
        brandIcon.contentTintColor = MiriVisualStyle.orange
        brandIcon.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(brandIcon)

        let brandTitle = NSTextField(labelWithString: "Miri")
        brandTitle.font = .systemFont(ofSize: 20, weight: .bold)
        brandTitle.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(brandTitle)

        let brandSubtitle = NSTextField(labelWithString: "Settings")
        brandSubtitle.font = .systemFont(ofSize: 11, weight: .medium)
        brandSubtitle.textColor = .secondaryLabelColor
        brandSubtitle.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(brandSubtitle)

        sidebarTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category")))
        sidebarTable.headerView = nil
        sidebarTable.backgroundColor = .clear
        sidebarTable.style = .sourceList
        sidebarTable.rowHeight = 38
        sidebarTable.dataSource = self
        sidebarTable.delegate = self
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebarTable
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = false
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarScroll)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(divider)

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 13
        header.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(header)

        pageIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .medium)
        pageIcon.contentTintColor = MiriVisualStyle.orange
        pageIcon.widthAnchor.constraint(equalToConstant: 34).isActive = true
        header.addArrangedSubview(pageIcon)

        let heading = NSStackView()
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3
        pageTitleLabel.font = .systemFont(ofSize: 25, weight: .bold)
        pageSubtitleLabel.font = .systemFont(ofSize: 13)
        pageSubtitleLabel.textColor = .secondaryLabelColor
        heading.addArrangedSubview(pageTitleLabel)
        heading.addArrangedSubview(pageSubtitleLabel)
        header.addArrangedSubview(heading)

        pageHost.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(pageHost)

        let footerDivider = NSBox()
        footerDivider.boxType = .separator
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(footerDivider)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 9
        footer.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(footer)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(statusLabel)
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(footerSpacer)

        revertButton.target = self
        revertButton.action = #selector(revertChanges)
        footer.addArrangedSubview(revertButton)
        footer.addArrangedSubview(button("Cancel", #selector(cancel)))
        applyButton.target = self
        applyButton.action = #selector(apply)
        footer.addArrangedSubview(applyButton)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]
        MiriVisualStyle.stylePrimaryButton(saveButton)
        saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
        footer.addArrangedSubview(saveButton)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 36),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),

            sidebar.topAnchor.constraint(equalTo: card.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 205),

            brandIcon.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 20),
            brandIcon.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
            brandIcon.widthAnchor.constraint(equalToConstant: 31),
            brandIcon.heightAnchor.constraint(equalToConstant: 31),
            brandTitle.topAnchor.constraint(equalTo: brandIcon.topAnchor, constant: -1),
            brandTitle.leadingAnchor.constraint(equalTo: brandIcon.trailingAnchor, constant: 10),
            brandSubtitle.topAnchor.constraint(equalTo: brandTitle.bottomAnchor, constant: 3),
            brandSubtitle.leadingAnchor.constraint(equalTo: brandTitle.leadingAnchor),
            sidebarScroll.topAnchor.constraint(equalTo: brandSubtitle.bottomAnchor, constant: 26),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18),

            divider.topAnchor.constraint(equalTo: card.topAnchor),
            divider.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            header.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),

            pageHost.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 19),
            pageHost.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 20),
            pageHost.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            pageHost.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -12),

            footerDivider.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),

            footer.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 28),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            footer.heightAnchor.constraint(equalToConstant: 32),
        ])

        rebuildPages()
        sidebarTable.reloadData()
        sidebarTable.selectRowIndexes(IndexSet(integer: selectedCategory.rawValue), byExtendingSelection: false)
        setDirty(false)
    }

    private func rebuildPages() {
        controls.removeAll()
        layoutChoiceButtons.removeAll()
        animationChoiceButtons.removeAll()
        pages = [
            .general: generalView(),
            .layout: layoutView(),
            .animations: animationsView(),
            .workspaceBar: workspaceBarView(),
            .shortcuts: keybindingsView(),
            .rules: rulesView(),
            .advanced: reliabilityView(),
        ]
        showPage(selectedCategory)
        updatePermissionUI()
        updateAnimationPermissionUI()
    }

    private func showPage(_ category: SettingsCategory) {
        selectedCategory = category
        pageTitleLabel.stringValue = category.title
        pageSubtitleLabel.stringValue = category.subtitle
        pageIcon.image = NSImage(systemSymbolName: category.symbol, accessibilityDescription: nil)
        currentPage?.removeFromSuperview()
        guard let page = pages[category] else { return }
        page.translatesAutoresizingMaskIntoConstraints = false
        pageHost.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: pageHost.topAnchor),
            page.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor),
        ])
        currentPage = page
    }

    private func settingsPage(_ sections: [NSView]) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 24, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        for section in sections {
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }

        scroll.documentView = document
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.widthAnchor.constraint(equalTo: document.widthAnchor),
        ])
        return scroll
    }

    private func sectionView(title: String, detail: String? = nil, rows: [SettingsRow]) -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        section.addArrangedSubview(titleLabel)
        if let detail {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 12)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.maximumNumberOfLines = 3
            section.addArrangedSubview(detailLabel)
        }

        let panel = MiriVisualStyle.insetPanel()
        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(rowsStack)

        for (index, item) in rows.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 20
            row.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

            let labels = NSStackView()
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 5
            let label = NSTextField(labelWithString: item.title)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            labels.addArrangedSubview(label)
            if let detail = item.detail {
                let note = NSTextField(wrappingLabelWithString: detail)
                note.font = .systemFont(ofSize: 11)
                note.textColor = .secondaryLabelColor
                note.maximumNumberOfLines = 3
                labels.addArrangedSubview(note)
            }
            row.addArrangedSubview(labels)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
            item.control.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(item.control)
            rowsStack.addArrangedSubview(row)

            if index < rows.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                rowsStack.addArrangedSubview(separator)
                separator.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor, constant: 20).isActive = true
                separator.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor, constant: -20).isActive = true
            }
        }

        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: panel.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        section.addArrangedSubview(panel)
        panel.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func customSection(title: String, detail: String? = nil, content: NSView) -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        section.addArrangedSubview(titleLabel)
        if let detail {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 12)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.maximumNumberOfLines = 3
            section.addArrangedSubview(detailLabel)
        }
        section.addArrangedSubview(content)
        content.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func generalView() -> NSView {
        settingsPage([
            sectionView(
                title: "Permissions",
                detail: "Miri checks access in place, just like onboarding.",
                rows: [
                    (
                        "Accessibility",
                        "Required to discover, focus, move, and resize windows.",
                        permissionControl(for: .accessibility)
                    ),
                    (
                        "Screen Recording",
                        "Used only to capture temporary window images for snapshot animations.",
                        permissionControl(for: .screenRecording)
                    ),
                ]
            ),
            sectionView(
                title: "Window state",
                rows: [
                    (
                        "Restore windows on quit",
                        "Return managed windows to their original frames when Miri exits normally.",
                        checkbox("restoreOnExit", draft.restoreOnExit ?? MiriConfig.fallback.restoreOnExit ?? true)
                    ),
                    (
                        "Persist layout",
                        "Remember workspaces, column positions, widths, and focus between launches.",
                        checkbox("persistLayout", draft.persistLayout ?? MiriConfig.fallback.persistLayout ?? true)
                    ),
                ]
            ),
        ])
    }

    private enum PermissionKind {
        case accessibility
        case screenRecording
    }

    private func permissionControl(for kind: PermissionKind) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 5
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(label)
        let action: Selector = kind == .accessibility
            ? #selector(requestAccessibilityPermission)
            : #selector(generalScreenRecordingButtonClicked)
        let button = self.button("", action)
        stack.addArrangedSubview(button)
        switch kind {
        case .accessibility:
            accessibilityStatusLabel = label
            accessibilityPermissionButton = button
        case .screenRecording:
            generalScreenRecordingStatusLabel = label
            generalScreenRecordingButton = button
        }
        return stack
    }

    private func updatePermissionUI() {
        updatePermissionLabel(
            accessibilityStatusLabel,
            button: accessibilityPermissionButton,
            state: permissions.accessibility,
            missingTitle: "Grant Access…"
        )
        updatePermissionLabel(
            generalScreenRecordingStatusLabel,
            button: generalScreenRecordingButton,
            state: permissions.screenRecording,
            missingTitle: "Grant Access…"
        )
        if permissions.screenRecording == .restartRequired {
            generalScreenRecordingButton?.title = "Save & Restart Miri"
            generalScreenRecordingButton?.isHidden = false
        }
    }

    private func updatePermissionLabel(
        _ label: NSTextField?,
        button: NSButton?,
        state: MiriPermissionState,
        missingTitle: String
    ) {
        switch state {
        case .missing:
            label?.stringValue = "Access needed"
            label?.textColor = MiriVisualStyle.yellow
            button?.title = missingTitle
            button?.isHidden = false
        case .restartRequired:
            label?.stringValue = "Granted · restart required"
            label?.textColor = MiriVisualStyle.green
            button?.isHidden = true
        case .granted:
            label?.stringValue = "Access granted"
            label?.textColor = MiriVisualStyle.green
            button?.isHidden = true
        }
    }

    @objc private func requestAccessibilityPermission() {
        actionSink(.requestAccessibilityPermission)
    }

    @objc private func generalScreenRecordingButtonClicked() {
        switch permissions.screenRecording {
        case .missing:
            actionSink(.requestScreenRecordingPermission)
        case .restartRequired:
            guard prepareDraftForSubmission() else { return }
            actionSink(.saveConfigAndRestart(draft))
        case .granted:
            break
        }
    }

    private func layoutView() -> NSView {
        settingsPage([
            customSection(
                title: "Focus alignment",
                detail: "The same layout choices shown during onboarding.",
                content: layoutChoiceControl()
            ),
            sectionView(
                title: "Column sizing",
                rows: [
                    ("Default width", "Fraction of the usable display width.", doubleField("defaultWidthRatio", Double(draft.defaultWidthRatio))),
                    ("Width presets", "Comma-separated ratios used by width cycling shortcuts.", textField("presetWidthRatios", (draft.presetWidthRatios ?? []).map { String(format: "%.2f", Double($0)) }.joined(separator: ", "))),
                    ("Resize behavior", nil, popup("widthResizeMode", [("Standard", "default"), ("Intelligent", "intelligent")], draft.widthResizeMode?.rawValue ?? MiriConfig.fallback.widthResizeMode?.rawValue ?? "default")),
                    ("New windows", "Where a newly managed column enters the layout.", popup("newWindowPosition", [("Before active window", "before_active"), ("After active window", "after_active"), ("At the end", "end")], draft.newWindowPosition?.rawValue ?? "after_active")),
                ]
            ),
            sectionView(
                title: "Spacing and workspaces",
                rows: [
                    ("Pre-created workspaces", "Always keep this many numbered workspaces available.", slider("minimumWorkspaceCount", draft.minimumWorkspaceCount ?? MiriConfig.fallback.minimumWorkspaceCount ?? 1, min: 1, max: 9)),
                    ("Back-and-forth switching", "Selecting the active workspace returns to the previous one.", checkbox("workspaceAutoBackAndForth", draft.workspaceAutoBackAndForth ?? MiriConfig.fallback.workspaceAutoBackAndForth ?? false)),
                    ("Inner gap", "Physical pixels between adjacent columns.", pointsField("innerGap", Double(draft.innerGap ?? 0), suffix: "px")),
                    ("Outer gap", "Physical pixels between windows and the usable display edge.", pointsField("outerGap", Double(draft.outerGap ?? 0), suffix: "px")),
                    ("Parked sliver", "Visible edge retained while windows are staged off-screen.", pointsField("parkedSliverWidth", Double(draft.parkedSliverWidth ?? 1), suffix: "px")),
                ]
            ),
        ])
    }

    private func layoutChoiceControl() -> NSView {
        let choices = NSStackView()
        choices.orientation = .horizontal
        choices.distribution = .fillEqually
        choices.spacing = 10
        let selected = draft.focusAlignment ?? MiriConfig.fallback.focusAlignment ?? .default
        let details: [FocusAlignment: String] = [
            .default: "Reveals the focused window with minimal movement.",
            .centered: "Keeps the focused window centered.",
            .centeredSmart: "Centers wide windows and gently reveals narrow ones.",
        ]
        for (index, option) in FocusAlignment.guiOptions.enumerated() {
            let preview = LayoutPreviewView(alignment: option.alignment)
            preview.widthAnchor.constraint(equalToConstant: 138).isActive = true
            preview.heightAnchor.constraint(equalToConstant: 62).isActive = true
            let choice = MiriSettingsChoiceButton(
                title: option.title,
                detail: details[option.alignment] ?? "",
                topView: preview,
                selected: selected == option.alignment,
                target: self,
                action: #selector(selectSettingsLayout(_:))
            )
            choice.tag = index
            choices.addArrangedSubview(choice)
            layoutChoiceButtons.append(choice)
        }
        return choices
    }

    @objc private func selectSettingsLayout(_ sender: NSButton) {
        guard FocusAlignment.guiOptions.indices.contains(sender.tag) else { return }
        draft.focusAlignment = FocusAlignment.guiOptions[sender.tag].alignment
        for (index, button) in layoutChoiceButtons.enumerated() {
            button.setSelected(index == sender.tag)
        }
        markDirty()
    }

    private func animationsView() -> NSView {
        let animationChoices = animationChoiceControl()
        let performance = sectionView(
            title: "Snapshot performance",
            detail: "These controls apply only to Smooth snapshots.",
            rows: [
                ("Movement speed", nil, slider("snapshotAnimationSpeed", draft.snapshotAnimationSpeed ?? MiriConfig.fallback.snapshotAnimationSpeed ?? 50, min: 1, max: 100)),
                ("Frame rate", "Manual snapshot runner frame rate.", intField("animationFPS", draft.animationFPS ?? 60)),
                ("Pixel threshold", "Distance at which a snapshot snaps to its final position.", doubleField("animationPixelThreshold", Double(draft.animationPixelThreshold ?? 0.5))),
            ]
        )
        animationAdvancedControls = performance
        return settingsPage([
            customSection(
                title: "Transition style",
                detail: "Choose immediate updates or compositor-backed movement.",
                content: animationChoices
            ),
            sectionView(
                title: "Screen Recording",
                rows: [
                    ("Permission status", "No images are recorded, stored, or transmitted.", animationPermissionControls()),
                ]
            ),
            performance,
        ])
    }

    private func animationChoiceControl() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10

        let previewHost = MiriVisualStyle.insetPanel()
        previewHost.translatesAutoresizingMaskIntoConstraints = false
        previewHost.heightAnchor.constraint(equalToConstant: 96).isActive = true
        root.addArrangedSubview(previewHost)
        animationPreviewHost = previewHost
        installAnimationPreview()

        let choices = NSStackView()
        choices.orientation = .horizontal
        choices.distribution = .fillEqually
        choices.spacing = 10
        let options: [(AnimationStrategy, String, String, String)] = [
            (.off, "Instant", "bolt.fill", "Apply every focus and layout change immediately."),
            (.snapshot, "Smooth snapshots", "sparkles", "Animate temporary window images between focus states."),
        ]
        for (index, option) in options.enumerated() {
            let choice = MiriSettingsChoiceButton(
                title: option.1,
                detail: option.3,
                symbolName: option.2,
                selected: selectedAnimationStrategy == option.0,
                target: self,
                action: #selector(selectAnimationStrategy(_:))
            )
            choice.tag = index
            choices.addArrangedSubview(choice)
            animationChoiceButtons.append(choice)
        }
        root.addArrangedSubview(choices)
        return root
    }

    private func installAnimationPreview() {
        guard let host = animationPreviewHost else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        let preview = AnimationPreviewView(mode: selectedAnimationStrategy == .snapshot)
        preview.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            preview.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 18),
            preview.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -18),
            preview.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8),
        ])
    }

    @objc private func selectAnimationStrategy(_ sender: NSButton) {
        selectedAnimationStrategy = sender.tag == 0 ? .off : .snapshot
        draft.animationStrategy = selectedAnimationStrategy
        for (index, button) in animationChoiceButtons.enumerated() {
            button.setSelected(index == sender.tag)
        }
        installAnimationPreview()
        updateAnimationPermissionUI()
        markDirty()
    }

    private func animationPermissionControls() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 6

        let statusLabel = helpLabel("")
        statusLabel.alignment = .right
        statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 330).isActive = true
        stack.addArrangedSubview(statusLabel)

        let permissionButton = button("Request Screen Recording Access…", #selector(animationPermissionButtonClicked))
        stack.addArrangedSubview(permissionButton)

        animationPermissionView = stack
        animationPermissionStatusLabel = statusLabel
        animationPermissionButton = permissionButton
        updateAnimationPermissionUI()
        return stack
    }

    @objc private func animationPermissionButtonClicked() {
        switch permissions.screenRecording {
        case .missing:
            actionSink(.requestScreenRecordingPermission)
        case .restartRequired:
            guard prepareDraftForSubmission() else { return }
            actionSink(.saveConfigAndRestart(draft))
        case .granted:
            break
        }
    }

    private func updateAnimationPermissionUI() {
        guard let permissionView = animationPermissionView,
              let statusLabel = animationPermissionStatusLabel,
              let permissionButton = animationPermissionButton
        else { return }

        let snapshotSelected = selectedAnimationStrategy == .snapshot
        permissionView.isHidden = false
        animationAdvancedControls?.alphaValue = snapshotSelected ? 1 : 0.48
        guard snapshotSelected else {
            statusLabel.stringValue = "No additional permission is needed for Instant mode."
            statusLabel.textColor = .secondaryLabelColor
            permissionButton.isHidden = true
            return
        }

        switch permissions.screenRecording {
        case .missing:
            statusLabel.stringValue = "Access is needed before snapshot animations can run."
            statusLabel.textColor = MiriVisualStyle.yellow
            permissionButton.title = "Grant Screen Recording Access…"
            permissionButton.isHidden = false
        case .restartRequired:
            statusLabel.stringValue = "Access granted · restart required"
            statusLabel.textColor = MiriVisualStyle.green
            permissionButton.title = "Save & Restart Miri"
            permissionButton.isHidden = false
        case .granted:
            statusLabel.stringValue = "Screen Recording access is granted."
            statusLabel.textColor = MiriVisualStyle.green
            permissionButton.isHidden = true
        }
    }

    private func workspaceBarView() -> NSView {
        settingsPage([
            sectionView(
                title: "Content",
                rows: [
                    ("Show fullscreen apps", "Include remembered native-fullscreen applications.", checkbox("workspaceBarShowFullscreen", draft.workspaceBarShowFullscreen ?? MiriConfig.fallback.workspaceBarShowFullscreen ?? true)),
                    ("Visible app icons", "Maximum app icons shown for each workspace.", slider("workspaceBarVisibleIconCount", draft.workspaceBarVisibleIconCount ?? MiriConfig.fallback.workspaceBarVisibleIconCount ?? 3, min: 1, max: 6)),
                    ("Overflow indicator", nil, popup("workspaceBarOverflowStyle", [("Plus and count", "plus_count"), ("Dots and count", "dots_count"), ("Chevron", "chevron"), ("None", "none")], draft.workspaceBarOverflowStyle?.rawValue ?? MiriConfig.fallback.workspaceBarOverflowStyle?.rawValue ?? "plus_count")),
                ]
            ),
            sectionView(
                title: "Appearance",
                rows: [
                    ("Active workspace", "Visual treatment for the current workspace.", popup("workspaceBarActiveStyle", [("Braces", "braces"), ("Filled pointer", "filled_pointer"), ("Filled dot", "filled_dot"), ("Square brackets", "square_brackets"), ("Angle brackets", "angle_brackets"), ("Outline", "outline"), ("Filled outline", "filled_outline")], draft.workspaceBarActiveStyle?.rawValue ?? MiriConfig.fallback.workspaceBarActiveStyle?.rawValue ?? "braces")),
                    ("Center app strip", nil, popup("workspaceBarCenterStyle", [("Delimiter", "delimiter"), ("Border", "border"), ("Filled border", "filled_border")], draft.workspaceBarCenterStyle?.rawValue ?? MiriConfig.fallback.workspaceBarCenterStyle?.rawValue ?? "delimiter")),
                    ("Accent colors", "Use the system accent or choose focused-window and border colors.", workspaceBarColorSettings()),
                    ("Center border outset", nil, slider("workspaceBarCenterBorderOutset", draft.workspaceBarCenterBorderOutset ?? MiriConfig.fallback.workspaceBarCenterBorderOutset ?? 0, min: 0, max: 5)),
                    ("Center border thickness", nil, slider("workspaceBarCenterBorderThickness", draft.workspaceBarCenterBorderThickness ?? MiriConfig.fallback.workspaceBarCenterBorderThickness ?? 1, min: 1, max: 3)),
                ]
            ),
        ])
    }

    private func workspaceBarColorSettings() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let useCustomColors = draft.workspaceBarUseCustomColors
            ?? MiriConfig.fallback.workspaceBarUseCustomColors
            ?? false
        let toggle = NSButton(
            checkboxWithTitle: "Use custom colors",
            target: self,
            action: #selector(workspaceBarCustomColorsChanged(_:))
        )
        toggle.state = useCustomColors ? .on : .off
        controls["workspaceBarUseCustomColors"] = toggle
        stack.addArrangedSubview(toggle)

        let customControls = NSStackView()
        customControls.orientation = .vertical
        customControls.alignment = .leading
        customControls.spacing = 6
        customControls.addArrangedSubview(colorSettingRow(
            "Focused window",
            colorWell(
                "workspaceBarHighlightColor",
                draft.workspaceBarHighlightColor ?? MiriConfig.fallback.workspaceBarHighlightColor ?? "#FFD60A"
            )
        ))
        customControls.addArrangedSubview(colorSettingRow(
            "Borders and delimiters",
            colorWell(
                "workspaceBarDelimiterColor",
                draft.workspaceBarDelimiterColor ?? MiriConfig.fallback.workspaceBarDelimiterColor ?? "#FFD60A"
            )
        ))
        customControls.isHidden = !useCustomColors
        stack.addArrangedSubview(customControls)
        workspaceBarCustomColorControls = customControls
        return stack
    }

    private func colorSettingRow(_ title: String, _ colorWell: NSColorWell) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 145).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(colorWell)
        return row
    }

    @objc private func workspaceBarCustomColorsChanged(_ sender: NSButton) {
        workspaceBarCustomColorControls?.isHidden = sender.state != .on
        markDirty()
    }

    private func keybindingsView() -> NSView {
        let keybindings = draft.keybindings ?? MiriConfig.defaultKeybindings
        let commands = MiriConfig.defaultKeybindings.keys.sorted()
        let groups: [(String, String, (String) -> Bool)] = [
            ("Workspace navigation", "Focus and move between Miri workspaces.", { $0.contains("workspace") && !$0.hasPrefix("move_column") }),
            ("Column navigation", "Move focus within the current workspace.", { $0.hasPrefix("column_") }),
            ("Move columns", "Reorder columns or send them to another workspace.", { $0.hasPrefix("move_column") }),
            ("Resize columns", "Cycle presets or nudge one or every column.", { $0.contains("width") }),
        ]

        var sections: [NSView] = [
            sectionView(
                title: "Shortcut handling",
                rows: [
                    ("Input backend", nil, keyboardShortcutControls()),
                    ("Excluded shortcuts", "Comma-separated shortcuts that always pass through in Full Compatibility mode.", textField("excludedKeybindings", (draft.excludedKeybindings ?? []).joined(separator: ", "))),
                ]
            ),
        ]
        for group in groups {
            let rows: [SettingsRow] = commands.filter(group.2).map { command in
                let bindings = keybindings[command] ?? []
                return (
                    humanizedCommand(command),
                    command,
                    textField("keybinding.\(command)", bindings.joined(separator: ", "))
                )
            }
            sections.append(sectionView(title: group.0, detail: group.1, rows: rows))
        }
        return settingsPage(sections)
    }

    private func keyboardShortcutControls() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 5
        stack.addArrangedSubview(keyboardShortcutBackendPopup())
        let help = keyboardShortcutBackendHelp()
        help.alignment = .right
        help.widthAnchor.constraint(equalToConstant: 300).isActive = true
        stack.addArrangedSubview(help)
        return stack
    }

    private func humanizedCommand(_ command: String) -> String {
        command.split(separator: "_").map { part in
            switch part.lowercased() {
            case "all": "All"
            case "to": "to"
            default: part.prefix(1).uppercased() + part.dropFirst()
            }
        }.joined(separator: " ")
    }

    private func reliabilityView() -> NSView {
        settingsPage([
            sectionView(
                title: "System reconciliation",
                detail: "Conservative recovery controls for missed or delayed macOS events.",
                rows: [
                    ("Safety rescan interval", "Long fallback interval in milliseconds.", intField("windowReconciliationIntervalMS", draft.windowReconciliationIntervalMS ?? MiriConfig.fallback.windowReconciliationIntervalMS ?? 60000)),
                    ("Placeholder probe cooldown", nil, secondsSlider("axCreatedPlaceholderProbeCooldownSeconds", Double(draft.axCreatedPlaceholderProbeCooldownMS ?? MiriConfig.fallback.axCreatedPlaceholderProbeCooldownMS ?? 1000) / 1000, min: 0.0, max: 5.0)),
                    ("Fullscreen transition grace", nil, secondsSlider("likelyFullscreenTransitionGraceSeconds", Double(draft.likelyFullscreenTransitionGraceMS ?? MiriConfig.fallback.likelyFullscreenTransitionGraceMS ?? 1500) / 1000, min: 0.1, max: 2.0)),
                    ("Fullscreen Space guard", nil, secondsSlider("fullscreenSpaceChangeGuardSeconds", Double(draft.fullscreenSpaceChangeGuardMS ?? MiriConfig.fallback.fullscreenSpaceChangeGuardMS ?? 1500) / 1000, min: 0.1, max: 3.0)),
                    ("Logical Space autosave", nil, minutesSlider("logicalSpaceAutosaveIntervalMinutes", draft.logicalSpaceAutosaveIntervalMinutes ?? MiriConfig.fallback.logicalSpaceAutosaveIntervalMinutes ?? 30, min: 1, max: 60)),
                ]
            ),
            sectionView(
                title: "Active rescans",
                detail: "Target apps that miss Accessibility window lifecycle events. This can increase CPU use.",
                rows: [
                    ("Enable active rescans", "Rescan listed tiled apps once per second and after input.", checkbox("activeRescanEnabled", draft.activeRescanEnabled ?? MiriConfig.fallback.activeRescanEnabled ?? false)),
                ]
            ),
            customSection(title: "Target applications", content: activeRescanListView()),
            sectionView(
                title: "Diagnostics",
                rows: [
                    ("Debug logging", "Write detailed logs to ~/.config/miri/debug.log.", checkbox("debugLogging", draft.debugLogging ?? MiriConfig.fallback.debugLogging ?? false)),
                ]
            ),
        ])
    }

    private func activeRescanListView() -> NSView {
        let panel = MiriVisualStyle.insetPanel()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(button("Add Bundle…", #selector(addManualActiveRescanBundle)))
        buttons.addArrangedSubview(button("Add Open App…", #selector(addActiveRescanBundleFromOpenApp)))
        let deleteButton = button("Delete", #selector(deleteActiveRescanBundle))
        deleteActiveRescanButton = deleteButton
        buttons.addArrangedSubview(deleteButton)
        stack.addArrangedSubview(buttons)

        activeRescanBundleTable.dataSource = self
        activeRescanBundleTable.delegate = self
        activeRescanBundleTable.target = self
        activeRescanBundleTable.doubleAction = #selector(editSelectedActiveRescanBundle)
        activeRescanBundleTable.usesAlternatingRowBackgroundColors = true
        activeRescanBundleTable.headerView = nil
        if activeRescanBundleTable.tableColumns.isEmpty {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("activeRescanBundle"))
            column.title = "Bundle Identifier"
            activeRescanBundleTable.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = activeRescanBundleTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        stack.addArrangedSubview(scroll)
        activeRescanBundleTable.reloadData()
        updateActiveRescanButtons()
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        return panel
    }

    private func rulesView() -> NSView {
        let panel = MiriVisualStyle.insetPanel()
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 9
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(root)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(button("Add Rule…", #selector(addManualRule)))
        buttons.addArrangedSubview(button("Add Open App…", #selector(addFromOpenApp)))
        let duplicate = button("Duplicate", #selector(duplicateRule))
        let moveUp = button("Move Up", #selector(moveRuleUp))
        let moveDown = button("Move Down", #selector(moveRuleDown))
        let delete = button("Delete", #selector(deleteRule))
        duplicateRuleButton = duplicate
        moveRuleUpButton = moveUp
        moveRuleDownButton = moveDown
        deleteRuleButton = delete
        buttons.addArrangedSubview(duplicate)
        buttons.addArrangedSubview(moveUp)
        buttons.addArrangedSubview(moveDown)
        buttons.addArrangedSubview(delete)
        root.addArrangedSubview(buttons)

        rulesTable.dataSource = self
        rulesTable.delegate = self
        rulesTable.target = self
        rulesTable.doubleAction = #selector(editSelectedRule)
        rulesTable.usesAlternatingRowBackgroundColors = true
        rulesTable.rowHeight = 30
        if rulesTable.tableColumns.isEmpty {
            let columns: [(String, String, CGFloat)] = [
                ("application", "Application", 155),
                ("match", "Window Match", 180),
                ("behavior", "Behavior", 85),
                ("placement", "Placement", 130),
            ]
            for item in columns {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(item.0))
                column.title = item.1
                column.width = item.2
                rulesTable.addTableColumn(column)
            }
        }
        let scroll = NSScrollView()
        scroll.documentView = rulesTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
        root.addArrangedSubview(scroll)
        rulesTable.reloadData()
        updateRuleButtons()
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: panel.topAnchor),
            root.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        return settingsPage([
            customSection(
                title: "Ordered rules",
                detail: "Rules are evaluated in list order. Double-click a row to edit it.",
                content: panel
            ),
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === sidebarTable {
            return SettingsCategory.allCases.count
        }
        if tableView === rulesTable {
            return draft.rules.count
        }
        if tableView === activeRescanBundleTable {
            return draftActiveRescanBundleIDs().count
        }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sidebarTable {
            guard let category = SettingsCategory(rawValue: row) else { return nil }
            let cell = NSTableCellView()
            let icon = NSImageView(image: NSImage(systemSymbolName: category.symbol, accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            icon.contentTintColor = category == selectedCategory ? MiriVisualStyle.orange : .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            let text = NSTextField(labelWithString: category.title)
            text.font = .systemFont(ofSize: 13, weight: category == selectedCategory ? .semibold : .regular)
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        let label: String
        if tableView === rulesTable {
            guard draft.rules.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
            let rule = draft.rules[row]
            switch identifier {
            case "application":
                label = rule.appName ?? rule.bundleID ?? "Any application"
            case "match":
                if let title = rule.titleContains, !title.isEmpty {
                    label = rule.titleExactMatch == true ? "Title is \(title)" : "Title contains \(title)"
                } else {
                    label = "All windows"
                }
            case "behavior":
                label = (rule.behavior?.rawValue ?? "default").capitalized
            case "placement":
                var parts: [String] = []
                if let width = rule.widthRatio { parts.append("\(Int((width * 100).rounded()))%") }
                if let workspace = rule.workspace { parts.append("Workspace \(workspace)") }
                if let position = rule.openPosition { parts.append(position.guiTitle) }
                label = parts.isEmpty ? "Default" : parts.joined(separator: " · ")
            default:
                label = ruleSummary(rule)
            }
        } else if tableView === activeRescanBundleTable {
            let bundleIDs = draftActiveRescanBundleIDs()
            guard bundleIDs.indices.contains(row) else { return nil }
            label = bundleIDs[row]
        } else {
            return nil
        }
        let text = NSTextField(labelWithString: label)
        text.lineBreakMode = .byTruncatingTail
        return text
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === sidebarTable {
            guard let category = SettingsCategory(rawValue: sidebarTable.selectedRow) else { return }
            showPage(category)
            sidebarTable.reloadData()
        } else if table === rulesTable {
            updateRuleButtons()
        } else if table === activeRescanBundleTable {
            updateActiveRescanButtons()
        }
    }

    private func updateRuleButtons() {
        let row = rulesTable.selectedRow
        let hasSelection = draft.rules.indices.contains(row)
        duplicateRuleButton?.isEnabled = hasSelection
        deleteRuleButton?.isEnabled = hasSelection
        moveRuleUpButton?.isEnabled = hasSelection && row > 0
        moveRuleDownButton?.isEnabled = hasSelection && row < draft.rules.count - 1
    }

    private func updateActiveRescanButtons() {
        deleteActiveRescanButton?.isEnabled = draftActiveRescanBundleIDs().indices.contains(activeRescanBundleTable.selectedRow)
    }

    private func ruleSummary(_ rule: WindowRule) -> String {
        var matchParts: [String] = []
        if let bundleID = rule.bundleID, !bundleID.isEmpty {
            matchParts.append(bundleID)
        }
        if let appName = rule.appName, !appName.isEmpty {
            matchParts.append("app='\(appName)'")
        }
        if let titleContains = rule.titleContains, !titleContains.isEmpty {
            let label = rule.titleExactMatch == true ? "title='\(titleContains)'" : "title contains '\(titleContains)'"
            matchParts.append(label)
        }
        let match = matchParts.isEmpty ? "manual" : matchParts.joined(separator: " · ")

        var detailParts: [String] = [rule.behavior?.rawValue ?? "default"]
        if let widthRatio = rule.widthRatio {
            detailParts.append("width=\(widthRatio)")
        }
        if let workspace = rule.workspace {
            detailParts.append("workspace=\(workspace)")
        }
        if let openPosition = rule.openPosition {
            detailParts.append("open=\(openPosition.rawValue)")
        }
        return "\(match) -> \(detailParts.joined(separator: " · "))"
    }

    private func readControlsIntoDraft() {
        draft.restoreOnExit = bool("restoreOnExit")
        draft.persistLayout = bool("persistLayout")
        draft.keyboardShortcutBackend = KeyboardShortcutBackend(rawValue: string("keyboardShortcutBackend"))
        draft.windowReconciliationIntervalMS = int("windowReconciliationIntervalMS")
        draft.axCreatedPlaceholderProbeCooldownMS = max(0, Int((double("axCreatedPlaceholderProbeCooldownSeconds") * 1000).rounded()))
        draft.likelyFullscreenTransitionGraceMS = Int((double("likelyFullscreenTransitionGraceSeconds") * 1000).rounded())
        draft.fullscreenSpaceChangeGuardMS = Int((double("fullscreenSpaceChangeGuardSeconds") * 1000).rounded())
        draft.logicalSpaceAutosaveIntervalMinutes = max(1, min(int("logicalSpaceAutosaveIntervalMinutes"), 60))
        draft.debugLogging = bool("debugLogging")
        draft.defaultWidthRatio = CGFloat(double("defaultWidthRatio"))
        draft.presetWidthRatios = string("presetWidthRatios").split(separator: ",").compactMap { CGFloat(Double($0.trimmingCharacters(in: .whitespaces)) ?? .nan) }
        draft.widthResizeMode = WidthResizeMode(rawValue: string("widthResizeMode"))
        if let focusAlignmentRawValue = (controls["focusAlignment"] as? NSPopUpButton)?
            .selectedItem?.representedObject as? String
        {
            draft.focusAlignment = FocusAlignment(rawValue: focusAlignmentRawValue)
        }
        draft.newWindowPosition = NewWindowPosition(rawValue: string("newWindowPosition"))
        draft.minimumWorkspaceCount = max(1, min(int("minimumWorkspaceCount"), 9))
        draft.workspaceAutoBackAndForth = bool("workspaceAutoBackAndForth")
        draft.innerGap = CGFloat(double("innerGap"))
        draft.outerGap = CGFloat(double("outerGap"))
        draft.parkedSliverWidth = CGFloat(double("parkedSliverWidth"))
        draft.animationStrategy = selectedAnimationStrategy
        draft.snapshotAnimationSpeed = max(1, min(int("snapshotAnimationSpeed"), 100))
        draft.animationFPS = int("animationFPS")
        draft.animationPixelThreshold = CGFloat(double("animationPixelThreshold"))
        draft.workspaceBarShowFullscreen = bool("workspaceBarShowFullscreen")
        draft.workspaceBarActiveStyle = WorkspaceBarActiveStyle(rawValue: string("workspaceBarActiveStyle"))
        draft.workspaceBarCenterStyle = WorkspaceBarCenterStyle(rawValue: string("workspaceBarCenterStyle"))
        draft.workspaceBarUseCustomColors = bool("workspaceBarUseCustomColors")
        draft.workspaceBarDelimiterColor = colorHex("workspaceBarDelimiterColor")
        draft.workspaceBarCenterBorderOutset = max(0, min(int("workspaceBarCenterBorderOutset"), 5))
        draft.workspaceBarCenterBorderThickness = max(1, min(int("workspaceBarCenterBorderThickness"), 3))
        draft.workspaceBarHighlightColor = colorHex("workspaceBarHighlightColor")
        draft.workspaceBarVisibleIconCount = max(1, min(int("workspaceBarVisibleIconCount"), 6))
        draft.workspaceBarOverflowStyle = WorkspaceBarOverflowStyle(rawValue: string("workspaceBarOverflowStyle"))
        draft.activeRescanEnabled = bool("activeRescanEnabled")
        draft.activeRescanBundleIDs = MiriConfig.normalizeBundleIDs(draft.activeRescanBundleIDs)

        draft.excludedKeybindings = csv("excludedKeybindings")
        var keybindings: [String: [String]] = [:]
        for command in MiriConfig.defaultKeybindings.keys.sorted() {
            keybindings[command] = csv("keybinding.\(command)")
        }
        draft.keybindings = keybindings
    }

    private func validateDraft() -> String? {
        var seen: [String: String] = [:]
        let keybindings = draft.keybindings ?? [:]
        for command in keybindings.keys.sorted() {
            for binding in keybindings[command] ?? [] {
                let normalized = binding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                if let previous = seen[normalized] {
                    return "Keybinding '\(binding)' is assigned to both '\(previous)' and '\(command)'."
                }
                seen[normalized] = command
            }
        }
        return nil
    }

    @objc private func addManualActiveRescanBundle() {
        let bundleID = promptForBundleID(title: "Add Active Rescan Bundle", value: "")
        guard let bundleID else {
            return
        }
        addActiveRescanBundleID(bundleID)
    }

    @objc private func addActiveRescanBundleFromOpenApp() {
        let alert = NSAlert()
        alert.messageText = "Add Active Rescan Bundle"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        popup.addItem(withTitle: "Manual bundle id…")
        for app in availableApps {
            popup.addItem(withTitle: "\(app.appName) — \(app.bundleID)")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if popup.indexOfSelectedItem == 0 {
            addManualActiveRescanBundle()
        } else {
            addActiveRescanBundleID(availableApps[popup.indexOfSelectedItem - 1].bundleID)
        }
    }

    @objc private func editSelectedActiveRescanBundle() {
        let row = activeRescanBundleTable.selectedRow
        var bundleIDs = draftActiveRescanBundleIDs()
        guard bundleIDs.indices.contains(row) else {
            return
        }
        guard let bundleID = promptForBundleID(title: "Edit Active Rescan Bundle", value: bundleIDs[row]) else {
            return
        }
        bundleIDs[row] = bundleID
        setDraftActiveRescanBundleIDs(bundleIDs)
        activeRescanBundleTable.reloadData()
        markDirty()
        if draftActiveRescanBundleIDs().indices.contains(row) {
            activeRescanBundleTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    @objc private func deleteActiveRescanBundle() {
        let row = activeRescanBundleTable.selectedRow
        var bundleIDs = draftActiveRescanBundleIDs()
        guard bundleIDs.indices.contains(row) else {
            return
        }
        bundleIDs.remove(at: row)
        setDraftActiveRescanBundleIDs(bundleIDs)
        activeRescanBundleTable.reloadData()
        markDirty()
    }

    private func addActiveRescanBundleID(_ bundleID: String) {
        var bundleIDs = draftActiveRescanBundleIDs()
        bundleIDs.append(bundleID)
        setDraftActiveRescanBundleIDs(bundleIDs)
        activeRescanBundleTable.reloadData()
        markDirty()
        let row = draftActiveRescanBundleIDs().firstIndex(of: bundleID.trimmingCharacters(in: .whitespacesAndNewlines))
        if let row {
            activeRescanBundleTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func draftActiveRescanBundleIDs() -> [String] {
        draft.activeRescanBundleIDs ?? MiriConfig.fallback.activeRescanBundleIDs ?? []
    }

    private func setDraftActiveRescanBundleIDs(_ bundleIDs: [String]) {
        draft.activeRescanBundleIDs = MiriConfig.normalizeBundleIDs(bundleIDs)
    }

    private func promptForBundleID(title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.widthAnchor.constraint(equalToConstant: 340).isActive = true
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let bundleID = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return bundleID.isEmpty ? nil : bundleID
    }

    @objc private func addManualRule() {
        draft.rules.append(WindowRule(bundleID: "", behavior: .tile))
        let index = draft.rules.count - 1
        if !editRule(at: index) {
            draft.rules.remove(at: index)
        }
        rulesTable.reloadData()
    }

    @objc private func addFromOpenApp() {
        let alert = NSAlert()
        alert.messageText = "Add Rule From Open App"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        popup.addItem(withTitle: "Manual bundle id…")
        for app in availableApps {
            popup.addItem(withTitle: "\(app.appName) — \(app.bundleID)")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if popup.indexOfSelectedItem == 0 {
            draft.rules.append(WindowRule(bundleID: "", behavior: .tile))
        } else {
            let app = availableApps[popup.indexOfSelectedItem - 1]
            draft.rules.append(WindowRule(bundleID: app.bundleID, appName: app.appName, behavior: .tile))
        }
        let index = draft.rules.count - 1
        if !editRule(at: index) {
            draft.rules.remove(at: index)
        }
        rulesTable.reloadData()
    }

    @objc private func editSelectedRule() {
        _ = editRule(at: rulesTable.selectedRow)
    }

    @objc private func duplicateRule() {
        let row = rulesTable.selectedRow
        guard draft.rules.indices.contains(row) else { return }
        draft.rules.insert(draft.rules[row], at: row + 1)
        rulesTable.reloadData()
        markDirty()
        rulesTable.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
    }

    @objc private func moveRuleUp() {
        let row = rulesTable.selectedRow
        guard draft.rules.indices.contains(row), row > 0 else { return }
        draft.rules.swapAt(row, row - 1)
        rulesTable.reloadData()
        markDirty()
        rulesTable.selectRowIndexes(IndexSet(integer: row - 1), byExtendingSelection: false)
    }

    @objc private func moveRuleDown() {
        let row = rulesTable.selectedRow
        guard draft.rules.indices.contains(row), row < draft.rules.count - 1 else { return }
        draft.rules.swapAt(row, row + 1)
        rulesTable.reloadData()
        markDirty()
        rulesTable.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
    }

    @objc private func deleteRule() {
        let row = rulesTable.selectedRow
        guard draft.rules.indices.contains(row) else { return }
        draft.rules.remove(at: row)
        rulesTable.reloadData()
        markDirty()
    }

    private func editRule(at index: Int) -> Bool {
        guard draft.rules.indices.contains(index) else { return false }
        var rule = draft.rules[index]
        let alert = NSAlert()
        alert.messageText = "Edit Rule"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let bundle = NSTextField(string: rule.bundleID ?? "")
        let app = NSTextField(string: rule.appName ?? "")
        let title = NSTextField(string: rule.titleContains ?? "")
        let exactTitleMatch = NSButton(checkboxWithTitle: "Exact title match", target: self, action: #selector(ruleTitleMatchChanged(_:)))
        exactTitleMatch.state = rule.titleExactMatch == true ? .on : .off
        let titleMatchHelp = NSTextField(labelWithString: titleMatchHelpText(exact: exactTitleMatch.state == .on))
        titleMatchHelp.lineBreakMode = .byWordWrapping
        titleMatchHelp.maximumNumberOfLines = 2
        titleMatchHelp.textColor = .secondaryLabelColor
        ruleTitleMatchHelpLabel = titleMatchHelp
        let width = NSTextField(string: rule.widthRatio.map { String(Double($0)) } ?? "")
        let workspace = NSTextField(string: rule.workspace.map(String.init) ?? "")
        let behavior = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        behavior.addItems(withTitles: ["Default", "Tile", "Float", "Ignore"])
        switch rule.behavior {
        case .tile: behavior.selectItem(withTitle: "Tile")
        case .float: behavior.selectItem(withTitle: "Float")
        case .ignore: behavior.selectItem(withTitle: "Ignore")
        case nil: behavior.selectItem(withTitle: "Default")
        }
        let openPosition = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        openPosition.addItems(withTitles: ["Default", "Before active window", "After active window", "At the end"])
        switch rule.openPosition {
        case .beforeActive: openPosition.selectItem(withTitle: "Before active window")
        case .afterActive: openPosition.selectItem(withTitle: "After active window")
        case .end: openPosition.selectItem(withTitle: "At the end")
        case nil: openPosition.selectItem(withTitle: "Default")
        }

        for field in [bundle, app, title, width, workspace] {
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        for popup in [behavior, openPosition] {
            popup.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        exactTitleMatch.widthAnchor.constraint(equalToConstant: 300).isActive = true
        titleMatchHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true

        addRuleEditorRow(label: "Bundle ID", control: bundle, to: stack)
        addRuleEditorRow(label: "App Name", control: app, to: stack)
        addRuleEditorRow(label: "Title Text", control: title, to: stack)
        addRuleEditorRow(label: "Title Matching", control: exactTitleMatch, to: stack)
        addRuleEditorRow(label: "", control: titleMatchHelp, to: stack)
        addRuleEditorRow(label: "Behavior", control: behavior, to: stack)
        addRuleEditorRow(label: "Open Position", control: openPosition, to: stack)
        addRuleEditorRow(label: "Width Ratio", control: width, to: stack)
        addRuleEditorRow(label: "Workspace", control: workspace, to: stack)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 330))
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: accessory.bottomAnchor),
        ])

        alert.accessoryView = accessory
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        rule.bundleID = bundle.stringValue.isEmpty ? nil : bundle.stringValue
        rule.appName = app.stringValue.isEmpty ? nil : app.stringValue
        rule.titleContains = title.stringValue.isEmpty ? nil : title.stringValue
        rule.titleExactMatch = rule.titleContains != nil && exactTitleMatch.state == .on ? true : nil
        switch behavior.titleOfSelectedItem {
        case "Tile": rule.behavior = .tile
        case "Float": rule.behavior = .float
        case "Ignore": rule.behavior = .ignore
        default: rule.behavior = nil
        }
        switch openPosition.titleOfSelectedItem {
        case "Before active window": rule.openPosition = .beforeActive
        case "After active window": rule.openPosition = .afterActive
        case "At the end": rule.openPosition = .end
        default: rule.openPosition = nil
        }
        rule.widthRatio = Double(width.stringValue).map { CGFloat($0) }
        rule.workspace = Int(workspace.stringValue)
        draft.rules[index] = rule
        rulesTable.reloadData()
        markDirty()
        ruleTitleMatchHelpLabel = nil
        return true
    }

    @objc private func ruleTitleMatchChanged(_ sender: NSButton) {
        ruleTitleMatchHelpLabel?.stringValue = titleMatchHelpText(exact: sender.state == .on)
    }

    private func titleMatchHelpText(exact: Bool) -> String {
        if exact {
            return "Matches only when the whole window title is the same as the title text."
        }
        return "Matches any window whose title contains the title text."
    }

    private func addRuleEditorRow(label: String, control: NSView, to stack: NSStackView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 120).isActive = true
        row.addArrangedSubview(labelView)
        row.addArrangedSubview(control)
        stack.addArrangedSubview(row)
    }

    @objc private func cancel() {
        guard !isDirty || confirmDiscardChanges() else { return }
        setDirty(false)
        close()
    }

    @objc private func revertChanges() {
        draft = sourceConfig
        selectedAnimationStrategy = sourceConfig.animationStrategy
            ?? MiriConfig.fallback.animationStrategy
            ?? .snapshot
        rebuildPages()
        setDirty(false)
        statusLabel.stringValue = "Changes reverted"
    }

    @objc private func apply() {
        guard prepareDraftForSubmission() else { return }
        statusLabel.stringValue = "Saving…"
        statusLabel.textColor = .secondaryLabelColor
        actionSink(.saveConfig(draft, closeOnSuccess: false))
    }

    @objc private func save() {
        guard prepareDraftForSubmission() else { return }
        statusLabel.stringValue = "Saving…"
        statusLabel.textColor = .secondaryLabelColor
        actionSink(.saveConfig(draft, closeOnSuccess: true))
    }

    private func prepareDraftForSubmission() -> Bool {
        if let validationError = validateControlValues() {
            statusLabel.stringValue = validationError
            statusLabel.textColor = .systemRed
            return false
        }
        readControlsIntoDraft()
        if let validationError = validateDraft() {
            showPage(.shortcuts)
            sidebarTable.selectRowIndexes(IndexSet(integer: SettingsCategory.shortcuts.rawValue), byExtendingSelection: false)
            statusLabel.stringValue = validationError
            statusLabel.textColor = .systemRed
            return false
        }
        return true
    }

    private func validateControlValues() -> String? {
        let numericFields: [(String, String)] = [
            ("defaultWidthRatio", "Default width"),
            ("innerGap", "Inner gap"),
            ("outerGap", "Outer gap"),
            ("parkedSliverWidth", "Parked sliver"),
            ("animationFPS", "Animation frame rate"),
            ("animationPixelThreshold", "Animation pixel threshold"),
            ("windowReconciliationIntervalMS", "Safety rescan interval"),
        ]
        for item in numericFields {
            guard let field = controls[item.0] as? NSTextField else { continue }
            guard Double(field.stringValue) != nil else {
                return "\(item.1) must be a number."
            }
        }
        if let field = controls["presetWidthRatios"] as? NSTextField {
            let values = field.stringValue.split(separator: ",").map {
                Double($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if values.contains(where: { $0 == nil }) {
                return "Every width preset must be a number separated by commas."
            }
        }
        return nil
    }

    func presentSaveSuccess(closeOnSuccess: Bool) {
        sourceConfig = draft
        setDirty(false)
        if closeOnSuccess {
            close()
        } else {
            statusLabel.stringValue = "Saved and reloaded"
            statusLabel.textColor = MiriVisualStyle.green
        }
    }

    func presentSaveFailure(reason: String) {
        statusLabel.stringValue = "Could not save: \(reason)"
        statusLabel.textColor = .systemRed
    }

    private func confirmDiscardChanges() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "Your changes have not been applied to Miri."
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func markDirty() {
        setDirty(true)
    }

    private func setDirty(_ dirty: Bool) {
        isDirty = dirty
        revertButton.isEnabled = dirty
        applyButton.isEnabled = dirty
        saveButton.isEnabled = dirty
        saveButton.alphaValue = dirty ? 1 : 0.45
        statusLabel.stringValue = dirty ? "Unsaved changes" : "All changes saved"
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func controlChanged(_ sender: NSControl) {
        markDirty()
    }

    func controlTextDidChange(_ obj: Notification) {
        markDirty()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }
    private func helpLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 4
        label.textColor = .secondaryLabelColor
        return label
    }
    private func checkbox(_ key: String, _ value: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(controlChanged(_:)))
        button.state = value ? .on : .off
        button.setAccessibilityLabel(key)
        controls[key] = button
        return button
    }

    private func textField(_ key: String, _ value: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        field.delegate = self
        field.setAccessibilityIdentifier(key)
        controls[key] = field
        return field
    }

    private func intField(_ key: String, _ value: Int) -> NSTextField { textField(key, String(value)) }
    private func doubleField(_ key: String, _ value: Double) -> NSTextField { textField(key, String(value)) }

    private func pointsField(_ key: String, _ value: Double, suffix: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        let field = NSTextField(string: String(value))
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        field.delegate = self
        field.setAccessibilityIdentifier(key)
        controls[key] = field
        stack.addArrangedSubview(field)
        let unit = NSTextField(labelWithString: suffix)
        unit.textColor = .secondaryLabelColor
        stack.addArrangedSubview(unit)
        return stack
    }

    private func popup(_ key: String, _ options: [(String, String)], _ selected: String) -> NSPopUpButton {
        let popup = NSPopUpButton()
        for option in options {
            popup.addItem(withTitle: option.0)
            popup.lastItem?.representedObject = option.1
        }
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == selected }) {
            popup.select(item)
        }
        popup.target = self
        popup.action = #selector(controlChanged(_:))
        controls[key] = popup
        return popup
    }

    private func keyboardShortcutBackendPopup() -> NSPopUpButton {
        let selected = draft.keyboardShortcutBackend ?? MiriConfig.fallback.keyboardShortcutBackend ?? .eventTap
        let popup = NSPopUpButton()
        for option in KeyboardShortcutBackend.guiOptions {
            popup.addItem(withTitle: option.title)
            popup.lastItem?.representedObject = option.backend.rawValue
        }
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == selected.rawValue }) {
            popup.select(item)
        }
        popup.target = self
        popup.action = #selector(keyboardShortcutBackendChanged(_:))
        controls["keyboardShortcutBackend"] = popup
        return popup
    }

    private func keyboardShortcutBackendHelp() -> NSTextField {
        let backend = draft.keyboardShortcutBackend ?? MiriConfig.fallback.keyboardShortcutBackend ?? .eventTap
        let label = NSTextField(labelWithString: keyboardShortcutBackendHelpText(backend))
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 4
        label.textColor = .secondaryLabelColor
        keyboardShortcutBackendHelpLabel = label
        return label
    }

    @objc private func keyboardShortcutBackendChanged(_ sender: NSPopUpButton) {
        let rawValue = (sender.selectedItem?.representedObject as? String) ?? KeyboardShortcutBackend.eventTap.rawValue
        let backend = KeyboardShortcutBackend(rawValue: rawValue) ?? .eventTap
        keyboardShortcutBackendHelpLabel?.stringValue = keyboardShortcutBackendHelpText(backend)
        markDirty()
    }

    private func keyboardShortcutBackendHelpText(_ backend: KeyboardShortcutBackend) -> String {
        switch backend {
        case .eventTap:
            return "Full compatibility. Uses the existing event tap, supports left/right Option shortcuts and excluded shortcuts, and can consume matching keys. It still sees every keyDown, though normal typing should do very little work."
        case .registeredHotKeys:
            return "Lower idle/typing overhead. Registers only Miri shortcuts with macOS, so Miri wakes only for those shortcuts. Carbon registered shortcuts cannot distinguish left vs right Option/Alt and do not support fn/globe bindings."
        }
    }

    private func slider(_ key: String, _ value: Int, min: Int, max: Int) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        let slider = NSSlider(value: Double(value), minValue: Double(min), maxValue: Double(max), target: self, action: #selector(sliderChanged(_:)))
        slider.numberOfTickMarks = max - min + 1
        slider.allowsTickMarkValuesOnly = true
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        slider.identifier = NSUserInterfaceItemIdentifier(key)
        let label = NSTextField(labelWithString: "\(value)")
        label.widthAnchor.constraint(equalToConstant: 48).isActive = true
        label.identifier = NSUserInterfaceItemIdentifier("\(key).label")
        stack.addArrangedSubview(slider)
        stack.addArrangedSubview(label)
        controls[key] = slider
        return stack
    }

    private func minutesSlider(_ key: String, _ value: Int, min: Int, max: Int) -> NSStackView {
        let clamped = Swift.min(Swift.max(value, min), max)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        let slider = NSSlider(value: Double(clamped), minValue: Double(min), maxValue: Double(max), target: self, action: #selector(minutesSliderChanged(_:)))
        slider.numberOfTickMarks = max - min + 1
        slider.allowsTickMarkValuesOnly = true
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        slider.identifier = NSUserInterfaceItemIdentifier(key)
        let label = NSTextField(labelWithString: "\(clamped)m")
        label.widthAnchor.constraint(equalToConstant: 48).isActive = true
        label.identifier = NSUserInterfaceItemIdentifier("\(key).label")
        stack.addArrangedSubview(slider)
        stack.addArrangedSubview(label)
        controls[key] = slider
        return stack
    }

    private func secondsSlider(_ key: String, _ value: Double, min: Double, max: Double) -> NSStackView {
        let clamped = Swift.min(Swift.max(value, min), max)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        let slider = NSSlider(value: clamped, minValue: min, maxValue: max, target: self, action: #selector(secondsSliderChanged(_:)))
        slider.numberOfTickMarks = Int(((max - min) / 0.1).rounded()) + 1
        slider.allowsTickMarkValuesOnly = true
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        slider.identifier = NSUserInterfaceItemIdentifier(key)
        let label = NSTextField(labelWithString: String(format: "%.1fs", clamped))
        label.widthAnchor.constraint(equalToConstant: 48).isActive = true
        label.identifier = NSUserInterfaceItemIdentifier("\(key).label")
        stack.addArrangedSubview(slider)
        stack.addArrangedSubview(label)
        controls[key] = slider
        return stack
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let key = sender.identifier?.rawValue else { return }
        sender.integerValue = Int(sender.doubleValue.rounded())
        if let stack = sender.superview as? NSStackView,
           let label = stack.arrangedSubviews.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == "\(key).label" }) {
            label.stringValue = "\(sender.integerValue)"
        }
        markDirty()
    }

    @objc private func minutesSliderChanged(_ sender: NSSlider) {
        guard let key = sender.identifier?.rawValue else { return }
        sender.integerValue = Int(sender.doubleValue.rounded())
        if let stack = sender.superview as? NSStackView,
           let label = stack.arrangedSubviews.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == "\(key).label" }) {
            label.stringValue = "\(sender.integerValue)m"
        }
        markDirty()
    }

    @objc private func secondsSliderChanged(_ sender: NSSlider) {
        guard let key = sender.identifier?.rawValue else { return }
        sender.doubleValue = (sender.doubleValue * 10).rounded() / 10
        if let stack = sender.superview as? NSStackView,
           let label = stack.arrangedSubviews.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == "\(key).label" }) {
            label.stringValue = String(format: "%.1fs", sender.doubleValue)
        }
        markDirty()
    }

    private func colorWell(_ key: String, _ value: String) -> NSColorWell {
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
        well.color = colorFromSetting(value)
        well.target = self
        well.action = #selector(controlChanged(_:))
        controls[key] = well
        return well
    }

    private func bool(_ key: String) -> Bool { (controls[key] as? NSButton)?.state == .on }
    private func string(_ key: String) -> String {
        if let p = controls[key] as? NSPopUpButton {
            return (p.selectedItem?.representedObject as? String) ?? p.titleOfSelectedItem ?? ""
        }
        return (controls[key] as? NSTextField)?.stringValue ?? ""
    }
    private func csv(_ key: String) -> [String] { string(key).split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private func int(_ key: String) -> Int { if let s = controls[key] as? NSSlider { return s.integerValue }; return Int(string(key)) ?? 0 }
    private func double(_ key: String) -> Double { if let s = controls[key] as? NSSlider { return s.doubleValue }; return Double(string(key)) ?? 0 }

    private func colorHex(_ key: String) -> String {
        guard let color = (controls[key] as? NSColorWell)?.color.usingColorSpace(.sRGB) else { return "#FFD60A" }
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private func colorFromSetting(_ value: String) -> NSColor {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
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
        case let hex where hex.hasPrefix("#"):
            return colorFromHex(hex) ?? .systemYellow
        default:
            return .systemYellow
        }
    }

    private func colorFromHex(_ hex: String) -> NSColor? {
        let trimmed = String(hex.dropFirst())
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xff) / 255
        let g = CGFloat((value >> 8) & 0xff) / 255
        let b = CGFloat(value & 0xff) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

extension FocusAlignment {
    static let guiOptions: [(alignment: FocusAlignment, title: String)] = [
        (.default, "Default"),
        (.centered, "Centered"),
        (.centeredSmart, "Centered Smart"),
    ]
}
extension NewWindowPosition {
    var guiTitle: String {
        switch self {
        case .beforeActive: "Before active"
        case .afterActive: "After active"
        case .end: "At end"
        }
    }
}

extension KeyboardShortcutBackend {
    static let guiOptions: [(backend: KeyboardShortcutBackend, title: String)] = [
        (.eventTap, "Full Compatibility"),
        (.registeredHotKeys, "Registered Shortcuts"),
    ]
}
