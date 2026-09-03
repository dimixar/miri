import AppKit
import SwiftUI

/// Semantic visual tokens shared by onboarding and Settings.
enum MiriTheme {
    enum Palette {
        static let orange = NSColor(srgbRed: 1.00, green: 0.28, blue: 0.12, alpha: 1)
        static let yellow = NSColor(srgbRed: 1.00, green: 0.72, blue: 0.00, alpha: 1)
        static let green = NSColor(srgbRed: 0.00, green: 0.82, blue: 0.22, alpha: 1)
        static let graphite = NSColor(srgbRed: 0.075, green: 0.08, blue: 0.09, alpha: 1)
        static let charcoal = NSColor(srgbRed: 0.14, green: 0.15, blue: 0.16, alpha: 1)
        static let silver = NSColor(srgbRed: 0.82, green: 0.83, blue: 0.85, alpha: 1)
        static let paper = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)

        static var accent: SwiftUI.Color { SwiftUI.Color(nsColor: orange) }
        static var warning: SwiftUI.Color { SwiftUI.Color(nsColor: yellow) }
        static var success: SwiftUI.Color { SwiftUI.Color(nsColor: green) }
        static var separator: SwiftUI.Color { SwiftUI.Color(nsColor: .separatorColor).opacity(0.35) }
        static var panel: SwiftUI.Color { SwiftUI.Color(nsColor: .controlBackgroundColor).opacity(0.58) }
    }

    enum Spacing {
        static let inline: CGFloat = 6
        static let compact: CGFloat = 8
        static let control: CGFloat = 12
        static let header: CGFloat = 14
        static let rowVertical: CGFloat = 16
        static let rowHorizontal: CGFloat = 20
        static let section: CGFloat = 24
        static let page: CGFloat = 28
        static let windowHorizontal: CGFloat = 24
        static let windowTop: CGFloat = 36
        static let windowBottom: CGFloat = 24
    }

    enum Radius {
        static let button: CGFloat = 7
        static let panel: CGFloat = 12
        static let choice: CGFloat = 13
        static let window: CGFloat = 24
    }

    enum Size {
        static let sidebarWidth: CGFloat = 205
        static let controlWidth: CGFloat = 220
        static let sliderWidth: CGFloat = 180
        static let valueLabelWidth: CGFloat = 52
        static let primaryButtonWidth: CGFloat = 92
        static let onboardingContentWidth: CGFloat = 620
        static let onboardingSummaryWidth: CGFloat = 480
        static let onboardingMinimumWidth: CGFloat = 760
        static let onboardingMinimumHeight: CGFloat = 570
        static let settingsMinimumWidth: CGFloat = 840
        static let settingsMinimumHeight: CGFloat = 600
    }

    enum Typography {
        static let onboardingTitle = Font.system(size: 30, weight: .bold)
        static let onboardingSubtitle = Font.system(size: 15)
        static let onboardingHeading = Font.system(size: 20, weight: .semibold)
        static let onboardingBody = Font.system(size: 14)
        static let onboardingNote = Font.system(size: 12)
        static let brandTitle = Font.system(size: 20, weight: .bold)
        static let brandSubtitle = Font.system(size: 11, weight: .medium)
        static let pageTitle = Font.system(size: 25, weight: .bold)
        static let pageSubtitle = Font.system(size: 13)
        static let sectionTitle = Font.system(size: 15, weight: .semibold)
        static let sectionDetail = Font.system(size: 12)
        static let rowTitle = Font.system(size: 13, weight: .medium)
        static let rowDetail = Font.system(size: 11)
        static let status = Font.system(size: 12, weight: .medium)
    }

    enum Motion {
        static let windowPresentation = 0.22
        static let standard = 0.20
        static let ambientPulse = 3.2
    }
}
