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

            MiriSection(title: "Layout fullscreen") {
                MiriSettingGroup {
                    MiriPickerRow(
                        title: "Fullscreen behavior",
                        detail: "Apply layout fullscreen to a workspace or remember it for individual windows.",
                        options: [
                            ("Per workspace", LayoutFullscreenMode.perWorkspace),
                            ("Per window", LayoutFullscreenMode.perWindow),
                        ],
                        selection: $store.draft.layoutFullscreenMode
                    )
                    if store.draft.layoutFullscreenMode == .perWindow {
                        MiriRowDivider()
                        MiriPickerRow(
                            title: "Vertical navigation while fullscreen",
                            detail: "Focus windows first tries the next row in the column, then falls back to held workspace navigation.",
                            options: [
                                ("Switch workspaces", FullscreenVerticalNavigation.switchWorkspaces),
                                ("Focus windows first", FullscreenVerticalNavigation.focusWindowsFirst),
                            ],
                            selection: $store.draft.fullscreenVerticalNavigation
                        )
                    }
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

            MiriSection(
                title: "Stacked columns",
                detail: "Capacity is a maximum, not an automatic stack. New windows always open in their own column; a lone window fills the height. Reducing capacity splits excess rows into new columns."
            ) {
                MiriSettingGroup {
                    MiriPickerRow(
                        title: "Maximum rows per column",
                        options: [("1 row", 1), ("2 rows", 2), ("3 rows", 3)],
                        selection: $store.draft.rowsPerColumn
                    )
                    MiriRowDivider()
                    MiriTextFieldRow(
                        title: "Height presets",
                        detail: "Comma-separated ratios greater than 0 and less than 1 used by height cycling shortcuts.",
                        text: SettingsTextBinding.decimalList($store.draft.heightPresetRatios)
                    )
                }
            }

            MiriSection(
                title: "Workspace navigation",
                detail: "Relative workspace moves require holding the shortcut. Row moves and numbered workspace shortcuts are immediate. Releasing early cancels the crossing."
            ) {
                MiriSettingGroup {
                    MiriIntegerSliderRow(
                        title: "Boundary hold duration",
                        detail: "750ms is the default.",
                        value: $store.draft.workspaceBoundaryHoldMS,
                        range: 10...2000,
                        step: 10,
                        suffix: "ms"
                    )
                }
            }

            MiriSection(title: "Window dragging") {
                MiriSettingGroup {
                    MiriIntegerSliderRow(
                        title: "Edge-scroll speed",
                        detail: "Scroll the layout while holding a window at the screen edge. 100% is the default speed.",
                        value: $store.draft.dragScrollSpeedPercent,
                        range: 25...500,
                        step: 25,
                        suffix: "%"
                    )
                }
            }

            MiriSection(title: "Floating windows") {
                MiriSettingGroup {
                    MiriToggleRow(
                        title: "Show outline for manually floated windows",
                        detail: "Accent-tinted glass that follows the window's corners. Rule-floated and ignored windows are never outlined.",
                        value: $store.draft.manualFloatingOutlineEnabled
                    )
                    MiriRowDivider()
                    MiriIntegerSliderRow(
                        title: "Outline thickness",
                        detail: "Measured in points. 2pt is the default.",
                        value: $store.draft.manualFloatingOutlineThickness,
                        range: 1...10,
                        suffix: "pt"
                    )
                    .disabled(!store.draft.manualFloatingOutlineEnabled)
                    .opacity(store.draft.manualFloatingOutlineEnabled ? 1 : 0.45)
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
                        detail: "Physical pixels between adjacent columns and stacked rows.",
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
