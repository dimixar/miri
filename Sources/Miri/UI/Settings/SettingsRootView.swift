import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    @State private var selection: SettingsRoute = .general
    let requestClose: () -> Void

    var body: some View {
        MiriWindowSurface {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: MiriTheme.Size.sidebarWidth)
                Divider()
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(MiriTheme.Palette.accent)
                    .frame(width: 31, height: 31)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Miri")
                        .font(MiriTheme.Typography.brandTitle)
                    Text("Settings")
                        .font(MiriTheme.Typography.brandSubtitle)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, MiriTheme.Spacing.rowHorizontal)
            .padding(.horizontal, 22)

            VStack(spacing: 2) {
                ForEach(SettingsRoute.allCases) { route in
                    Button {
                        selection = route
                    } label: {
                        HStack(spacing: MiriTheme.Spacing.compact) {
                            Image(systemName: route.symbol)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(
                                    route == selection
                                        ? MiriTheme.Palette.accent
                                        : Color.secondary
                                )
                                .frame(width: 18)
                            Text(route.title)
                                .font(.system(size: 13, weight: route == selection ? .semibold : .regular))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, MiriTheme.Spacing.compact)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: MiriTheme.Radius.button, style: .continuous)
                                .fill(route == selection ? MiriTheme.Palette.accent.opacity(0.12) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 26)
            .padding(.horizontal, 10)

            Spacer()
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            MiriPageHeader(
                symbol: selection.symbol,
                title: selection.title,
                subtitle: selection.subtitle
            )
            .padding(.top, MiriTheme.Spacing.section)
            .padding(.horizontal, MiriTheme.Spacing.page)
            .padding(.bottom, 19)

            selectedPage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, MiriTheme.Spacing.rowHorizontal)
                .padding(.bottom, MiriTheme.Spacing.control)

            Divider()

            MiriActionFooter(
                feedback: store.feedback,
                isDirty: store.isDirty,
                revert: store.revert,
                cancel: requestClose,
                apply: { submit(closeOnSuccess: false) },
                save: { submit(closeOnSuccess: true) }
            )
            .padding(.horizontal, MiriTheme.Spacing.page)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch selection {
        case .general:
            GeneralSettingsView(store: store)
        case .layout:
            LayoutSettingsView(store: store)
        case .animations:
            AnimationSettingsView(store: store)
        case .workspaceBar:
            WorkspaceBarSettingsView(store: store)
        case .shortcuts:
            ShortcutSettingsView(store: store)
        case .rules:
            RuleSettingsView(store: store)
        case .advanced:
            AdvancedSettingsView(store: store)
        }
    }

    private func submit(closeOnSuccess: Bool) {
        if store.draft.validationMessage()?.hasPrefix("Keybinding") == true {
            selection = .shortcuts
        }
        _ = store.submit(closeOnSuccess: closeOnSuccess)
    }
}
