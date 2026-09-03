import AppKit
import QuartzCore

enum MiriVisualStyle {
    static let orange = NSColor(srgbRed: 1.00, green: 0.28, blue: 0.12, alpha: 1)
    static let yellow = NSColor(srgbRed: 1.00, green: 0.72, blue: 0.00, alpha: 1)
    static let green = NSColor(srgbRed: 0.00, green: 0.82, blue: 0.22, alpha: 1)
    static let graphite = NSColor(srgbRed: 0.075, green: 0.08, blue: 0.09, alpha: 1)
    static let charcoal = NSColor(srgbRed: 0.14, green: 0.15, blue: 0.16, alpha: 1)
    static let silver = NSColor(srgbRed: 0.82, green: 0.83, blue: 0.85, alpha: 1)
    static let paper = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)

    @MainActor static func insetPanel() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.cornerCurve = .continuous
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.58).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        return view
    }

    @MainActor static func stylePrimaryButton(_ button: NSButton) {
        button.isBordered = false
        button.focusRingType = .none
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.cornerCurve = .continuous
        button.layer?.backgroundColor = orange.cgColor
        button.contentTintColor = .white
    }
}

@MainActor
final class MiriBackdropView: NSView {
    private let gradient = CAGradientLayer()
    private let glow = CAGradientLayer()

    init(animated: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        gradient.colors = [
            MiriVisualStyle.graphite.cgColor,
            MiriVisualStyle.charcoal.cgColor,
            NSColor.windowBackgroundColor.cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(gradient)

        glow.type = .radial
        glow.colors = [MiriVisualStyle.orange.withAlphaComponent(0.09).cgColor, NSColor.clear.cgColor]
        glow.locations = [0, 1]
        glow.opacity = animated ? 0.7 : 0.52
        layer?.addSublayer(glow)

        if animated {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.45
            pulse.toValue = 0.9
            pulse.duration = 3.2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(pulse, forKey: "ambient-pulse")
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        gradient.frame = bounds
        glow.frame = CGRect(
            x: bounds.width * 0.34,
            y: bounds.height * 0.36,
            width: bounds.width * 0.74,
            height: bounds.height * 0.82
        )
    }
}

@MainActor
final class MiriSettingsChoiceButton: NSButton {
    private let topView: NSView
    private let icon: NSImageView?
    private var selectedChoice: Bool

    init(
        title: String,
        detail: String,
        symbolName: String? = nil,
        topView: NSView? = nil,
        selected: Bool,
        target: AnyObject?,
        action: Selector
    ) {
        let suppliedTopView: NSView
        let suppliedIcon: NSImageView?
        if let topView {
            suppliedTopView = topView
            suppliedIcon = nil
        } else {
            let image = NSImage(systemSymbolName: symbolName ?? "circle", accessibilityDescription: nil) ?? NSImage()
            let imageView = NSImageView(image: image)
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            suppliedTopView = imageView
            suppliedIcon = imageView
        }
        self.topView = suppliedTopView
        self.icon = suppliedIcon
        self.selectedChoice = selected
        super.init(frame: .zero)

        self.target = target
        self.action = action
        self.title = ""
        setAccessibilityLabel(title)
        setAccessibilityValue(selected ? "Selected" : "Not selected")
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        suppliedTopView.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(suppliedTopView)

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
            content.topAnchor.constraint(equalTo: self.topAnchor, constant: 13),
            content.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -13),
            self.heightAnchor.constraint(greaterThanOrEqualToConstant: 112),
        ])
        applySelectionStyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool) {
        selectedChoice = selected
        setAccessibilityValue(selected ? "Selected" : "Not selected")
        applySelectionStyle()
    }

    private func applySelectionStyle() {
        layer?.backgroundColor = (selectedChoice
            ? MiriVisualStyle.orange.withAlphaComponent(0.13)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.55)).cgColor
        layer?.borderWidth = selectedChoice ? 2 : 1
        layer?.borderColor = (selectedChoice
            ? MiriVisualStyle.orange
            : NSColor.separatorColor.withAlphaComponent(0.4)).cgColor
        icon?.contentTintColor = selectedChoice ? MiriVisualStyle.orange : .secondaryLabelColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
}
