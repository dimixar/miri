import AppKit
import QuartzCore

@MainActor
final class LayoutPreviewView: NSView {
    private let alignment: FocusAlignment

    init(alignment: FocusAlignment) {
        self.alignment = alignment
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let viewport = bounds.insetBy(dx: 4, dy: 5)
        let viewportPath = NSBezierPath(roundedRect: viewport, xRadius: 7, yRadius: 7)
        NSColor.separatorColor.withAlphaComponent(0.22).setFill()
        viewportPath.fill()

        NSGraphicsContext.saveGraphicsState()
        viewportPath.addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let width: CGFloat = alignment == .centeredSmart ? 64 : 50
        let activeX: CGFloat = switch alignment {
        case .default: viewport.minX + 13
        case .centered, .centeredSmart: viewport.midX - width / 2
        }
        let colors: [NSColor] = [
            MiriTheme.Palette.silver,
            MiriTheme.Palette.paper,
            MiriTheme.Palette.silver,
        ]
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
final class AnimationPreviewView: NSView {
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
            MiriTheme.Palette.orange,
            MiriTheme.Palette.yellow,
            MiriTheme.Palette.green,
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
        layer?.cornerRadius = MiriTheme.Radius.choice
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
