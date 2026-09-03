import Foundation

extension FocusAlignment {
    static let guiOptions: [(alignment: FocusAlignment, title: String)] = [
        (.default, "Default"),
        (.centered, "Centered"),
        (.centeredSmart, "Centered Smart"),
    ]
}

enum SettingsRoute: String, CaseIterable, Identifiable {
    case general
    case layout
    case animations
    case workspaceBar
    case shortcuts
    case rules
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .layout: return "Layout"
        case .animations: return "Animations"
        case .workspaceBar: return "Workspace Bar"
        case .shortcuts: return "Shortcuts"
        case .rules: return "Window Rules"
        case .advanced: return "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Permissions and everyday behavior."
        case .layout: return "Choose how windows, columns, and workspaces are arranged."
        case .animations: return "Control movement style and snapshot performance."
        case .workspaceBar: return "Tune the menu bar workspace indicator."
        case .shortcuts: return "Configure global keyboard control."
        case .rules: return "Choose how specific apps and windows are managed."
        case .advanced: return "Recovery, reconciliation, and diagnostic settings."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .layout: return "rectangle.3.group.fill"
        case .animations: return "sparkles"
        case .workspaceBar: return "menubar.rectangle"
        case .shortcuts: return "keyboard.fill"
        case .rules: return "list.bullet.rectangle"
        case .advanced: return "wrench.and.screwdriver.fill"
        }
    }
}
