import SwiftUI

struct WorkspaceBarSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        MiriPageScrollContainer {
            MiriSection(title: "Content") {
                MiriSettingGroup {
                    MiriToggleRow(
                        title: "Show fullscreen apps",
                        detail: "Include remembered native-fullscreen applications.",
                        value: $store.draft.workspaceBarShowFullscreen
                    )
                    MiriRowDivider()
                    MiriIntegerSliderRow(
                        title: "Visible app icons",
                        detail: "Maximum app icons shown for each workspace.",
                        value: $store.draft.workspaceBarVisibleIconCount,
                        range: 1...6
                    )
                    MiriRowDivider()
                    MiriPickerRow(
                        title: "Overflow indicator",
                        options: [
                            ("Plus and count", WorkspaceBarOverflowStyle.plusCount),
                            ("Dots and count", WorkspaceBarOverflowStyle.dotsCount),
                            ("Chevron", WorkspaceBarOverflowStyle.chevron),
                            ("None", WorkspaceBarOverflowStyle.none),
                        ],
                        selection: $store.draft.workspaceBarOverflowStyle
                    )
                }
            }

            MiriSection(title: "Appearance") {
                MiriSettingGroup {
                    MiriPickerRow(
                        title: "Active workspace",
                        detail: "Visual treatment for the current workspace.",
                        options: [
                            ("Braces", WorkspaceBarActiveStyle.braces),
                            ("Filled pointer", WorkspaceBarActiveStyle.filledPointer),
                            ("Filled dot", WorkspaceBarActiveStyle.filledDot),
                            ("Square brackets", WorkspaceBarActiveStyle.squareBrackets),
                            ("Angle brackets", WorkspaceBarActiveStyle.angleBrackets),
                            ("Outline", WorkspaceBarActiveStyle.outline),
                            ("Filled outline", WorkspaceBarActiveStyle.filledOutline),
                        ],
                        selection: $store.draft.workspaceBarActiveStyle
                    )
                    MiriRowDivider()
                    MiriPickerRow(
                        title: "Center app strip",
                        options: [
                            ("Delimiter", WorkspaceBarCenterStyle.delimiter),
                            ("Border", WorkspaceBarCenterStyle.border),
                            ("Filled border", WorkspaceBarCenterStyle.filledBorder),
                        ],
                        selection: $store.draft.workspaceBarCenterStyle
                    )
                    MiriRowDivider()
                    MiriSettingRow(
                        title: "Accent colors",
                        detail: "Use the system accent or choose focused-window and border colors."
                    ) {
                        colorControls
                    }
                    MiriRowDivider()
                    MiriIntegerSliderRow(
                        title: "Center border outset",
                        value: $store.draft.workspaceBarCenterBorderOutset,
                        range: 0...5
                    )
                    MiriRowDivider()
                    MiriIntegerSliderRow(
                        title: "Center border thickness",
                        value: $store.draft.workspaceBarCenterBorderThickness,
                        range: 1...3
                    )
                }
            }
        }
    }

    private var colorControls: some View {
        VStack(alignment: .leading, spacing: MiriTheme.Spacing.compact) {
            Toggle("Use custom colors", isOn: $store.draft.workspaceBarUseCustomColors)
                .toggleStyle(.checkbox)
            if store.draft.workspaceBarUseCustomColors {
                colorPicker(
                    "Focused window",
                    setting: $store.draft.workspaceBarHighlightColor
                )
                colorPicker(
                    "Borders and delimiters",
                    setting: $store.draft.workspaceBarDelimiterColor
                )
            }
        }
    }

    private func colorPicker(_ title: String, setting: Binding<String>) -> some View {
        ColorPicker(
            title,
            selection: Binding(
                get: { MiriColorCodec.color(from: setting.wrappedValue) },
                set: { setting.wrappedValue = MiriColorCodec.setting(from: $0) }
            ),
            supportsOpacity: false
        )
        .frame(width: MiriTheme.Size.controlWidth)
    }
}
