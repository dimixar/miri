import SwiftUI

struct RuleSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var selectedIndex: Int?
    @State private var editor: RuleEditorPresentation?

    private struct RuleEditorPresentation: Identifiable {
        let id = UUID()
        let index: Int?
        let rule: WindowRule
    }

    var body: some View {
        MiriPageScrollContainer {
            MiriSection(
                title: "Ordered rules",
                detail: "Rules are evaluated in list order. Double-click a row to edit it."
            ) {
                MiriPanel(horizontalPadding: MiriTheme.Spacing.rowVertical, verticalPadding: MiriTheme.Spacing.rowVertical) {
                    VStack(alignment: .leading, spacing: 9) {
                        toolbar
                        ruleHeader
                        List(selection: $selectedIndex) {
                            ForEach(Array(store.draft.rules.indices), id: \.self) { index in
                                ruleRow(store.draft.rules[index])
                                    .tag(index)
                                    .onTapGesture(count: 2) {
                                        selectedIndex = index
                                        editRule(at: index)
                                    }
                            }
                        }
                        .frame(minHeight: 330)
                    }
                }
            }
        }
        .sheet(item: $editor) { presentation in
            RuleEditorSheet(rule: presentation.rule) { rule in
                if let index = presentation.index,
                   store.draft.rules.indices.contains(index)
                {
                    store.draft.rules[index] = rule
                    selectedIndex = index
                } else {
                    store.draft.rules.append(rule)
                    selectedIndex = store.draft.rules.count - 1
                }
                editor = nil
            } cancel: {
                editor = nil
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: MiriTheme.Spacing.compact) {
            Button("Add Rule…") {
                editor = RuleEditorPresentation(
                    index: nil,
                    rule: WindowRule(bundleID: "", behavior: .tile)
                )
            }
            Menu("Add Open App…") {
                Button("Manual bundle id…") {
                    editor = RuleEditorPresentation(
                        index: nil,
                        rule: WindowRule(bundleID: "", behavior: .tile)
                    )
                }
                Divider()
                ForEach(Array(store.availableApps.enumerated()), id: \.offset) { _, app in
                    Button("\(app.appName) — \(app.bundleID)") {
                        editor = RuleEditorPresentation(
                            index: nil,
                            rule: WindowRule(
                                bundleID: app.bundleID,
                                appName: app.appName,
                                behavior: .tile
                            )
                        )
                    }
                }
            }
            Button("Duplicate", action: duplicateSelectedRule)
                .disabled(!hasSelection)
            Button("Move Up", action: moveSelectedRuleUp)
                .disabled(!canMoveUp)
            Button("Move Down", action: moveSelectedRuleDown)
                .disabled(!canMoveDown)
            Button("Delete", action: deleteSelectedRule)
                .disabled(!hasSelection)
        }
    }

    private var ruleHeader: some View {
        HStack(spacing: MiriTheme.Spacing.control) {
            Text("Application").frame(width: 155, alignment: .leading)
            Text("Window Match").frame(width: 180, alignment: .leading)
            Text("Behavior").frame(width: 85, alignment: .leading)
            Text("Placement").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, MiriTheme.Spacing.compact)
    }

    private func ruleRow(_ rule: WindowRule) -> some View {
        HStack(spacing: MiriTheme.Spacing.control) {
            Text(rule.appName ?? rule.bundleID ?? "Any application")
                .frame(width: 155, alignment: .leading)
            Text(windowMatch(for: rule))
                .frame(width: 180, alignment: .leading)
            Text((rule.behavior?.rawValue ?? "default").capitalized)
                .frame(width: 85, alignment: .leading)
            Text(placement(for: rule))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(1)
    }

    private var hasSelection: Bool {
        selectedIndex.map(store.draft.rules.indices.contains) ?? false
    }

    private var canMoveUp: Bool {
        guard let selectedIndex else { return false }
        return store.draft.rules.indices.contains(selectedIndex) && selectedIndex > 0
    }

    private var canMoveDown: Bool {
        guard let selectedIndex else { return false }
        return store.draft.rules.indices.contains(selectedIndex)
            && selectedIndex < store.draft.rules.count - 1
    }

    private func editRule(at index: Int) {
        guard store.draft.rules.indices.contains(index) else { return }
        editor = RuleEditorPresentation(index: index, rule: store.draft.rules[index])
    }

    private func duplicateSelectedRule() {
        guard let selectedIndex, store.draft.rules.indices.contains(selectedIndex) else { return }
        store.draft.rules.insert(store.draft.rules[selectedIndex], at: selectedIndex + 1)
        self.selectedIndex = selectedIndex + 1
    }

    private func moveSelectedRuleUp() {
        guard let selectedIndex, canMoveUp else { return }
        store.draft.rules.swapAt(selectedIndex, selectedIndex - 1)
        self.selectedIndex = selectedIndex - 1
    }

    private func moveSelectedRuleDown() {
        guard let selectedIndex, canMoveDown else { return }
        store.draft.rules.swapAt(selectedIndex, selectedIndex + 1)
        self.selectedIndex = selectedIndex + 1
    }

    private func deleteSelectedRule() {
        guard let selectedIndex, store.draft.rules.indices.contains(selectedIndex) else { return }
        store.draft.rules.remove(at: selectedIndex)
        self.selectedIndex = nil
    }

    private func windowMatch(for rule: WindowRule) -> String {
        guard let title = rule.titleContains, !title.isEmpty else { return "All windows" }
        return rule.titleExactMatch == true ? "Title is \(title)" : "Title contains \(title)"
    }

    private func placement(for rule: WindowRule) -> String {
        var parts: [String] = []
        if let width = rule.widthRatio {
            parts.append("\(Int((width * 100).rounded()))%")
        }
        if let workspace = rule.workspace {
            parts.append("Workspace \(workspace)")
        }
        if let position = rule.openPosition {
            parts.append(position.settingsTitle)
        }
        return parts.isEmpty ? "Default" : parts.joined(separator: " · ")
    }
}

private struct RuleEditorSheet: View {
    @State private var bundleID: String
    @State private var appName: String
    @State private var titleText: String
    @State private var exactTitleMatch: Bool
    @State private var behavior: WindowBehavior?
    @State private var openPosition: NewWindowPosition?
    @State private var widthRatio: String
    @State private var workspace: String

    let save: (WindowRule) -> Void
    let cancel: () -> Void

    init(rule: WindowRule, save: @escaping (WindowRule) -> Void, cancel: @escaping () -> Void) {
        _bundleID = State(initialValue: rule.bundleID ?? "")
        _appName = State(initialValue: rule.appName ?? "")
        _titleText = State(initialValue: rule.titleContains ?? "")
        _exactTitleMatch = State(initialValue: rule.titleExactMatch == true)
        _behavior = State(initialValue: rule.behavior)
        _openPosition = State(initialValue: rule.openPosition)
        _widthRatio = State(initialValue: rule.widthRatio.map { String(Double($0)) } ?? "")
        _workspace = State(initialValue: rule.workspace.map(String.init) ?? "")
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MiriTheme.Spacing.control) {
            Text("Edit Rule")
                .font(MiriTheme.Typography.pageTitle)
            Grid(alignment: .leading, horizontalSpacing: MiriTheme.Spacing.control, verticalSpacing: 10) {
                editorRow("Bundle ID") { TextField("", text: $bundleID) }
                editorRow("App Name") { TextField("", text: $appName) }
                editorRow("Title Text") { TextField("", text: $titleText) }
                editorRow("Title Matching") {
                    Toggle("Exact title match", isOn: $exactTitleMatch)
                        .toggleStyle(.checkbox)
                }
                editorRow("") {
                    Text(titleMatchHelp)
                        .font(MiriTheme.Typography.rowDetail)
                        .foregroundStyle(.secondary)
                }
                editorRow("Behavior") {
                    Picker("", selection: $behavior) {
                        Text("Default").tag(Optional<WindowBehavior>.none)
                        Text("Tile").tag(Optional(WindowBehavior.tile))
                        Text("Float").tag(Optional(WindowBehavior.float))
                        Text("Ignore").tag(Optional(WindowBehavior.ignore))
                    }
                    .labelsHidden()
                }
                editorRow("Open Position") {
                    Picker("", selection: $openPosition) {
                        Text("Default").tag(Optional<NewWindowPosition>.none)
                        Text("Before active window").tag(Optional(NewWindowPosition.beforeActive))
                        Text("After active window").tag(Optional(NewWindowPosition.afterActive))
                        Text("At the end").tag(Optional(NewWindowPosition.end))
                    }
                    .labelsHidden()
                }
                editorRow("Width Ratio") { TextField("", text: $widthRatio) }
                editorRow("Workspace") { TextField("", text: $workspace) }
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: saveRule)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(MiriTheme.Spacing.page)
        .frame(width: 520)
    }

    private var titleMatchHelp: String {
        exactTitleMatch
            ? "Matches only when the whole window title is the same as the title text."
            : "Matches any window whose title contains the title text."
    }

    private func editorRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GridRow {
            Text(label)
                .frame(width: 110, alignment: .trailing)
            content()
                .frame(width: 320, alignment: .leading)
        }
    }

    private func saveRule() {
        let normalizedTitle = normalized(titleText)
        save(WindowRule(
            bundleID: normalized(bundleID),
            appName: normalized(appName),
            titleContains: normalizedTitle,
            titleExactMatch: normalizedTitle != nil && exactTitleMatch ? true : nil,
            behavior: behavior,
            widthRatio: Double(widthRatio).map { CGFloat($0) },
            workspace: Int(workspace),
            openPosition: openPosition
        ))
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension NewWindowPosition {
    var settingsTitle: String {
        switch self {
        case .beforeActive: return "Before active"
        case .afterActive: return "After active"
        case .end: return "At end"
        }
    }
}
