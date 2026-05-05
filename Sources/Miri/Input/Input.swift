import CoreGraphics

enum KeyCode {
    static let one: Int64 = 18
    static let two: Int64 = 19
    static let three: Int64 = 20
    static let four: Int64 = 21
    static let five: Int64 = 23
    static let six: Int64 = 22
    static let seven: Int64 = 26
    static let eight: Int64 = 28
    static let nine: Int64 = 25
    static let zero: Int64 = 29
    static let h: Int64 = 4
    static let j: Int64 = 38
    static let k: Int64 = 40
    static let l: Int64 = 37
    static let equal: Int64 = 24
    static let minus: Int64 = 27
    static let home: Int64 = 115
    static let end: Int64 = 119
    static let leftBracket: Int64 = 33
    static let rightBracket: Int64 = 30
}

enum Command {
    case focusWorkspace(Int)
    case focusPreviousWorkspace
    case workspaceDown
    case workspaceUp
    case columnLeft
    case columnRight
    case columnFirst
    case columnLast
    case moveColumnLeft
    case moveColumnRight
    case moveColumnToFirst
    case moveColumnToLast
    case moveColumnToWorkspace(Int)
    case moveColumnToWorkspaceDown
    case moveColumnToWorkspaceUp
    case cycleWidthPresetBackward
    case cycleWidthPresetForward
    case nudgeWidthNarrower
    case nudgeWidthWider
    case cycleAllWidthPresetsBackward
    case cycleAllWidthPresetsForward
    case nudgeAllWidthsNarrower
    case nudgeAllWidthsWider
}

enum TrackpadNavigationEvent {
    case began
    case changed(delta: CGPoint, velocity: CGPoint)
    case ended(velocity: CGPoint)
}
