import SwiftUI

struct LayoutPreviewRepresentable: NSViewRepresentable {
    let alignment: FocusAlignment

    func makeNSView(context: Context) -> LayoutPreviewView {
        LayoutPreviewView(alignment: alignment)
    }

    func updateNSView(_ nsView: LayoutPreviewView, context: Context) {}
}

struct AnimationPreviewRepresentable: NSViewRepresentable {
    let mode: Bool?

    init(animated: Bool) {
        mode = animated
    }

    init(mode: Bool?) {
        self.mode = mode
    }

    func makeNSView(context: Context) -> AnimationPreviewView {
        AnimationPreviewView(mode: mode)
    }

    func updateNSView(_ nsView: AnimationPreviewView, context: Context) {}
}
