import AppKit
import SwiftUI

/// 提示词输入框：回车发送，Shift+回车换行；输入法组词（拼音未上屏）时回车交给输入法
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let stv = SubmitTextView(frame: .zero)
        stv.isVerticallyResizable = true
        stv.isHorizontallyResizable = false
        stv.autoresizingMask = [.width]
        stv.minSize = .zero
        stv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        stv.textContainer?.widthTracksTextView = true
        stv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = stv
        stv.onSubmit = { context.coordinator.parent.onSubmit() }
        stv.delegate = context.coordinator
        stv.font = .systemFont(ofSize: 14)
        stv.drawsBackground = false
        stv.isRichText = false
        stv.allowsUndo = true
        stv.isAutomaticQuoteSubstitutionEnabled = false
        stv.isAutomaticDashSubstitutionEnabled = false
        stv.textContainerInset = NSSize(width: 0, height: 2)
        stv.string = text
        DispatchQueue.main.async { stv.window?.makeFirstResponder(stv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text && !tv.hasMarkedText() {
            tv.string = text
            if text.isEmpty { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        init(_ p: PromptEditor) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isReturn && !hasMarkedText() {
            if mods.contains(.shift) || mods.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            if mods.isEmpty {
                onSubmit?()
                return
            }
        }
        super.keyDown(with: event)
    }
}
