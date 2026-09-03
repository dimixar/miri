import SwiftUI

struct AdvancedSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var selectedBundleID: String?
    @State private var bundleEditor: BundleEditor?

    private struct BundleEditor: Identifiable {
        let id = UUID()
        let originalValue: String?
        var value: String
    }

    var body: some View {
        MiriPageScrollContainer {
            MiriSection(
                title: "System reconciliation",
                detail: "Conservative recovery controls for missed or delayed macOS events."
            ) {
                MiriSettingGroup {
                    MiriTextFieldRow(
                        title: "Safety rescan interval",
                        detail: "Long fallback interval in milliseconds.",
                        text: SettingsTextBinding.integer($store.draft.windowReconciliationIntervalMS)
                    )
                    MiriRowDivider()
                    MiriSecondsSliderRow(
                        title: "Placeholder probe cooldown",
                        milliseconds: $store.draft.axCreatedPlaceholderProbeCooldownMS,
                        secondsRange: 0...5
                    )
                    MiriRowDivider()
                    MiriSecondsSliderRow(
                        title: "Fullscreen transition grace",
                        milliseconds: $store.draft.likelyFullscreenTransitionGraceMS,
                        secondsRange: 0.1...2
                    )
                    MiriRowDivider()
                    MiriSecondsSliderRow(
                        title: "Fullscreen Space guard",
                        milliseconds: $store.draft.fullscreenSpaceChangeGuardMS,
                        secondsRange: 0.1...3
                    )
                    MiriRowDivider()
                    MiriIntegerSliderRow(
                        title: "Logical Space autosave",
                        value: $store.draft.logicalSpaceAutosaveIntervalMinutes,
                        range: 1...60,
                        suffix: "m"
                    )
                }
            }

            MiriSection(
                title: "Active rescans",
                detail: "Target apps that miss Accessibility window lifecycle events. This can increase CPU use."
            ) {
                MiriSettingGroup {
                    MiriToggleRow(
                        title: "Enable active rescans",
                        detail: "Rescan listed tiled apps once per second and after input.",
                        value: $store.draft.activeRescanEnabled
                    )
                }
            }

            MiriSection(title: "Target applications") {
                targetApplications
            }

            MiriSection(title: "Diagnostics") {
                MiriSettingGroup {
                    MiriToggleRow(
                        title: "Debug logging",
                        detail: "Write detailed logs to ~/.config/miri/debug.log.",
                        value: $store.draft.debugLogging
                    )
                }
            }
        }
        .sheet(item: $bundleEditor) { editor in
            bundleEditorSheet(editor)
        }
    }

    private var targetApplications: some View {
        MiriPanel(horizontalPadding: MiriTheme.Spacing.rowVertical, verticalPadding: MiriTheme.Spacing.rowVertical) {
            VStack(alignment: .leading, spacing: MiriTheme.Spacing.compact) {
                HStack(spacing: MiriTheme.Spacing.compact) {
                    Button("Add Bundle…") {
                        bundleEditor = BundleEditor(originalValue: nil, value: "")
                    }
                    Menu("Add Open App…") {
                        ForEach(Array(store.availableApps.enumerated()), id: \.offset) { _, app in
                            Button("\(app.appName) — \(app.bundleID)") {
                                addBundleID(app.bundleID)
                            }
                        }
                    }
                    Button("Edit…") {
                        guard let selectedBundleID else { return }
                        bundleEditor = BundleEditor(originalValue: selectedBundleID, value: selectedBundleID)
                    }
                    .disabled(selectedBundleID == nil)
                    Button("Delete") {
                        guard let selectedBundleID else { return }
                        store.draft.activeRescanBundleIDs.removeAll { $0 == selectedBundleID }
                        self.selectedBundleID = nil
                    }
                    .disabled(selectedBundleID == nil)
                }

                List(selection: $selectedBundleID) {
                    ForEach(store.draft.activeRescanBundleIDs, id: \.self) { bundleID in
                        Text(bundleID)
                            .tag(bundleID)
                            .onTapGesture(count: 2) {
                                selectedBundleID = bundleID
                                bundleEditor = BundleEditor(originalValue: bundleID, value: bundleID)
                            }
                    }
                }
                .frame(height: 150)
            }
        }
    }

    private func bundleEditorSheet(_ initial: BundleEditor) -> some View {
        BundleEditorSheet(initialValue: initial.value) { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let original = initial.originalValue,
               let index = store.draft.activeRescanBundleIDs.firstIndex(of: original)
            {
                store.draft.activeRescanBundleIDs[index] = trimmed
                store.draft.activeRescanBundleIDs = MiriConfig.normalizeBundleIDs(
                    store.draft.activeRescanBundleIDs
                ) ?? []
            } else {
                addBundleID(trimmed)
            }
            selectedBundleID = trimmed
            bundleEditor = nil
        } cancel: {
            bundleEditor = nil
        }
    }

    private func addBundleID(_ bundleID: String) {
        store.draft.activeRescanBundleIDs.append(bundleID)
        store.draft.activeRescanBundleIDs = MiriConfig.normalizeBundleIDs(
            store.draft.activeRescanBundleIDs
        ) ?? []
        selectedBundleID = bundleID
    }
}

private struct BundleEditorSheet: View {
    @State private var value: String
    let save: (String) -> Void
    let cancel: () -> Void

    init(initialValue: String, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        _value = State(initialValue: initialValue)
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MiriTheme.Spacing.control) {
            Text("Bundle Identifier")
                .font(MiriTheme.Typography.sectionTitle)
            TextField("com.example.application", text: $value)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(value) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(MiriTheme.Spacing.page)
    }
}
