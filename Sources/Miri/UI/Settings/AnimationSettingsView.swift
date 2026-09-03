import SwiftUI

struct AnimationSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        MiriPageScrollContainer {
            MiriSection(
                title: "Transition style",
                detail: "Choose immediate updates or compositor-backed movement."
            ) {
                VStack(spacing: MiriTheme.Spacing.compact) {
                    MiriPanel(horizontalPadding: 18, verticalPadding: 8) {
                        AnimationPreviewRepresentable(animated: snapshotsEnabled)
                            .id(store.draft.animationStrategy)
                            .frame(height: 80)
                    }

                    HStack(spacing: MiriTheme.Spacing.compact) {
                        animationChoice(
                            .off,
                            title: "Instant",
                            symbol: "bolt.fill",
                            detail: "Apply every focus and layout change immediately."
                        )
                        animationChoice(
                            .snapshot,
                            title: "Smooth snapshots",
                            symbol: "sparkles",
                            detail: "Animate temporary window images between focus states."
                        )
                    }
                }
            }

            MiriSection(title: "Screen Recording") {
                MiriSettingGroup {
                    MiriSettingRow(
                        title: "Permission status",
                        detail: "No images are recorded, stored, or transmitted."
                    ) {
                        permissionControl
                    }
                }
            }

            MiriSection(
                title: "Snapshot performance",
                detail: "These controls apply only to Smooth snapshots."
            ) {
                MiriSettingGroup {
                    MiriIntegerSliderRow(
                        title: "Movement speed",
                        value: $store.draft.snapshotAnimationSpeed,
                        range: 1...100
                    )
                    MiriRowDivider()
                    MiriTextFieldRow(
                        title: "Frame rate",
                        detail: "Manual snapshot runner frame rate.",
                        text: SettingsTextBinding.integer($store.draft.animationFPS)
                    )
                    MiriRowDivider()
                    MiriTextFieldRow(
                        title: "Pixel threshold",
                        detail: "Distance at which a snapshot snaps to its final position.",
                        text: SettingsTextBinding.decimal($store.draft.animationPixelThreshold)
                    )
                }
                .opacity(snapshotsEnabled ? 1 : 0.48)
            }
        }
    }

    private var snapshotsEnabled: Bool {
        store.draft.animationStrategy == .snapshot
    }

    private func animationChoice(
        _ strategy: AnimationStrategy,
        title: String,
        symbol: String,
        detail: String
    ) -> some View {
        MiriChoiceCard(
            title: title,
            detail: detail,
            isSelected: store.draft.animationStrategy == strategy,
            action: { store.draft.animationStrategy = strategy }
        ) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(
                    store.draft.animationStrategy == strategy
                        ? MiriTheme.Palette.accent
                        : Color.secondary
                )
                .frame(height: 30)
        }
    }

    @ViewBuilder
    private var permissionControl: some View {
        if !snapshotsEnabled {
            MiriStatusBadge(
                text: "No additional permission is needed for Instant mode.",
                kind: .neutral
            )
        } else {
            VStack(alignment: .trailing, spacing: MiriTheme.Spacing.inline) {
                switch store.permissions.screenRecording {
                case .missing:
                    MiriStatusBadge(
                        text: "Access is needed before snapshot animations can run.",
                        kind: .warning
                    )
                    Button("Grant Screen Recording Access…") {
                        store.requestScreenRecordingPermission()
                    }
                case .restartRequired:
                    MiriStatusBadge(text: "Access granted · restart required", kind: .success)
                    Button("Save & Restart Miri") {
                        _ = store.saveAndRestart()
                    }
                case .granted:
                    MiriStatusBadge(text: "Screen Recording access is granted.", kind: .success)
                }
            }
        }
    }
}
