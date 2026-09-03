import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        MiriPageScrollContainer {
            MiriSection(
                title: "Permissions",
                detail: "Miri checks access in place, just like onboarding."
            ) {
                MiriSettingGroup {
                    MiriPermissionRow(
                        kind: .accessibility,
                        state: store.permissions.accessibility,
                        request: store.requestAccessibilityPermission
                    )
                    MiriRowDivider()
                    MiriPermissionRow(
                        kind: .screenRecording,
                        state: store.permissions.screenRecording,
                        request: store.requestScreenRecordingPermission,
                        restart: { _ = store.saveAndRestart() }
                    )
                }
            }

            MiriSection(title: "Window state") {
                MiriSettingGroup {
                    MiriToggleRow(
                        title: "Restore windows on quit",
                        detail: "Return managed windows to their original frames when Miri exits normally.",
                        value: $store.draft.restoreOnExit
                    )
                    MiriRowDivider()
                    MiriToggleRow(
                        title: "Persist layout",
                        detail: "Remember workspaces, column positions, widths, and focus between launches.",
                        value: $store.draft.persistLayout
                    )
                }
            }
        }
    }
}
