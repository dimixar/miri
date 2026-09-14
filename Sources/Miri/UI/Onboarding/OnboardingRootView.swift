import SwiftUI

struct OnboardingRootView: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        MiriWindowSurface {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 30)
                    .padding(.horizontal, MiriTheme.Spacing.windowTop)

                contentPage
                    .id(model.progress.step)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, MiriTheme.Spacing.windowTop)
                    .padding(.vertical, 20)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))

                footer
                    .padding(.horizontal, MiriTheme.Spacing.windowTop)
                    .padding(.bottom, MiriTheme.Spacing.section)
            }
            .animation(.easeInOut(duration: 0.32), value: model.progress.step)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(progressColor(index))
                        .frame(width: index == model.stepIndex ? 24 : 7, height: 6)
                }
            }
            Text(model.title)
                .font(MiriTheme.Typography.onboardingTitle)
            Text(model.subtitle)
                .font(MiriTheme.Typography.onboardingSubtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Nothing is tiled until setup is complete.")
                .font(MiriTheme.Typography.onboardingNote)
                .foregroundStyle(.tertiary)
            Spacer()
            if model.canGoBack {
                Button("Back") { model.goBack() }
                    .frame(minWidth: 82)
            }
            Button(model.nextTitle) { model.goNext() }
                .buttonStyle(MiriPrimaryButtonStyle())
                .frame(minWidth: 110)
                .disabled(!model.canGoNext)
                .opacity(model.canGoNext ? 1 : 0.42)
                .keyboardShortcut(.defaultAction)
        }
        .frame(height: 34)
    }

    @ViewBuilder
    private var contentPage: some View {
        switch model.progress.step {
        case .accessibility:
            accessibilityPage
        case .layout:
            layoutPage
        case .animation:
            animationPage
        case .ready:
            readyPage
        case .completed:
            EmptyView()
        }
    }

    private var accessibilityPage: some View {
        centeredPage {
            heroSymbol("accessibility", color: MiriTheme.Palette.accent)
            pageHeading("Accessibility access")
            pageBody(
                "Miri uses macOS Accessibility only to discover, focus, move, and resize windows. It does not read typed text or document contents."
            )
            MiriStatusBadge(
                text: accessibilityGranted
                    ? "Accessibility access granted"
                    : "Waiting for Accessibility access",
                kind: accessibilityGranted ? .success : .warning
            )
            if !accessibilityGranted {
                Button("Grant Accessibility Access…") {
                    model.requestAccessibility()
                }
                .buttonStyle(MiriPrimaryButtonStyle())
                secondaryNote(
                    "After enabling Miri in System Settings, return here. This page checks automatically; press Next when it turns green."
                )
            } else {
                secondaryNote("All set. Miri will still wait for you to press Next.")
            }
        }
    }

    private var layoutPage: some View {
        centeredPage {
            HStack(spacing: MiriTheme.Spacing.control) {
                onboardingLayoutChoice(
                    .default,
                    title: "Default",
                    detail: "Keeps the active window visible with minimal movement."
                )
                onboardingLayoutChoice(
                    .centered,
                    title: "Centered",
                    detail: "Always places the active window in the center."
                )
                onboardingLayoutChoice(
                    .centeredSmart,
                    title: "Centered Smart",
                    detail: "Fits wide windows with a neighbor when possible. Centers a lone window."
                )
            }
            .frame(width: MiriTheme.Size.onboardingContentWidth)

            MiriPanel(horizontalPadding: MiriTheme.Spacing.rowVertical, verticalPadding: 14) {
                VStack(spacing: 9) {
                    HStack {
                        Text("Outer margin")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("\(Int(model.progress.outerGap.rounded())) pt")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.progress.outerGap, in: 0...48, step: 1)
                    secondaryNote(
                        "Space between managed windows and the usable edge of the display."
                    )
                }
            }
            .frame(width: MiriTheme.Size.onboardingContentWidth)
        }
    }

    private var animationPage: some View {
        centeredPage(spacing: MiriTheme.Spacing.control) {
            AnimationPreviewRepresentable(mode: model.progress.animationsEnabled)
                .id(model.progress.animationsEnabled)
                .frame(width: 430, height: 92)

            HStack(spacing: MiriTheme.Spacing.control) {
                onboardingAnimationChoice(
                    enabled: false,
                    title: "Instant",
                    symbol: "bolt.fill",
                    detail: "The same focus changes, applied immediately without tweening."
                )
                onboardingAnimationChoice(
                    enabled: true,
                    title: "Smooth snapshots",
                    symbol: "sparkles",
                    detail: "Fluid compositor-backed transitions between focus states."
                )
            }
            .frame(width: MiriTheme.Size.onboardingContentWidth)

            animationDetails
                .frame(width: MiriTheme.Size.onboardingContentWidth)
                .frame(minHeight: 112)
        }
    }

    @ViewBuilder
    private var animationDetails: some View {
        if let enabled = model.progress.animationsEnabled {
            if enabled {
                VStack(spacing: 7) {
                    secondaryNote(
                        "Screen Recording is used only to capture images of your open windows for animation frames—nothing is recorded, stored, or transmitted."
                    )
                    switch model.permissions.screenRecording {
                    case .missing:
                        Button("Grant Screen Recording Access…") {
                            model.requestScreenRecording()
                        }
                        .buttonStyle(MiriPrimaryButtonStyle())
                    case .restartRequired:
                        HStack(spacing: 9) {
                            MiriStatusBadge(text: "Access granted — restart required", kind: .success)
                            Button("Restart Miri and Continue") {
                                model.restartForScreenRecording()
                            }
                            .buttonStyle(MiriPrimaryButtonStyle())
                        }
                    case .granted:
                        MiriStatusBadge(text: "Screen Recording access granted", kind: .success)
                    }
                }
            } else {
                secondaryNote(
                    "Instant mode follows the same focus sequence above, but switches between each state immediately and needs no additional permission."
                )
            }
        } else {
            secondaryNote("Choose an animation style to continue.")
        }
    }

    private var readyPage: some View {
        centeredPage {
            heroSymbol("checkmark.circle.fill", color: MiriTheme.Palette.success)
            pageHeading("Setup complete")
            MiriPanel(horizontalPadding: 18, verticalPadding: MiriTheme.Spacing.rowVertical) {
                VStack(spacing: 10) {
                    summaryRow(
                        symbol: "rectangle.3.group",
                        title: "Layout",
                        value: alignmentTitle
                    )
                    summaryRow(
                        symbol: "arrow.down.right.and.arrow.up.left",
                        title: "Outer margin",
                        value: "\(Int(model.progress.outerGap.rounded())) pt"
                    )
                    summaryRow(
                        symbol: "sparkles",
                        title: "Transitions",
                        value: model.progress.animationsEnabled == true ? "Smooth snapshots" : "Instant"
                    )
                }
            }
            .frame(width: MiriTheme.Size.onboardingSummaryWidth)
            secondaryNote(
                "Click Start using Miri when you’re ready. Window discovery and tiling begin only then."
            )
        }
    }

    private var accessibilityGranted: Bool {
        model.permissions.accessibility != .missing
    }

    private var alignmentTitle: String {
        switch model.progress.focusAlignment {
        case .default: return "Default"
        case .centered: return "Centered"
        case .centeredSmart: return "Centered Smart"
        }
    }

    private func progressColor(_ index: Int) -> Color {
        guard index <= model.stepIndex else {
            return Color(nsColor: .separatorColor).opacity(0.55)
        }
        return [
            MiriTheme.Palette.accent,
            MiriTheme.Palette.warning,
            MiriTheme.Palette.success,
            Color(nsColor: MiriTheme.Palette.paper),
        ][index]
    }

    private func centeredPage<Content: View>(
        spacing: CGFloat = 18,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: spacing, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func heroSymbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 48, weight: .medium))
            .foregroundStyle(color)
            .frame(height: 58)
    }

    private func pageHeading(_ text: String) -> some View {
        Text(text)
            .font(MiriTheme.Typography.onboardingHeading)
            .multilineTextAlignment(.center)
    }

    private func pageBody(_ text: String) -> some View {
        Text(text)
            .font(MiriTheme.Typography.onboardingBody)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 590)
    }

    private func secondaryNote(_ text: String) -> some View {
        Text(text)
            .font(MiriTheme.Typography.onboardingNote)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 590)
    }

    private func onboardingLayoutChoice(
        _ alignment: FocusAlignment,
        title: String,
        detail: String
    ) -> some View {
        MiriChoiceCard(
            title: title,
            detail: detail,
            isSelected: model.progress.focusAlignment == alignment,
            action: { model.progress.focusAlignment = alignment }
        ) {
            LayoutPreviewRepresentable(alignment: alignment)
                .frame(height: 62)
        }
    }

    private func onboardingAnimationChoice(
        enabled: Bool,
        title: String,
        symbol: String,
        detail: String
    ) -> some View {
        MiriChoiceCard(
            title: title,
            detail: detail,
            isSelected: model.progress.animationsEnabled == enabled,
            action: { model.progress.animationsEnabled = enabled }
        ) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(
                    model.progress.animationsEnabled == enabled
                        ? MiriTheme.Palette.accent
                        : Color.secondary
                )
                .frame(height: 28)
        }
    }

    private func summaryRow(symbol: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(MiriTheme.Palette.accent)
                .frame(width: 20)
            Text(title)
                .font(MiriTheme.Typography.rowTitle)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
