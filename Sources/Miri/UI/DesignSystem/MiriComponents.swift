import SwiftUI

struct MiriWindowSurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: MiriTheme.Palette.graphite),
                    Color(nsColor: MiriTheme.Palette.charcoal),
                    Color(nsColor: .windowBackgroundColor),
                ],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )
            RadialGradient(
                colors: [MiriTheme.Palette.accent.opacity(0.08), .clear],
                center: UnitPoint(x: 0.70, y: 0.58),
                startRadius: 0,
                endRadius: 390
            )

            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MiriTheme.Radius.window, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: MiriTheme.Radius.window, style: .continuous)
                        .stroke(MiriTheme.Palette.separator, lineWidth: 1)
                }
                .padding(.top, MiriTheme.Spacing.windowTop)
                .padding(.horizontal, MiriTheme.Spacing.windowHorizontal)
                .padding(.bottom, MiriTheme.Spacing.windowBottom)
        }
        .ignoresSafeArea()
    }
}

struct MiriPageHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: MiriTheme.Spacing.header) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(MiriTheme.Palette.accent)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(MiriTheme.Typography.pageTitle)
                Text(subtitle)
                    .font(MiriTheme.Typography.pageSubtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MiriPageScrollContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MiriTheme.Spacing.section) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MiriTheme.Spacing.compact)
            .padding(.top, 4)
            .padding(.bottom, MiriTheme.Spacing.section)
        }
    }
}

struct MiriSection<Content: View>: View {
    let title: String
    let detail: String?
    private let content: Content

    init(
        title: String,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MiriTheme.Spacing.compact) {
            Text(title)
                .font(MiriTheme.Typography.sectionTitle)
            if let detail {
                Text(detail)
                    .font(MiriTheme.Typography.sectionDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MiriPanel<Content: View>: View {
    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat
    private let content: Content

    init(
        horizontalPadding: CGFloat = MiriTheme.Spacing.rowHorizontal,
        verticalPadding: CGFloat = MiriTheme.Spacing.rowVertical,
        @ViewBuilder content: () -> Content
    ) {
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MiriTheme.Radius.panel, style: .continuous)
                    .fill(MiriTheme.Palette.panel)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MiriTheme.Radius.panel, style: .continuous)
                    .stroke(MiriTheme.Palette.separator, lineWidth: 1)
            }
    }
}

struct MiriSettingRow<Trailing: View>: View {
    let title: String
    let detail: String?
    private let trailing: Trailing

    init(
        title: String,
        detail: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: MiriTheme.Spacing.rowHorizontal) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(MiriTheme.Typography.rowTitle)
                if let detail {
                    Text(detail)
                        .font(MiriTheme.Typography.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, MiriTheme.Spacing.rowHorizontal)
        .padding(.vertical, MiriTheme.Spacing.rowVertical)
        .frame(maxWidth: .infinity)
    }
}

struct MiriSettingGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: MiriTheme.Radius.panel, style: .continuous)
                .fill(MiriTheme.Palette.panel)
        )
        .overlay {
            RoundedRectangle(cornerRadius: MiriTheme.Radius.panel, style: .continuous)
                .stroke(MiriTheme.Palette.separator, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: MiriTheme.Radius.panel, style: .continuous))
    }
}

struct MiriRowDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, MiriTheme.Spacing.rowHorizontal)
    }
}

struct MiriToggleRow: View {
    let title: String
    let detail: String?
    @Binding var value: Bool

    init(title: String, detail: String? = nil, value: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _value = value
    }

    var body: some View {
        MiriSettingRow(title: title, detail: detail) {
            Toggle("", isOn: $value)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }
}

struct MiriPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, MiriTheme.Spacing.control)
            .frame(minWidth: MiriTheme.Size.primaryButtonWidth, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: MiriTheme.Radius.button, style: .continuous)
                    .fill(MiriTheme.Palette.accent.opacity(configuration.isPressed ? 0.78 : 1))
            )
    }
}

struct MiriChoiceCard<Preview: View>: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void
    private let preview: Preview

    init(
        title: String,
        detail: String,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder preview: () -> Preview
    ) {
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.action = action
        self.preview = preview()
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                preview
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(.horizontal, MiriTheme.Spacing.control)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 112)
            .background(
                RoundedRectangle(cornerRadius: MiriTheme.Radius.choice, style: .continuous)
                    .fill(isSelected ? MiriTheme.Palette.accent.opacity(0.13) : MiriTheme.Palette.panel)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MiriTheme.Radius.choice, style: .continuous)
                    .stroke(
                        isSelected ? MiriTheme.Palette.accent : MiriTheme.Palette.separator,
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: MiriTheme.Radius.choice, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

struct MiriStatusBadge: View {
    enum Kind {
        case neutral
        case warning
        case success
        case error

        var color: Color {
            switch self {
            case .neutral: return .secondary
            case .warning: return MiriTheme.Palette.warning
            case .success: return MiriTheme.Palette.success
            case .error: return .red
            }
        }
    }

    let text: String
    let kind: Kind

    var body: some View {
        Text(text)
            .font(MiriTheme.Typography.status)
            .foregroundStyle(kind.color)
    }
}

enum MiriPermissionKind {
    case accessibility
    case screenRecording

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }

    var detail: String {
        switch self {
        case .accessibility:
            return "Required to discover, focus, move, and resize windows."
        case .screenRecording:
            return "Used only to capture temporary window images for snapshot animations."
        }
    }
}

struct MiriPermissionRow: View {
    let kind: MiriPermissionKind
    let state: MiriPermissionState
    let request: () -> Void
    var restart: (() -> Void)?

    var body: some View {
        MiriSettingRow(title: kind.title, detail: kind.detail) {
            VStack(alignment: .trailing, spacing: 5) {
                MiriStatusBadge(text: statusText, kind: statusKind)
                if let actionTitle {
                    Button(actionTitle, action: action)
                }
            }
        }
    }

    private var statusText: String {
        switch state {
        case .missing: return "Access needed"
        case .restartRequired: return "Granted · restart required"
        case .granted: return "Access granted"
        }
    }

    private var statusKind: MiriStatusBadge.Kind {
        state == .missing ? .warning : .success
    }

    private var actionTitle: String? {
        switch state {
        case .missing: return "Grant Access…"
        case .restartRequired where restart != nil: return "Save & Restart Miri"
        case .restartRequired, .granted: return nil
        }
    }

    private var action: () -> Void {
        switch state {
        case .missing: return request
        case .restartRequired: return restart ?? {}
        case .granted: return {}
        }
    }
}

struct MiriLabeledSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: (Double) -> String

    var body: some View {
        HStack(spacing: MiriTheme.Spacing.compact) {
            Slider(value: $value, in: range, step: step)
                .frame(width: MiriTheme.Size.sliderWidth)
            Text(valueText(value))
                .frame(width: MiriTheme.Size.valueLabelWidth, alignment: .leading)
                .monospacedDigit()
        }
    }
}

struct MiriActionFooter: View {
    let feedback: SettingsStore.Feedback
    let isDirty: Bool
    let revert: () -> Void
    let cancel: () -> Void
    let apply: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            MiriStatusBadge(text: feedbackText, kind: feedbackKind)
                .lineLimit(1)
            Spacer()
            Button("Revert", action: revert)
                .disabled(!isDirty)
            Button("Cancel", action: cancel)
            Button("Apply", action: apply)
                .disabled(!isDirty)
            Button("Save", action: save)
                .buttonStyle(MiriPrimaryButtonStyle())
                .disabled(!isDirty)
                .opacity(isDirty ? 1 : 0.45)
                .keyboardShortcut("s", modifiers: .command)
        }
        .frame(height: 32)
    }

    private var feedbackText: String {
        switch feedback {
        case .none: return isDirty ? "Unsaved changes" : "All changes saved"
        case .saving: return "Saving…"
        case .saved: return "Saved and reloaded"
        case let .error(message): return message
        }
    }

    private var feedbackKind: MiriStatusBadge.Kind {
        switch feedback {
        case .saved: return .success
        case .error: return .error
        case .none, .saving: return .neutral
        }
    }
}
