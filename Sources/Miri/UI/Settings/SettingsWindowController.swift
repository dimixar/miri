import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private weak var miri: Miri?
    private var draft: MiriConfig
    private var availableApps: [RuleAppInfo]
    private let tabView = NSTabView()
    private let rulesTable = NSTableView()
    private let activeRescanBundleTable = NSTableView()
    private weak var ruleTitleMatchHelpLabel: NSTextField?
    private weak var keyboardShortcutBackendHelpLabel: NSTextField?

    private var controls: [String: NSControl] = [:]

    init(miri: Miri, config: MiriConfig, availableApps: [RuleAppInfo]) {
        self.miri = miri
        self.draft = config
        self.availableApps = availableApps

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Miri Settings"
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh(config: MiriConfig, availableApps: [RuleAppInfo]) {
        draft = config
        self.availableApps = availableApps
        rebuildTabs()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabView)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttonRow)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(spacer)
        buttonRow.addArrangedSubview(button("Cancel", #selector(cancel)))
        buttonRow.addArrangedSubview(button("Apply", #selector(apply)))
        buttonRow.addArrangedSubview(button("Save", #selector(save)))

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),
            buttonRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            buttonRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            buttonRow.heightAnchor.constraint(equalToConstant: 32),
        ])

        rebuildTabs()
    }

    private func rebuildTabs() {
        controls.removeAll()
        tabView.tabViewItems.removeAll()
        tabView.addTabViewItem(tab("General", generalView()))
        tabView.addTabViewItem(tab("Layout", layoutView()))
        tabView.addTabViewItem(tab("Animations", animationsView()))
        tabView.addTabViewItem(tab("Keybindings", keybindingsView()))
        tabView.addTabViewItem(tab("Workspace Bar", workspaceBarView()))
        tabView.addTabViewItem(tab("Reliability", reliabilityView()))
        tabView.addTabViewItem(tab("Rules", rulesView()))
    }

    private func tab(_ title: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    private func form(_ rows: [(String, NSView)]) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        for (label, view) in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 12
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false

            let text = NSTextField(labelWithString: label)
            text.alignment = .right
            text.widthAnchor.constraint(equalToConstant: 240).isActive = true
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            row.addArrangedSubview(text)
            row.addArrangedSubview(view)
            stack.addArrangedSubview(row)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalToConstant: 720),
            document.heightAnchor.constraint(greaterThanOrEqualToConstant: 480),
        ])

        scroll.documentView = document
        return scroll
    }

    private func generalView() -> NSView { form([
        ("Restore windows on quit", checkbox("restoreOnExit", draft.restoreOnExit ?? MiriConfig.fallback.restoreOnExit ?? true)),
        ("Persist layout", checkbox("persistLayout", draft.persistLayout ?? MiriConfig.fallback.persistLayout ?? true)),
        ("Shortcut handling", keyboardShortcutBackendPopup()),
        ("", keyboardShortcutBackendHelp()),
        ("Reconciliation interval ms", intField("windowReconciliationIntervalMS", draft.windowReconciliationIntervalMS ?? MiriConfig.fallback.windowReconciliationIntervalMS ?? 60000)),
        ("Placeholder probe cooldown", secondsSlider("axCreatedPlaceholderProbeCooldownSeconds", Double(draft.axCreatedPlaceholderProbeCooldownMS ?? MiriConfig.fallback.axCreatedPlaceholderProbeCooldownMS ?? 1000) / 1000, min: 0.0, max: 5.0)),
        ("Fullscreen transition grace", secondsSlider("likelyFullscreenTransitionGraceSeconds", Double(draft.likelyFullscreenTransitionGraceMS ?? MiriConfig.fallback.likelyFullscreenTransitionGraceMS ?? 1500) / 1000, min: 0.1, max: 2.0)),
        ("Fullscreen Space guard", secondsSlider("fullscreenSpaceChangeGuardSeconds", Double(draft.fullscreenSpaceChangeGuardMS ?? MiriConfig.fallback.fullscreenSpaceChangeGuardMS ?? 1500) / 1000, min: 0.1, max: 3.0)),
        ("Logical Space autosave", minutesSlider("logicalSpaceAutosaveIntervalMinutes", draft.logicalSpaceAutosaveIntervalMinutes ?? MiriConfig.fallback.logicalSpaceAutosaveIntervalMinutes ?? 30, min: 1, max: 60)),
        ("Debug logging", checkbox("debugLogging", draft.debugLogging ?? MiriConfig.fallback.debugLogging ?? false)),
    ]) }

    private func layoutView() -> NSView { form([
        ("Default width ratio", doubleField("defaultWidthRatio", Double(draft.defaultWidthRatio))),
        ("Preset width ratios CSV", textField("presetWidthRatios", (draft.presetWidthRatios ?? []).map { String(format: "%.2f", Double($0)) }.joined(separator: ", "))),
        ("Width resize mode", popup("widthResizeMode", WidthResizeMode.allCasesStrings, draft.widthResizeMode?.rawValue ?? MiriConfig.fallback.widthResizeMode?.rawValue ?? "default")),
        ("Focus alignment", popup("focusAlignment", FocusAlignment.allCasesStrings, draft.focusAlignment?.rawValue ?? "smart")),
        ("New window position", popup("newWindowPosition", NewWindowPosition.allCasesStrings, draft.newWindowPosition?.rawValue ?? "after_active")),
        ("Inner gap", doubleField("innerGap", Double(draft.innerGap ?? 0))),
        ("Outer gap", doubleField("outerGap", Double(draft.outerGap ?? 0))),
        ("Parked sliver px", doubleField("parkedSliverWidth", Double(draft.parkedSliverWidth ?? 1))),
    ]) }

    private func animationsView() -> NSView { form([
        ("Snapshot speed", slider("snapshotAnimationSpeed", draft.snapshotAnimationSpeed ?? MiriConfig.fallback.snapshotAnimationSpeed ?? 50, min: 1, max: 100)),
        ("Fallback AX duration ms", intField("animationDurationMS", draft.animationDurationMS ?? 0)),
        ("Keyboard AX duration ms", intField("keyboardAnimationMS", draft.keyboardAnimationMS ?? 0)),
        ("Move column AX duration ms", intField("moveColumnAnimationMS", draft.moveColumnAnimationMS ?? 0)),
        ("Width animation ms", intField("widthAnimationMS", draft.widthAnimationMS ?? 0)),
        ("Strategy", popup("animationStrategy", AnimationStrategy.allCasesStrings, draft.animationStrategy?.rawValue ?? MiriConfig.fallback.animationStrategy?.rawValue ?? "snapshot")),
        ("Animation FPS", intField("animationFPS", draft.animationFPS ?? 60)),
        ("Pixel threshold", doubleField("animationPixelThreshold", Double(draft.animationPixelThreshold ?? 0.5))),
        ("Curve", popup("animationCurve", AnimationCurve.allCasesStrings, draft.animationCurve?.rawValue ?? "smooth")),
    ]) }

    private func workspaceBarView() -> NSView { form([
        ("Show fullscreen apps", checkbox("workspaceBarShowFullscreen", draft.workspaceBarShowFullscreen ?? MiriConfig.fallback.workspaceBarShowFullscreen ?? true)),
        ("Active workspace style", popup("workspaceBarActiveStyle", WorkspaceBarActiveStyle.allCasesStrings, draft.workspaceBarActiveStyle?.rawValue ?? MiriConfig.fallback.workspaceBarActiveStyle?.rawValue ?? "braces")),
        ("Center app strip style", popup("workspaceBarCenterStyle", WorkspaceBarCenterStyle.allCasesStrings, draft.workspaceBarCenterStyle?.rawValue ?? MiriConfig.fallback.workspaceBarCenterStyle?.rawValue ?? "delimiter")),
        ("Delimiter/border color", colorWell("workspaceBarDelimiterColor", draft.workspaceBarDelimiterColor ?? MiriConfig.fallback.workspaceBarDelimiterColor ?? "#FFD60A")),
        ("Center border size", slider("workspaceBarCenterBorderOutset", draft.workspaceBarCenterBorderOutset ?? MiriConfig.fallback.workspaceBarCenterBorderOutset ?? 0, min: 0, max: 5)),
        ("Center border thickness", slider("workspaceBarCenterBorderThickness", draft.workspaceBarCenterBorderThickness ?? MiriConfig.fallback.workspaceBarCenterBorderThickness ?? 1, min: 1, max: 3)),
        ("Highlight color", colorWell("workspaceBarHighlightColor", draft.workspaceBarHighlightColor ?? MiriConfig.fallback.workspaceBarHighlightColor ?? "yellow")),
        ("Visible app window icons", slider("workspaceBarVisibleIconCount", draft.workspaceBarVisibleIconCount ?? MiriConfig.fallback.workspaceBarVisibleIconCount ?? 3, min: 1, max: 6)),
        ("Overflow style", popup("workspaceBarOverflowStyle", WorkspaceBarOverflowStyle.allCasesStrings, draft.workspaceBarOverflowStyle?.rawValue ?? MiriConfig.fallback.workspaceBarOverflowStyle?.rawValue ?? "plus_count")),
    ]) }

    private func keybindingsView() -> NSView {
        var rows: [(String, NSView)] = []
        rows.append(("Excluded keybindings CSV", textField("excludedKeybindings", (draft.excludedKeybindings ?? []).joined(separator: ", "))))

        let keybindings = draft.keybindings ?? MiriConfig.defaultKeybindings
        for command in MiriConfig.defaultKeybindings.keys.sorted() {
            let bindings = keybindings[command] ?? []
            rows.append((command, textField("keybinding.\(command)", bindings.joined(separator: ", "))))
        }

        return form(rows)
    }

    private func reliabilityView() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let toggleRow = NSStackView()
        toggleRow.orientation = .horizontal
        toggleRow.spacing = 12
        toggleRow.alignment = .centerY
        let toggleLabel = NSTextField(labelWithString: "Active rescans")
        toggleLabel.alignment = .right
        toggleLabel.widthAnchor.constraint(equalToConstant: 160).isActive = true
        toggleRow.addArrangedSubview(toggleLabel)
        toggleRow.addArrangedSubview(checkbox("activeRescanEnabled", draft.activeRescanEnabled ?? MiriConfig.fallback.activeRescanEnabled ?? false))
        root.addArrangedSubview(toggleRow)

        let description = helpLabel("When enabled, Miri rescans listed tiled apps once per second and on user input. Use this for apps that miss Accessibility close, minimize, hide, or show events.")
        description.widthAnchor.constraint(equalToConstant: 620).isActive = true
        root.addArrangedSubview(description)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(button("Add Manual Bundle", #selector(addManualActiveRescanBundle)))
        buttons.addArrangedSubview(button("Add From Open App…", #selector(addActiveRescanBundleFromOpenApp)))
        buttons.addArrangedSubview(button("Delete", #selector(deleteActiveRescanBundle)))
        root.addArrangedSubview(buttons)

        activeRescanBundleTable.dataSource = self
        activeRescanBundleTable.delegate = self
        activeRescanBundleTable.target = self
        activeRescanBundleTable.doubleAction = #selector(editSelectedActiveRescanBundle)
        activeRescanBundleTable.usesAlternatingRowBackgroundColors = true
        activeRescanBundleTable.headerView = nil
        if activeRescanBundleTable.tableColumns.isEmpty {
            activeRescanBundleTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("activeRescanBundle")))
        }
        let scroll = NSScrollView()
        scroll.documentView = activeRescanBundleTable
        scroll.hasVerticalScroller = true
        root.addArrangedSubview(scroll)
        activeRescanBundleTable.reloadData()
        return root
    }

    private func rulesView() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(button("Add Manual Rule", #selector(addManualRule)))
        buttons.addArrangedSubview(button("Add From Open App…", #selector(addFromOpenApp)))
        buttons.addArrangedSubview(button("Duplicate", #selector(duplicateRule)))
        buttons.addArrangedSubview(button("Move Up", #selector(moveRuleUp)))
        buttons.addArrangedSubview(button("Move Down", #selector(moveRuleDown)))
        buttons.addArrangedSubview(button("Delete", #selector(deleteRule)))
        root.addArrangedSubview(buttons)

        rulesTable.dataSource = self
        rulesTable.delegate = self
        rulesTable.target = self
        rulesTable.doubleAction = #selector(editSelectedRule)
        rulesTable.usesAlternatingRowBackgroundColors = true
        rulesTable.headerView = nil
        if rulesTable.tableColumns.isEmpty {
            rulesTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule")))
        }
        let scroll = NSScrollView()
        scroll.documentView = rulesTable
        scroll.hasVerticalScroller = true
        root.addArrangedSubview(scroll)
        rulesTable.reloadData()
        return root
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === rulesTable {
            return draft.rules.count
        }
        if tableView === activeRescanBundleTable {
            return draftActiveRescanBundleIDs().count
        }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label: String
        if tableView === rulesTable {
            guard draft.rules.indices.contains(row) else { return nil }
            label = ruleSummary(draft.rules[row])
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
        draft.focusAlignment = FocusAlignment(rawValue: string("focusAlignment"))
        draft.newWindowPosition = NewWindowPosition(rawValue: string("newWindowPosition"))
        draft.innerGap = CGFloat(double("innerGap"))
        draft.outerGap = CGFloat(double("outerGap"))
        draft.parkedSliverWidth = CGFloat(double("parkedSliverWidth"))
        draft.animationDurationMS = int("animationDurationMS")
        draft.keyboardAnimationMS = int("keyboardAnimationMS")
        draft.moveColumnAnimationMS = int("moveColumnAnimationMS")
        draft.widthAnimationMS = int("widthAnimationMS")
        draft.animationStrategy = AnimationStrategy(rawValue: string("animationStrategy"))
        draft.snapshotAnimationSpeed = max(1, min(int("snapshotAnimationSpeed"), 100))
        draft.animationFPS = int("animationFPS")
        draft.animationPixelThreshold = CGFloat(double("animationPixelThreshold"))
        draft.animationCurve = AnimationCurve(rawValue: string("animationCurve"))
        draft.workspaceBarShowFullscreen = bool("workspaceBarShowFullscreen")
        draft.workspaceBarActiveStyle = WorkspaceBarActiveStyle(rawValue: string("workspaceBarActiveStyle"))
        draft.workspaceBarCenterStyle = WorkspaceBarCenterStyle(rawValue: string("workspaceBarCenterStyle"))
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
    }

    private func addActiveRescanBundleID(_ bundleID: String) {
        var bundleIDs = draftActiveRescanBundleIDs()
        bundleIDs.append(bundleID)
        setDraftActiveRescanBundleIDs(bundleIDs)
        activeRescanBundleTable.reloadData()
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
        editRule(at: draft.rules.count - 1)
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
        editRule(at: draft.rules.count - 1)
    }

    @objc private func editSelectedRule() {
        editRule(at: rulesTable.selectedRow)
    }

    @objc private func duplicateRule() {
        let row = rulesTable.selectedRow
        guard draft.rules.indices.contains(row) else { return }
        draft.rules.insert(draft.rules[row], at: row + 1)
        rulesTable.reloadData()
        rulesTable.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
    }

    @objc private func moveRuleUp() {
        let row = rulesTable.selectedRow
        guard draft.rules.indices.contains(row), row > 0 else { return }
        draft.rules.swapAt(row, row - 1)
        rulesTable.reloadData()
        rulesTable.selectRowIndexes(IndexSet(integer: row - 1), byExtendingSelection: false)
    }

    @objc private func moveRuleDown() {
        let row = rulesTable.selectedRow
        guard draft.rules.indices.contains(row), row < draft.rules.count - 1 else { return }
        draft.rules.swapAt(row, row + 1)
        rulesTable.reloadData()
        rulesTable.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
    }

    @objc private func deleteRule() {
        let row = rulesTable.selectedRow
        guard draft.rules.indices.contains(row) else { return }
        draft.rules.remove(at: row)
        rulesTable.reloadData()
    }

    private func editRule(at index: Int) {
        guard draft.rules.indices.contains(index) else { return }
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

        for field in [bundle, app, title, width, workspace] {
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        behavior.widthAnchor.constraint(equalToConstant: 300).isActive = true
        exactTitleMatch.widthAnchor.constraint(equalToConstant: 300).isActive = true
        titleMatchHelp.widthAnchor.constraint(equalToConstant: 300).isActive = true

        addRuleEditorRow(label: "Bundle ID", control: bundle, to: stack)
        addRuleEditorRow(label: "App Name", control: app, to: stack)
        addRuleEditorRow(label: "Title Text", control: title, to: stack)
        addRuleEditorRow(label: "Title Matching", control: exactTitleMatch, to: stack)
        addRuleEditorRow(label: "", control: titleMatchHelp, to: stack)
        addRuleEditorRow(label: "Behavior", control: behavior, to: stack)
        addRuleEditorRow(label: "Width Ratio", control: width, to: stack)
        addRuleEditorRow(label: "Workspace", control: workspace, to: stack)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 290))
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
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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
        rule.widthRatio = Double(width.stringValue).map { CGFloat($0) }
        rule.workspace = Int(workspace.stringValue)
        draft.rules[index] = rule
        rulesTable.reloadData()
        ruleTitleMatchHelpLabel = nil
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

    @objc private func cancel() { close() }

    @objc private func apply() {
        readControlsIntoDraft()
        if let validationError = validateDraft() {
            showAlert(title: "Invalid Settings", message: validationError)
            return
        }
        miri?.saveConfigFromSettings(draft)
        showAlert(title: "Miri Settings Saved", message: "Config was saved and reloaded.")
    }

    @objc private func save() {
        readControlsIntoDraft()
        if let validationError = validateDraft() {
            showAlert(title: "Invalid Settings", message: validationError)
            return
        }
        miri?.saveConfigFromSettings(draft)
        close()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: action); return b }
    private func helpLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 4
        label.textColor = .secondaryLabelColor
        return label
    }
    private func checkbox(_ key: String, _ value: Bool) -> NSButton { let b = NSButton(checkboxWithTitle: "", target: nil, action: nil); b.state = value ? .on : .off; controls[key] = b; return b }
    private func textField(_ key: String, _ value: String) -> NSTextField { let f = NSTextField(string: value); f.widthAnchor.constraint(equalToConstant: 220).isActive = true; controls[key] = f; return f }
    private func intField(_ key: String, _ value: Int) -> NSTextField { textField(key, String(value)) }
    private func doubleField(_ key: String, _ value: Double) -> NSTextField { textField(key, String(value)) }
    private func popup(_ key: String, _ values: [String], _ selected: String) -> NSPopUpButton { let p = NSPopUpButton(); p.addItems(withTitles: values); p.selectItem(withTitle: selected); controls[key] = p; return p }

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
        label.widthAnchor.constraint(equalToConstant: 390).isActive = true
        keyboardShortcutBackendHelpLabel = label
        return label
    }

    @objc private func keyboardShortcutBackendChanged(_ sender: NSPopUpButton) {
        let rawValue = (sender.selectedItem?.representedObject as? String) ?? KeyboardShortcutBackend.eventTap.rawValue
        let backend = KeyboardShortcutBackend(rawValue: rawValue) ?? .eventTap
        keyboardShortcutBackendHelpLabel?.stringValue = keyboardShortcutBackendHelpText(backend)
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
    }

    @objc private func minutesSliderChanged(_ sender: NSSlider) {
        guard let key = sender.identifier?.rawValue else { return }
        sender.integerValue = Int(sender.doubleValue.rounded())
        if let stack = sender.superview as? NSStackView,
           let label = stack.arrangedSubviews.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == "\(key).label" }) {
            label.stringValue = "\(sender.integerValue)m"
        }
    }

    @objc private func secondsSliderChanged(_ sender: NSSlider) {
        guard let key = sender.identifier?.rawValue else { return }
        sender.doubleValue = (sender.doubleValue * 10).rounded() / 10
        if let stack = sender.superview as? NSStackView,
           let label = stack.arrangedSubviews.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == "\(key).label" }) {
            label.stringValue = String(format: "%.1fs", sender.doubleValue)
        }
    }

    private func colorWell(_ key: String, _ value: String) -> NSColorWell {
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
        well.color = colorFromSetting(value)
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

extension FocusAlignment { static let allCasesStrings = ["left", "center", "smart"] }
extension NewWindowPosition { static let allCasesStrings = ["before_active", "after_active", "end"] }
extension AnimationCurve { static let allCasesStrings = ["smooth", "snappy", "linear"] }
extension AnimationStrategy { static let allCasesStrings = ["snapshot", "off"] }
extension WorkspaceBarOverflowStyle { static let allCasesStrings = ["plus_count", "dots_count", "chevron", "none"] }
extension WorkspaceBarActiveStyle { static let allCasesStrings = ["braces", "filled_pointer", "filled_dot", "square_brackets", "angle_brackets", "outline", "filled_outline"] }
extension WorkspaceBarCenterStyle { static let allCasesStrings = ["delimiter", "border", "filled_border"] }
extension WidthResizeMode { static let allCasesStrings = ["default", "intelligent"] }

extension KeyboardShortcutBackend {
    static let guiOptions: [(backend: KeyboardShortcutBackend, title: String)] = [
        (.eventTap, "Full Compatibility"),
        (.registeredHotKeys, "Registered Shortcuts"),
    ]
}
