import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject var store: SettingsStore

    private struct CommandGroup {
        let title: String
        let detail: String
        let includes: (String) -> Bool
    }

    private let groups: [CommandGroup] = [
        CommandGroup(
            title: "Workspace navigation",
            detail: "Focus and move between Miri workspaces.",
            includes: { $0.contains("workspace") && !$0.hasPrefix("move_column") }
        ),
        CommandGroup(
            title: "Column navigation",
            detail: "Move focus within the current workspace.",
            includes: { $0.hasPrefix("column_") }
        ),
        CommandGroup(
            title: "Move columns",
            detail: "Reorder columns or send them to another workspace.",
            includes: { $0.hasPrefix("move_column") }
        ),
        CommandGroup(
            title: "Resize columns",
            detail: "Cycle presets or nudge one or every column.",
            includes: { $0.contains("width") }
        ),
    ]

    var body: some View {
        MiriPageScrollContainer {
            MiriSection(title: "Shortcut handling") {
                MiriSettingGroup {
                    MiriSettingRow(title: "Input backend") {
                        VStack(alignment: .trailing, spacing: 5) {
                            Picker("", selection: $store.draft.keyboardShortcutBackend) {
                                Text("Full Compatibility").tag(KeyboardShortcutBackend.eventTap)
                                Text("Registered Shortcuts").tag(KeyboardShortcutBackend.registeredHotKeys)
                            }
                            .labelsHidden()
                            .frame(width: MiriTheme.Size.controlWidth)
                            Text(backendHelp)
                                .font(MiriTheme.Typography.rowDetail)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 300, alignment: .trailing)
                        }
                    }
                    MiriRowDivider()
                    MiriTextFieldRow(
                        title: "Excluded shortcuts",
                        detail: "Comma-separated shortcuts that always pass through in Full Compatibility mode.",
                        text: SettingsTextBinding.stringList($store.draft.excludedKeybindings)
                    )
                }
            }

            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                commandSection(group)
            }
        }
    }

    private func commandSection(_ group: CommandGroup) -> some View {
        let commands = MiriConfig.defaultKeybindings.keys.sorted().filter(group.includes)
        return MiriSection(title: group.title, detail: group.detail) {
            MiriSettingGroup {
                ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                    MiriTextFieldRow(
                        title: humanizedCommand(command),
                        detail: command,
                        text: keybinding(for: command)
                    )
                    if index < commands.count - 1 {
                        MiriRowDivider()
                    }
                }
            }
        }
    }

    private func keybinding(for command: String) -> Binding<String> {
        Binding(
            get: { (store.draft.keybindings[command] ?? []).joined(separator: ", ") },
            set: { text in
                store.draft.keybindings[command] = text
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var backendHelp: String {
        switch store.draft.keyboardShortcutBackend {
        case .eventTap:
            return "Full compatibility. Supports left/right Option shortcuts and excluded shortcuts, and can consume matching keys."
        case .registeredHotKeys:
            return "Lower idle overhead. macOS wakes Miri only for registered shortcuts, but cannot distinguish left and right Option."
        }
    }

    private func humanizedCommand(_ command: String) -> String {
        command.split(separator: "_").map { part in
            switch part.lowercased() {
            case "all": return "All"
            case "to": return "to"
            default: return part.prefix(1).uppercased() + part.dropFirst()
            }
        }.joined(separator: " ")
    }
}
