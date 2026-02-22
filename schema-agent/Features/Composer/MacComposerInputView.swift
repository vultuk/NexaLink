import SwiftUI
#if os(macOS)
import AppKit

struct MacComposerInputView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = MacComposerTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.string = text
        textView.textContainerInset = NSSize(width: 0, height: 0)
        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textContainer.lineFragmentPadding = 0
        }

        scrollView.documentView = textView
        DispatchQueue.main.async {
            context.coordinator.recalculateHeight(for: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? MacComposerTextView else { return }
        textView.onSubmit = onSubmit
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.recalculateHeight(for: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacComposerInputView

        init(parent: MacComposerInputView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let updated = textView.string
            if parent.text != updated {
                parent.text = updated
            }
            recalculateHeight(for: textView)
        }

        func recalculateHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return
            }

            let containerWidth = max(textView.bounds.width, 1)
            if textContainer.containerSize.width != containerWidth {
                textContainer.containerSize.width = containerWidth
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2)
            let clamped = min(max(usedHeight, parent.minHeight), parent.maxHeight)
            if abs(parent.measuredHeight - clamped) > 0.5 {
                DispatchQueue.main.async {
                    if abs(self.parent.measuredHeight - clamped) > 0.5 {
                        self.parent.measuredHeight = clamped
                    }
                }
            }
            textView.enclosingScrollView?.hasVerticalScroller = usedHeight > parent.maxHeight + 0.5
        }
    }
}

private final class MacComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn else {
            super.keyDown(with: event)
            return
        }
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) {
            super.keyDown(with: event)
            return
        }
        let unsupportedFlags: NSEvent.ModifierFlags = [.command, .option, .control, .function]
        if flags.intersection(unsupportedFlags).isEmpty {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}
#endif
