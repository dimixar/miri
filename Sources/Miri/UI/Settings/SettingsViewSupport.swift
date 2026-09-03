import AppKit
import SwiftUI

struct MiriTextFieldRow: View {
    let title: String
    let detail: String?
    @Binding var text: String
    var width: CGFloat = MiriTheme.Size.controlWidth

    init(
        title: String,
        detail: String? = nil,
        text: Binding<String>,
        width: CGFloat = MiriTheme.Size.controlWidth
    ) {
        self.title = title
        self.detail = detail
        _text = text
        self.width = width
    }

    var body: some View {
        MiriSettingRow(title: title, detail: detail) {
            MiriBufferedTextField(value: text) { text = $0 }
                .frame(width: width)
                .accessibilityLabel(title)
        }
    }
}

/// Keeps in-progress text intact while a typed draft binding accepts only valid
/// values. External changes such as Revert are reflected whenever editing ends.
struct MiriBufferedTextField: View {
    let value: String
    let onChange: (String) -> Void
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(value: String, onChange: @escaping (String) -> Void) {
        self.value = value
        self.onChange = onChange
        _text = State(initialValue: value)
    }

    var body: some View {
        TextField("", text: $text)
            .labelsHidden()
            .focused($isFocused)
            .onChange(of: text, perform: onChange)
            .onChange(of: value) { newValue in
                if !isFocused, text != newValue {
                    text = newValue
                }
            }
            .onChange(of: isFocused) { focused in
                if !focused, text != value {
                    text = value
                }
            }
    }
}

struct MiriPickerRow<Option: Hashable>: View {
    let title: String
    let detail: String?
    let options: [(String, Option)]
    @Binding var selection: Option
    var width: CGFloat = MiriTheme.Size.controlWidth

    init(
        title: String,
        detail: String? = nil,
        options: [(String, Option)],
        selection: Binding<Option>,
        width: CGFloat = MiriTheme.Size.controlWidth
    ) {
        self.title = title
        self.detail = detail
        self.options = options
        _selection = selection
        self.width = width
    }

    var body: some View {
        MiriSettingRow(title: title, detail: detail) {
            Picker("", selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.0).tag(option.1)
                }
            }
            .labelsHidden()
            .frame(width: width)
            .accessibilityLabel(title)
        }
    }
}

struct MiriIntegerSliderRow: View {
    let title: String
    let detail: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var suffix = ""

    init(
        title: String,
        detail: String? = nil,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        suffix: String = ""
    ) {
        self.title = title
        self.detail = detail
        _value = value
        self.range = range
        self.suffix = suffix
    }

    var body: some View {
        MiriSettingRow(title: title, detail: detail) {
            MiriLabeledSlider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0.rounded()) }
                ),
                range: Double(range.lowerBound)...Double(range.upperBound),
                step: 1,
                valueText: { "\(Int($0.rounded()))\(suffix)" }
            )
        }
    }
}

struct MiriSecondsSliderRow: View {
    let title: String
    let detail: String?
    @Binding var milliseconds: Int
    let secondsRange: ClosedRange<Double>

    init(
        title: String,
        detail: String? = nil,
        milliseconds: Binding<Int>,
        secondsRange: ClosedRange<Double>
    ) {
        self.title = title
        self.detail = detail
        _milliseconds = milliseconds
        self.secondsRange = secondsRange
    }

    var body: some View {
        MiriSettingRow(title: title, detail: detail) {
            MiriLabeledSlider(
                value: Binding(
                    get: { Double(milliseconds) / 1_000 },
                    set: { milliseconds = Int(($0 * 1_000).rounded()) }
                ),
                range: secondsRange,
                step: 0.1,
                valueText: { String(format: "%.1fs", $0) }
            )
        }
    }
}

enum SettingsTextBinding {
    static func decimal(_ value: Binding<CGFloat>) -> Binding<String> {
        Binding(
            get: { String(format: "%g", Double(value.wrappedValue)) },
            set: { text in
                if let parsed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    value.wrappedValue = CGFloat(parsed)
                }
            }
        )
    }

    static func integer(_ value: Binding<Int>) -> Binding<String> {
        Binding(
            get: { String(value.wrappedValue) },
            set: { text in
                if let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    value.wrappedValue = parsed
                }
            }
        )
    }

    static func decimalList(_ value: Binding<[CGFloat]>) -> Binding<String> {
        Binding(
            get: {
                value.wrappedValue
                    .map { String(format: "%.2f", Double($0)) }
                    .joined(separator: ", ")
            },
            set: { text in
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    value.wrappedValue = []
                    return
                }
                let pieces = text.split(separator: ",", omittingEmptySubsequences: false)
                let parsed = pieces.compactMap {
                    Double($0.trimmingCharacters(in: .whitespacesAndNewlines)).map { CGFloat($0) }
                }
                if pieces.allSatisfy({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) != nil }) {
                    value.wrappedValue = parsed
                }
            }
        )
    }

    static func stringList(_ value: Binding<[String]>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue.joined(separator: ", ") },
            set: { text in
                value.wrappedValue = text
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}

enum MiriColorCodec {
    static func color(from setting: String) -> Color {
        Color(nsColor: nsColor(from: setting))
    }

    static func setting(from color: Color) -> String {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return "#FFD60A" }
        let red = Int((converted.redComponent * 255).rounded())
        let green = Int((converted.greenComponent * 255).rounded())
        let blue = Int((converted.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func nsColor(from setting: String) -> NSColor {
        switch setting.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
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
        case let hex where hex.hasPrefix("#"):
            let valueText = String(hex.dropFirst())
            guard valueText.count == 6, let value = Int(valueText, radix: 16) else {
                return .systemYellow
            }
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255,
                alpha: 1
            )
        default:
            return .systemYellow
        }
    }
}
