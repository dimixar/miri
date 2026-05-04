import AppKit

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var miri: Miri?
    private let menu = NSMenu()
    private let workspaceItem = NSMenuItem(title: "Workspace: —", action: nil, keyEquivalent: "")
    private let focusedItem = NSMenuItem(title: "Focused: —", action: nil, keyEquivalent: "")
    private let widthItem = NSMenuItem(title: "Width: —", action: nil, keyEquivalent: "")
    private var refreshTimer: Timer?

    init(miri: Miri) {
        self.miri = miri
        super.init()
        configureMenu()
        refreshWorkspaceBar()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWorkspaceBar() }
        }
    }

    private func configureMenu() {
        statusItem.button?.title = "Miri"
        statusItem.button?.imagePosition = .imageOnly
        menu.delegate = self

        workspaceItem.isEnabled = false
        focusedItem.isEnabled = false
        widthItem.isEnabled = false

        menu.addItem(workspaceItem)
        menu.addItem(focusedItem)
        menu.addItem(widthItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Rescan Windows", action: #selector(rescanWindows), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Miri", action: #selector(quitMiri), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let status = miri?.currentStatus() else {
            return
        }

        workspaceItem.title = "Workspace: \(status.workspace) of \(status.workspaceCount)"
        focusedItem.title = "Focused: \(status.focusedWindow)"
        widthItem.title = status.widthPercent.map { "Width: \($0)%" } ?? "Width: —"
        refreshWorkspaceBar()
    }

    private func refreshWorkspaceBar() {
        guard let barStatus = miri?.currentWorkspaceBarStatus() else {
            statusItem.button?.title = "Miri"
            statusItem.button?.image = nil
            return
        }
        statusItem.button?.title = ""
        statusItem.button?.image = drawWorkspaceBar(barStatus)
    }

    private func drawWorkspaceBar(_ status: MiriWorkspaceBarStatus) -> NSImage {
        let config = miri?.currentConfigForStatusBar() ?? .fallback
        let maxIcons = config.workspaceBarVisibleIconCount ?? MiriConfig.fallback.workspaceBarVisibleIconCount ?? 3
        let iconSize: CGFloat = 16
        let iconBox: CGFloat = 20
        let height: CGFloat = 22
        let paddingX: CGFloat = 5
        let textGap: CGFloat = 5
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]

        let count = status.windows.count
        let focused = status.focusedIndex.flatMap { count.indicesContains($0) ? $0 : nil }
        let range: Range<Int>
        if let focused, count > 0 {
            let visibleCount = min(maxIcons, count)
            var start = focused - visibleCount / 2
            start = max(0, min(start, count - visibleCount))
            range = start..<(start + visibleCount)
        } else {
            range = 0..<min(maxIcons, count)
        }

        let leftOverflow = range.lowerBound
        let rightOverflow = max(0, count - range.upperBound)
        let workspaceText = "{\(status.workspace)}"
        let overflowStyle = config.workspaceBarOverflowStyle ?? MiriConfig.fallback.workspaceBarOverflowStyle ?? .plusCount
        let leftText = overflowText(count: leftOverflow, side: .left, style: overflowStyle)
        let rightText = overflowText(count: rightOverflow, side: .right, style: overflowStyle)

        func textWidth(_ text: String?) -> CGFloat {
            guard let text else { return 0 }
            return ceil((text as NSString).size(withAttributes: textAttrs).width)
        }

        let iconCount = CGFloat(range.count)
        let width = paddingX * 2
            + textWidth(workspaceText)
            + (leftText == nil ? 0 : textGap + textWidth(leftText))
            + (range.isEmpty ? 0 : textGap + iconCount * iconBox)
            + (rightText == nil ? 0 : textGap + textWidth(rightText))

        let image = NSImage(size: NSSize(width: width, height: height))
        image.isTemplate = false
        image.lockFocus()
        defer { image.unlockFocus() }

        var x = paddingX
        let yText: CGFloat = 3
        (workspaceText as NSString).draw(at: CGPoint(x: x, y: yText), withAttributes: textAttrs)
        x += textWidth(workspaceText)

        if let leftText {
            x += textGap
            (leftText as NSString).draw(at: CGPoint(x: x, y: yText), withAttributes: textAttrs)
            x += textWidth(leftText)
        }

        if !range.isEmpty {
            x += textGap
        }

        for index in range {
            let window = status.windows[index]
            let isFocused = index == focused
            let box = NSRect(x: x, y: 1, width: iconBox, height: iconBox)
            if isFocused {
                highlightColor(config.workspaceBarHighlightColor).withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
            }

            let icon = icon(for: window)
            icon.draw(in: NSRect(x: x + 2, y: 3, width: iconSize, height: iconSize), from: .zero, operation: .sourceOver, fraction: 1)
            x += iconBox
        }

        if let rightText {
            x += textGap
            (rightText as NSString).draw(at: CGPoint(x: x, y: yText), withAttributes: textAttrs)
        }

        return image
    }

    private enum OverflowSide {
        case left
        case right
    }

    private func overflowText(count: Int, side: OverflowSide, style: WorkspaceBarOverflowStyle) -> String? {
        guard count > 0 else { return nil }
        switch style {
        case .plusCount:
            return "+\(count)"
        case .dotsCount:
            return "…\(count)"
        case .chevron:
            return side == .left ? "‹" : "›"
        case .none:
            return nil
        }
    }

    private func highlightColor(_ name: String?) -> NSColor {
        switch name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "green": return .systemGreen
        case "mint": return .systemMint
        case "teal": return .systemTeal
        case "cyan": return .systemCyan
        case "blue": return .systemBlue
        case "indigo": return .systemIndigo
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "gray", "grey": return .systemGray
        case let hex? where hex.hasPrefix("#"):
            return colorFromHex(hex) ?? .systemYellow
        default:
            return .systemYellow
        }
    }

    private func colorFromHex(_ hex: String) -> NSColor? {
        let trimmed = String(hex.dropFirst())
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xff) / 255
        let g = CGFloat((value >> 8) & 0xff) / 255
        let b = CGFloat(value & 0xff) / 255
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }

    private func icon(for window: MiriWorkspaceBarWindow) -> NSImage {
        if let bundleID = window.bundleID,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let icon = app.icon
        {
            return icon
        }

        if let bundleID = window.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        {
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        return NSWorkspace.shared.icon(for: .application)
    }

    @objc private func openSettings() {
        miri?.showSettingsFromMenu()
    }

    @objc private func openConfig() {
        miri?.openConfigFromMenu()
    }

    @objc private func reloadConfig() {
        miri?.reloadFromMenu()
    }

    @objc private func rescanWindows() {
        miri?.rescanFromMenu()
    }

    @objc private func quitMiri() {
        miri?.quitFromMenu()
    }
}

private extension Int {
    func indicesContains(_ index: Int) -> Bool {
        index >= 0 && index < self
    }
}
