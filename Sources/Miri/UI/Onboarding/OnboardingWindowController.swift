import AppKit
import QuartzCore

private enum MiriOnboardingPalette {
    static let orange = NSColor(srgbRed: 1.00, green: 0.28, blue: 0.12, alpha: 1)
    static let yellow = NSColor(srgbRed: 1.00, green: 0.72, blue: 0.00, alpha: 1)
    static let green = NSColor(srgbRed: 0.00, green: 0.82, blue: 0.22, alpha: 1)
    static let graphite = NSColor(srgbRed: 0.075, green: 0.08, blue: 0.09, alpha: 1)
    static let charcoal = NSColor(srgbRed: 0.14, green: 0.15, blue: 0.16, alpha: 1)
    static let silver = NSColor(srgbRed: 0.82, green: 0.83, blue: 0.85, alpha: 1)
    static let paper = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    private var progress: OnboardingProgress
    private var permissions: MiriPermissionStatus
    private let permissionProvider: () -> MiriPermissionStatus
    private let progressSink: (OnboardingProgress) -> Void
    private let actionSink: (UIAction) -> Void

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let contentHost = NSView()
    private let progressDots = NSStackView()
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private var permissionTimer: Timer?
    private var currentPage: NSView?
    private weak var marginValueLabel: NSTextField?

    init(
        progress: OnboardingProgress,
        permissions: MiriPermissionStatus,
        permissionProvider: @escaping () -> MiriPermissionStatus,
        progressSink: @escaping (OnboardingProgress) -> Void,
        actionSink: @escaping (UIAction) -> Void
    ) {
        self.progress = progress
        self.permissions = permissions
        self.permissionProvider = permissionProvider
        self.progressSink = progressSink
        self.actionSink = actionSink

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Miri"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.minSize = NSSize(width: 760, height: 570)
        super.init(window: window)
        buildUI()
        showCurrentPage(animated: false)
        startPermissionChecks()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func close() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        super.close()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard let window else { return }
        window.center()
        window.alphaValue = 0
        let finalFrame = window.frame
        window.setFrame(finalFrame.insetBy(dx: 14, dy: 10), display: false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(finalFrame, display: true)
        }
    }

    func updatePermissions(_ permissions: MiriPermissionStatus) {
        guard permissions != self.permissions else { return }
        self.permissions = permissions
        if progress.step == .accessibility || progress.step == .animation {
            showCurrentPage(animated: false)
        }
    }

    func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not finish setup"
        alert.informativeText = message
        alert.beginSheetModal(for: window!)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let backdrop = OnboardingBackdropView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backdrop)

        let card = NSVisualEffectView()
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 24
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 7
        header.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(header)

        progressDots.orientation = .horizontal
        progressDots.spacing = 7
        header.addArrangedSubview(progressDots)

        titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
        titleLabel.textColor = .labelColor
        header.addArrangedSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping
        header.addArrangedSubview(subtitleLabel)

        contentHost.wantsLayer = true
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(contentHost)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(footer)

        let privacy = NSTextField(labelWithString: "Nothing is tiled until setup is complete.")
        privacy.textColor = .tertiaryLabelColor
        privacy.font = .systemFont(ofSize: 12)
        footer.addArrangedSubview(privacy)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)

        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.bezelStyle = .rounded
        backButton.focusRingType = .none
        footer.addArrangedSubview(backButton)

        nextButton.target = self
        nextButton.action = #selector(goNext)
        nextButton.isBordered = false
        nextButton.focusRingType = .none
        nextButton.wantsLayer = true
        nextButton.layer?.cornerRadius = 7
        nextButton.layer?.cornerCurve = .continuous
        nextButton.layer?.backgroundColor = MiriOnboardingPalette.orange.cgColor
        nextButton.keyEquivalent = "\r"
        nextButton.contentTintColor = .white
        footer.addArrangedSubview(nextButton)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -28),

            header.topAnchor.constraint(equalTo: card.topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 36),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -36),

            contentHost.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 22),
            contentHost.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 36),
            contentHost.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -36),
            contentHost.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -20),

            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 36),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -36),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            footer.heightAnchor.constraint(equalToConstant: 34),
            backButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 82),
            nextButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
    }

    private func startPermissionChecks() {
        permissionTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(checkPermissions),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func checkPermissions() {
        updatePermissions(permissionProvider())
    }

    private func showCurrentPage(animated: Bool) {
        updateHeader()
        let page: NSView
        switch progress.step {
        case .accessibility: page = accessibilityPage()
        case .layout: page = layoutPage()
        case .animation: page = animationPage()
        case .ready: page = readyPage()
        case .completed: return
        }

        page.translatesAutoresizingMaskIntoConstraints = false
        if animated, let layer = contentHost.layer {
            let transition = CATransition()
            transition.type = .push
            transition.subtype = .fromRight
            transition.duration = 0.32
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(transition, forKey: "onboarding-page")
        }
        currentPage?.removeFromSuperview()
        contentHost.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: contentHost.topAnchor),
            page.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        currentPage = page
        updateNavigation()
    }

    private func updateHeader() {
        switch progress.step {
        case .accessibility:
            titleLabel.stringValue = "Welcome to Miri"
            subtitleLabel.stringValue = "First, allow Miri to arrange your windows. You stay in control of when tiling begins."
        case .layout:
            titleLabel.stringValue = "Make it feel like yours"
            subtitleLabel.stringValue = "Choose how the focused column sits on screen, then set a comfortable outer margin."
        case .animation:
            titleLabel.stringValue = "Smooth or instant?"
            subtitleLabel.stringValue = "Choose snapshot transitions for fluid movement, or keep every layout change immediate."
        case .ready:
            titleLabel.stringValue = "You’re ready"
            subtitleLabel.stringValue = "Miri will now discover your windows and begin managing your desktop."
        case .completed:
            break
        }

        progressDots.arrangedSubviews.forEach { view in
            progressDots.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let activeIndex = stepIndex(progress.step)
        for index in 0..<4 {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            let completedColors = [
                MiriOnboardingPalette.orange,
                MiriOnboardingPalette.yellow,
                MiriOnboardingPalette.green,
                MiriOnboardingPalette.paper,
            ]
            dot.layer?.backgroundColor = (index <= activeIndex
                ? completedColors[index]
                : NSColor.separatorColor.withAlphaComponent(0.55)).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: index == activeIndex ? 24 : 7).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            progressDots.addArrangedSubview(dot)
        }
    }

    private func updateNavigation() {
        backButton.isHidden = progress.step == .accessibility
        nextButton.title = progress.step == .ready ? "Start using Miri" : "Next"
        switch progress.step {
        case .accessibility:
            nextButton.isEnabled = permissions.accessibility != .missing
        case .layout:
            nextButton.isEnabled = true
        case .animation:
            if progress.animationsEnabled == true {
                nextButton.isEnabled = permissions.screenRecording == .granted
            } else {
                nextButton.isEnabled = progress.animationsEnabled == false
            }
        case .ready:
            nextButton.isEnabled = true
        case .completed:
            nextButton.isEnabled = false
        }
        nextButton.alphaValue = nextButton.isEnabled ? 1 : 0.42
    }

    private func accessibilityPage() -> NSView {
        let root = centeredPageStack(spacing: 18)
        root.addArrangedSubview(heroSymbol("accessibility", color: MiriOnboardingPalette.orange))

        let heading = pageHeading("Accessibility access")
        root.addArrangedSubview(heading)
        root.addArrangedSubview(pageBody(
            "Miri uses macOS Accessibility only to discover, focus, move, and resize windows. It does not read typed text or document contents."
        ))

        let granted = permissions.accessibility != .missing
        let status = OnboardingStatusView(
            text: granted ? "Accessibility access granted" : "Waiting for Accessibility access",
            isReady: granted
        )
        root.addArrangedSubview(status)

        if !granted {
            let request = prominentButton("Grant Accessibility Access…", action: #selector(requestAccessibility))
            root.addArrangedSubview(request)
            root.addArrangedSubview(secondaryNote("After enabling Miri in System Settings, return here. This page checks automatically; press Next when it turns green."))
        } else {
            root.addArrangedSubview(secondaryNote("All set. Miri will still wait for you to press Next."))
        }
        return root
    }

    private func layoutPage() -> NSView {
        let root = centeredPageStack(spacing: 18)

        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.alignment = .centerY
        cards.distribution = .fillEqually
        cards.spacing = 12
        for (index, option) in FocusAlignment.guiOptions.enumerated() {
            let description = switch option.alignment {
            case .default: "Keeps the active window visible with minimal movement."
            case .centered: "Always places the active window in the center."
            case .centeredSmart: "Centers wide windows and gently reveals narrow ones."
            }
            let card = LayoutChoiceButton(
                alignment: option.alignment,
                title: option.title,
                detail: description,
                selected: progress.focusAlignment == option.alignment,
                target: self,
                action: #selector(selectLayout(_:))
            )
            card.tag = index
            cards.addArrangedSubview(card)
        }
        root.addArrangedSubview(cards)

        let marginPanel = insetPanel()
        let marginStack = NSStackView()
        marginStack.orientation = .vertical
        marginStack.spacing = 9
        marginStack.translatesAutoresizingMaskIntoConstraints = false
        marginPanel.addSubview(marginStack)

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        let label = NSTextField(labelWithString: "Outer margin")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        titleRow.addArrangedSubview(label)
        let rowSpacer = NSView()
        rowSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.addArrangedSubview(rowSpacer)
        let value = NSTextField(labelWithString: "\(Int(progress.outerGap.rounded())) pt")
        value.textColor = .secondaryLabelColor
        marginValueLabel = value
        titleRow.addArrangedSubview(value)
        marginStack.addArrangedSubview(titleRow)

        let slider = NSSlider(value: progress.outerGap, minValue: 0, maxValue: 48, target: self, action: #selector(marginChanged(_:)))
        slider.isContinuous = true
        slider.numberOfTickMarks = 7
        slider.allowsTickMarkValuesOnly = false
        marginStack.addArrangedSubview(slider)
        marginStack.addArrangedSubview(secondaryNote("Space between managed windows and the usable edge of the display."))

        NSLayoutConstraint.activate([
            marginStack.topAnchor.constraint(equalTo: marginPanel.topAnchor, constant: 14),
            marginStack.leadingAnchor.constraint(equalTo: marginPanel.leadingAnchor, constant: 16),
            marginStack.trailingAnchor.constraint(equalTo: marginPanel.trailingAnchor, constant: -16),
            marginStack.bottomAnchor.constraint(equalTo: marginPanel.bottomAnchor, constant: -14),
            marginPanel.widthAnchor.constraint(equalToConstant: 620),
        ])
        root.addArrangedSubview(marginPanel)
        return root
    }

    private func animationPage() -> NSView {
        let root = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let preview = AnimationPreviewView(mode: progress.animationsEnabled)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 430).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 92).isActive = true
        stack.addArrangedSubview(preview)

        let choices = NSStackView()
        choices.orientation = .horizontal
        choices.spacing = 12
        choices.distribution = .fillEqually
        let instant = OnboardingChoiceButton(
            title: "Instant",
            detail: "The same focus changes, applied immediately without tweening.",
            symbolName: "bolt.fill",
            selected: progress.animationsEnabled == false,
            target: self,
            action: #selector(selectInstantAnimations)
        )
        let smooth = OnboardingChoiceButton(
            title: "Smooth snapshots",
            detail: "Fluid compositor-backed transitions between focus states.",
            symbolName: "sparkles",
            selected: progress.animationsEnabled == true,
            target: self,
            action: #selector(selectSmoothAnimations)
        )
        choices.addArrangedSubview(instant)
        choices.addArrangedSubview(smooth)
        choices.translatesAutoresizingMaskIntoConstraints = false
        choices.widthAnchor.constraint(equalToConstant: 620).isActive = true
        choices.heightAnchor.constraint(equalToConstant: 105).isActive = true
        stack.addArrangedSubview(choices)

        let detailsHost = NSView()
        detailsHost.translatesAutoresizingMaskIntoConstraints = false
        detailsHost.widthAnchor.constraint(equalToConstant: 620).isActive = true
        detailsHost.heightAnchor.constraint(equalToConstant: 112).isActive = true
        let details = animationDetailsView()
        details.translatesAutoresizingMaskIntoConstraints = false
        detailsHost.addSubview(details)
        NSLayoutConstraint.activate([
            details.centerXAnchor.constraint(equalTo: detailsHost.centerXAnchor),
            details.centerYAnchor.constraint(equalTo: detailsHost.centerYAnchor),
            details.leadingAnchor.constraint(greaterThanOrEqualTo: detailsHost.leadingAnchor),
            details.trailingAnchor.constraint(lessThanOrEqualTo: detailsHost.trailingAnchor),
        ])
        stack.addArrangedSubview(detailsHost)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        return root
    }

    private func animationDetailsView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7

        guard let animationsEnabled = progress.animationsEnabled else {
            stack.addArrangedSubview(secondaryNote("Choose an animation style to continue."))
            return stack
        }
        guard animationsEnabled else {
            stack.addArrangedSubview(secondaryNote("Instant mode follows the same focus sequence above, but switches between each state immediately and needs no additional permission."))
            return stack
        }

        stack.addArrangedSubview(secondaryNote("Screen Recording is used only to capture images of your open windows for animation frames—nothing is recorded, stored, or transmitted."))
        switch permissions.screenRecording {
        case .missing:
            stack.addArrangedSubview(prominentButton("Grant Screen Recording Access…", action: #selector(requestScreenRecording)))
        case .restartRequired:
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 9
            row.addArrangedSubview(OnboardingStatusView(text: "Access granted — restart required", isReady: true))
            row.addArrangedSubview(prominentButton("Restart Miri and Continue", action: #selector(restartForScreenRecording)))
            stack.addArrangedSubview(row)
        case .granted:
            stack.addArrangedSubview(OnboardingStatusView(text: "Screen Recording access granted", isReady: true))
        }
        return stack
    }

    private func readyPage() -> NSView {
        let root = centeredPageStack(spacing: 18)
        root.addArrangedSubview(heroSymbol("checkmark.circle.fill", color: MiriOnboardingPalette.green))
        root.addArrangedSubview(pageHeading("Setup complete"))

        let alignmentName = FocusAlignment.guiOptions.first(where: { $0.alignment == progress.focusAlignment })?.title ?? "Default"
        let animationName = progress.animationsEnabled == true ? "Smooth snapshots" : "Instant"
        let summary = insetPanel()
        let labels = NSStackView()
        labels.orientation = .vertical
        labels.spacing = 10
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.addArrangedSubview(summaryRow(symbol: "rectangle.3.group", title: "Layout", value: alignmentName))
        labels.addArrangedSubview(summaryRow(symbol: "arrow.down.right.and.arrow.up.left", title: "Outer margin", value: "\(Int(progress.outerGap.rounded())) pt"))
        labels.addArrangedSubview(summaryRow(symbol: "sparkles", title: "Transitions", value: animationName))
        summary.addSubview(labels)
        NSLayoutConstraint.activate([
            labels.topAnchor.constraint(equalTo: summary.topAnchor, constant: 16),
            labels.leadingAnchor.constraint(equalTo: summary.leadingAnchor, constant: 18),
            labels.trailingAnchor.constraint(equalTo: summary.trailingAnchor, constant: -18),
            labels.bottomAnchor.constraint(equalTo: summary.bottomAnchor, constant: -16),
            summary.widthAnchor.constraint(equalToConstant: 480),
        ])
        root.addArrangedSubview(summary)
        root.addArrangedSubview(secondaryNote("Click Start using Miri when you’re ready. Window discovery and tiling begin only then."))
        return root
    }

    @objc private func requestAccessibility() {
        actionSink(.requestAccessibilityPermission)
    }

    @objc private func requestScreenRecording() {
        progressSink(progress)
        actionSink(.requestScreenRecordingPermission)
    }

    @objc private func restartForScreenRecording() {
        progressSink(progress)
        actionSink(.restart)
    }

    @objc private func selectLayout(_ sender: NSButton) {
        guard FocusAlignment.guiOptions.indices.contains(sender.tag) else { return }
        progress.focusAlignment = FocusAlignment.guiOptions[sender.tag].alignment
        progressSink(progress)
        showCurrentPage(animated: false)
    }

    @objc private func marginChanged(_ sender: NSSlider) {
        progress.outerGap = sender.doubleValue.rounded()
        marginValueLabel?.stringValue = "\(Int(progress.outerGap)) pt"
        progressSink(progress)
    }

    @objc private func selectInstantAnimations() {
        progress.animationsEnabled = false
        progressSink(progress)
        showCurrentPage(animated: false)
    }

    @objc private func selectSmoothAnimations() {
        progress.animationsEnabled = true
        progressSink(progress)
        showCurrentPage(animated: false)
    }

    @objc private func goBack() {
        switch progress.step {
        case .layout: progress.step = .accessibility
        case .animation: progress.step = .layout
        case .ready: progress.step = .animation
        case .accessibility, .completed: return
        }
        progressSink(progress)
        showCurrentPage(animated: true)
    }

    @objc private func goNext() {
        switch progress.step {
        case .accessibility:
            guard permissions.accessibility != .missing else { return }
            progress.step = .layout
        case .layout:
            progress.step = .animation
        case .animation:
            guard progress.animationsEnabled != nil else { return }
            if progress.animationsEnabled == true {
                guard permissions.screenRecording == .granted else { return }
            }
            progress.step = .ready
        case .ready:
            actionSink(.completeOnboarding(progress))
            return
        case .completed:
            return
        }
        progressSink(progress)
        showCurrentPage(animated: true)
    }

    private func centeredPageStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .gravityAreas
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        return stack
    }

    private func heroSymbol(_ name: String, color: NSColor) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let view = NSImageView(image: image ?? NSImage())
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .medium)
        view.contentTintColor = color
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 58).isActive = true
        return view
    }

    private func pageHeading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.alignment = .center
        return label
    }

    private func pageBody(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 4
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 590).isActive = true
        return label
    }

    private func secondaryNote(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 590).isActive = true
        return label
    }

    private func prominentButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.focusRingType = .none
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.cornerCurve = .continuous
        button.layer?.backgroundColor = MiriOnboardingPalette.orange.cgColor
        button.controlSize = .large
        button.contentTintColor = .white
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        return button
    }

    private func insetPanel() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.cornerCurve = .continuous
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.58).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        return view
    }

    private func summaryRow(symbol: String, title: String, value: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = MiriOnboardingPalette.orange
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        row.addArrangedSubview(icon)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        row.addArrangedSubview(titleLabel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.textColor = .secondaryLabelColor
        row.addArrangedSubview(valueLabel)
        return row
    }

    private func stepIndex(_ step: OnboardingStep) -> Int {
        switch step {
        case .accessibility: 0
        case .layout: 1
        case .animation: 2
        case .ready, .completed: 3
        }
    }
}

@MainActor
private final class OnboardingBackdropView: NSView {
    private let gradient = CAGradientLayer()
    private let glow = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradient.colors = [
            MiriOnboardingPalette.graphite.cgColor,
            MiriOnboardingPalette.charcoal.cgColor,
            NSColor.windowBackgroundColor.cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(gradient)

        glow.type = .radial
        glow.colors = [MiriOnboardingPalette.orange.withAlphaComponent(0.12).cgColor, NSColor.clear.cgColor]
        glow.locations = [0, 1]
        layer?.addSublayer(glow)

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.45
        pulse.toValue = 0.9
        pulse.duration = 3.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(pulse, forKey: "ambient-pulse")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        gradient.frame = bounds
        glow.frame = CGRect(x: bounds.width * 0.38, y: bounds.height * 0.35, width: bounds.width * 0.7, height: bounds.height * 0.8)
    }
}

@MainActor
private final class OnboardingStatusView: NSView {
    init(text: String, isReady: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        let color = isReady ? MiriOnboardingPalette.green : MiriOnboardingPalette.yellow
        layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        layer?.borderColor = color.withAlphaComponent(0.32).cgColor
        layer?.borderWidth = 1

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: isReady ? "checkmark.circle.fill" : "clock.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = color
        stack.addArrangedSubview(icon)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(label)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private class OnboardingChoiceButton: NSButton {
    init(
        title: String,
        detail: String,
        symbolName: String,
        selected: Bool,
        target: AnyObject?,
        action: Selector
    ) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.title = ""
        setAccessibilityLabel(title)
        imagePosition = .noImage
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = (selected ? MiriOnboardingPalette.orange.withAlphaComponent(0.13) : NSColor.controlBackgroundColor.withAlphaComponent(0.55)).cgColor
        layer?.borderWidth = selected ? 2 : 1
        layer?.borderColor = (selected ? MiriOnboardingPalette.orange : NSColor.separatorColor.withAlphaComponent(0.4)).cgColor

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        content.isHidden = false
        let icon = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 21, weight: .medium)
        icon.contentTintColor = selected ? MiriOnboardingPalette.orange : .secondaryLabelColor
        content.addArrangedSubview(icon)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        content.addArrangedSubview(heading)
        let body = NSTextField(wrappingLabelWithString: detail)
        body.font = .systemFont(ofSize: 11)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.maximumNumberOfLines = 3
        content.addArrangedSubview(body)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 105),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        return bounds.contains(localPoint) ? self : nil
    }
}

@MainActor
private final class LayoutChoiceButton: NSButton {
    let layoutAlignment: FocusAlignment

    init(
        alignment: FocusAlignment,
        title: String,
        detail: String,
        selected: Bool,
        target: AnyObject?,
        action: Selector
    ) {
        self.layoutAlignment = alignment
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.title = ""
        setAccessibilityLabel(title)
        imagePosition = .noImage
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = (selected ? MiriOnboardingPalette.orange.withAlphaComponent(0.13) : NSColor.controlBackgroundColor.withAlphaComponent(0.55)).cgColor
        layer?.borderWidth = selected ? 2 : 1
        layer?.borderColor = (selected ? MiriOnboardingPalette.orange : NSColor.separatorColor.withAlphaComponent(0.4)).cgColor

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        let preview = LayoutPreviewView(alignment: alignment)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 70).isActive = true
        preview.widthAnchor.constraint(equalToConstant: 150).isActive = true
        content.addArrangedSubview(preview)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        content.addArrangedSubview(heading)
        let body = NSTextField(wrappingLabelWithString: detail)
        body.font = .systemFont(ofSize: 10.5)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.maximumNumberOfLines = 3
        content.addArrangedSubview(body)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            heightAnchor.constraint(equalToConstant: 176),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        return bounds.contains(localPoint) ? self : nil
    }
}

@MainActor
private final class LayoutPreviewView: NSView {
    private let alignment: FocusAlignment

    init(alignment: FocusAlignment) {
        self.alignment = alignment
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let viewport = bounds.insetBy(dx: 4, dy: 5)
        NSColor.separatorColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: viewport, xRadius: 7, yRadius: 7).fill()

        let width: CGFloat = alignment == .centeredSmart ? 64 : 50
        let activeX: CGFloat = switch alignment {
        case .default: viewport.minX + 13
        case .centered: viewport.midX - width / 2
        case .centeredSmart: viewport.midX - width / 2
        }
        let colors: [NSColor] = [MiriOnboardingPalette.silver, MiriOnboardingPalette.paper, MiriOnboardingPalette.silver]
        for index in -1...1 {
            let rect = CGRect(
                x: activeX + CGFloat(index) * (width + 5),
                y: viewport.minY + 8,
                width: width,
                height: viewport.height - 16
            )
            colors[index + 1].withAlphaComponent(index == 0 ? 0.82 : 0.30).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        }
    }
}

@MainActor
private final class AnimationPreviewView: NSView {
    private enum PreviewState {
        case initial
        case centerFocused
        case rightFocused
    }

    /// nil shows the neutral starting arrangement, false demonstrates instant
    /// state changes, and true demonstrates the same sequence with tweening.
    private let mode: Bool?
    private let tiles: [CALayer]
    private var configuredSize = CGSize.zero

    init(mode: Bool?) {
        self.mode = mode
        let colors = [
            MiriOnboardingPalette.orange,
            MiriOnboardingPalette.yellow,
            MiriOnboardingPalette.green,
        ]
        tiles = colors.map { color in
            let tile = CALayer()
            tile.cornerRadius = 8
            tile.cornerCurve = .continuous
            tile.backgroundColor = color.withAlphaComponent(0.88).cgColor
            return tile
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.52).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        tiles.forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard bounds.size != configuredSize, bounds.width > 100, bounds.height > 40 else { return }
        configuredSize = bounds.size
        configureSequence()
    }

    private func configureSequence() {
        for tile in tiles {
            tile.removeAllAnimations()
        }

        let initialFrames = frames(for: .initial)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (tile, frame) in zip(tiles, initialFrames) {
            tile.frame = frame
        }
        CATransaction.commit()

        guard let mode else { return }
        let states: [PreviewState]
        let keyTimes: [NSNumber]
        let calculationMode: CAAnimationCalculationMode
        let duration: CFTimeInterval

        if mode {
            // Each duplicate state creates a readable hold between the smooth
            // transitions: initial → centered → right → centered → initial.
            states = [
                .initial, .initial,
                .centerFocused, .centerFocused,
                .rightFocused, .rightFocused,
                .centerFocused, .centerFocused,
                .initial, .initial,
            ]
            keyTimes = [0, 0.10, 0.25, 0.36, 0.52, 0.63, 0.76, 0.86, 0.97, 1]
            calculationMode = .linear
            duration = 7.0
        } else {
            states = [.initial, .centerFocused, .rightFocused, .centerFocused, .initial]
            keyTimes = [0, 0.20, 0.45, 0.70, 0.90]
            calculationMode = .discrete
            duration = 6.0
        }

        let stateFrames = states.map(frames(for:))
        let beginTime = CACurrentMediaTime() + 0.15
        for index in tiles.indices {
            let position = CAKeyframeAnimation(keyPath: "position")
            position.values = stateFrames.map {
                NSValue(point: CGPoint(x: $0[index].midX, y: $0[index].midY))
            }
            position.keyTimes = keyTimes
            position.calculationMode = calculationMode
            position.duration = duration
            position.beginTime = beginTime
            position.repeatCount = .infinity

            let bounds = CAKeyframeAnimation(keyPath: "bounds")
            bounds.values = stateFrames.map {
                NSValue(rect: CGRect(origin: .zero, size: $0[index].size))
            }
            bounds.keyTimes = keyTimes
            bounds.calculationMode = calculationMode
            bounds.duration = duration
            bounds.beginTime = beginTime
            bounds.repeatCount = .infinity

            if mode {
                let easing = CAMediaTimingFunction(name: .easeInEaseOut)
                position.timingFunctions = Array(repeating: easing, count: states.count - 1)
                bounds.timingFunctions = Array(repeating: easing, count: states.count - 1)
            }
            tiles[index].add(position, forKey: "focus-position")
            tiles[index].add(bounds, forKey: "focus-size")
        }
    }

    private func frames(for state: PreviewState) -> [CGRect] {
        let padding: CGFloat = 24
        let gap: CGFloat = 10
        let sideReveal: CGFloat = 13
        let tileHeight = bounds.height - 28
        let y = (bounds.height - tileHeight) / 2
        let initialWidth = (bounds.width - padding * 2 - gap * 2) / 3
        let fullWidth = bounds.width - padding * 2

        let initial = (0..<3).map { index in
            CGRect(
                x: padding + CGFloat(index) * (initialWidth + gap),
                y: y,
                width: initialWidth,
                height: tileHeight
            )
        }
        switch state {
        case .initial:
            return initial
        case .centerFocused:
            return [
                CGRect(x: -initialWidth + sideReveal, y: y, width: initialWidth, height: tileHeight),
                CGRect(x: padding, y: y, width: fullWidth, height: tileHeight),
                CGRect(x: bounds.width - sideReveal, y: y, width: initialWidth, height: tileHeight),
            ]
        case .rightFocused:
            return [
                CGRect(x: -initialWidth, y: y, width: initialWidth, height: tileHeight),
                CGRect(x: -fullWidth + sideReveal, y: y, width: fullWidth, height: tileHeight),
                CGRect(x: padding, y: y, width: fullWidth, height: tileHeight),
            ]
        }
    }
}
