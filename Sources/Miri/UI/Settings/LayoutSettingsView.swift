import SwiftUI

struct LayoutSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        MiriPageScrollContainer {
            MiriSection(
                title: "Focus alignment",
                detail: "The same layout choices shown during onboarding."
            ) {
                HStack(spacing: MiriTheme.Spacing.compact) {
                    layoutChoice(
                        .default,
                        title: "Default",
                        detail: "Reveals the focused window with minimal movement."
                    )
                    layoutChoice(
                        .centered,
                        title: "Centered",
                        detail: "Keeps the focused window centered."
                    )
                    layoutChoice(
                        .centeredSmart,
                        title: "Centered Smart",
                        detail: "Fits wide windows with a neighbor when possible. Centers a lone window."
                    )
                }
            }

            MiriSection(title: "Column sizing") {
                MiriSettingGroup {
                    MiriTextFieldRow(
                        title: "Default width",
                        detail: "Fraction of the usable display width.",
                        text: SettingsTextBinding.decimal($store.draft.defaultWidthRatio)
                    )
                    MiriRowDivider()
                    MiriTextFieldRow(
                        title: "Width presets",
                        detail: "Comma-separated ratios used by width cycling shortcuts.",
                        text: SettingsTextBinding.decimalList($store.draft.presetWidthRatios)
                    )
                    MiriRowDivider()
                    MiriPickerRow(
                        title: "Resize behavior",
                        options: [
                            ("Standard", WidthResizeMode.default),
                            ("Intelligent", WidthResizeMode.intelligent),
                        ],
                        selection: $store.draft.widthResizeMode
                    )
                    MiriRowDivider()
                    MiriPickerRow(
                        title: "New windows",
                        detail: "Where a newly managed column enters the layout.",
                        options: [
                            ("Before active window", NewWindowPosition.beforeActive),
                            ("After active window", NewWindowPosition.afterActive),
                            ("At the end", NewWindowPosition.end),
                        ],
                        selection: $store.draft.newWindowPosition
                    )
                }
            }

            MiriSection(title: "Spacing and workspaces") {
                MiriSettingGroup {
                    MiriIntegerSliderRow(
                        title: "Pre-created workspaces",
                        detail: "Always keep this many numbered workspaces available.",
                        value: $store.draft.minimumWorkspaceCount,
                        range: 1...9
                    )
                    MiriRowDivider()
                    MiriToggleRow(
                        title: "Back-and-forth switching",
                        detail: "Selecting the active workspace returns to the previous one.",
                        value: $store.draft.workspaceAutoBackAndForth
                    )
                    MiriRowDivider()
                    pointsRow(
                        title: "Inner gap",
                        detail: "Physical pixels between adjacent columns.",
                        value: $store.draft.innerGap
                    )
                    MiriRowDivider()
                    pointsRow(
                        title: "Outer gap",
                        detail: "Physical pixels between windows and the usable display edge.",
                        value: $store.draft.outerGap
                    )
                    MiriRowDivider()
                    pointsRow(
                        title: "Parked sliver",
                        detail: "Visible edge retained while windows are staged off-screen.",
                        value: $store.draft.parkedSliverWidth
                    )
                }
            }
        }
    }

    private func layoutChoice(_ alignment: FocusAlignment, title: String, detail: String) -> some View {
        MiriChoiceCard(
            title: title,
            detail: detail,
            isSelected: store.draft.focusAlignment == alignment,
            action: { store.draft.focusAlignment = alignment }
        ) {
            LayoutPreviewRepresentable(alignment: alignment)
                .frame(width: 138, height: 62)
        }
    }

    private func pointsRow(
        title: String,
        detail: String,
        value: Binding<CGFloat>
    ) -> some View {
        MiriSettingRow(title: title, detail: detail) {
            HStack(spacing: MiriTheme.Spacing.inline) {
                let text = SettingsTextBinding.decimal(value)
                MiriBufferedTextField(value: text.wrappedValue) { text.wrappedValue = $0 }
                    .frame(width: 80)
                    .accessibilityLabel(title)
                Text("px")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
