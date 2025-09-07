import SwiftUI
import AppKit

/// Cell, die Text/Placeholder *wirklich vertikal mittig* zeichnet und keinen Hintergrund malt.
final class CenteredPlainSearchFieldCell: NSSearchFieldCell {
    // Feinjustage
    private let verticalNudge: CGFloat = 0     // optisch tiefer/höher; 0 = neutral
    private let leftPadding: CGFloat   = 8     // Platzhalter/Anzeige leicht nach rechts
    private let editExtraLeft: CGFloat = 12    // NUR Editor/Cursor weiter rechts

    private func centered(_ rect: NSRect) -> NSRect {
        let fnt = self.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let line = fnt.ascender - fnt.descender + fnt.leading
        let lh   = max(1, CGFloat(line))

        var r = rect
        let dy = max(0, (r.height - lh) / 2.0).rounded(.down)
        r.origin.y    += dy + verticalNudge
        r.size.height -= 2 * dy
        r.origin.x    += leftPadding
        r.size.width  -= leftPadding
        return r
    }

    // --- Lupe/Buttons optional leicht justieren ---
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        var r = super.searchButtonRect(forBounds: rect)
        r.origin.x += 8   // Lupe minimal nach rechts
        r.origin.y += 1   // Lupe minimal tiefer
        return r
    }

    // --- Platzhalter/Anzeige-Text (statisch) ---
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var r = centered(super.searchTextRect(forBounds: rect))
        r.origin.y += 2
        return r
    }
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        return centered(super.titleRect(forBounds: rect))
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        return centered(super.drawingRect(forBounds: rect))
    }

    // --- Editor (Cursor/Eingabe): gleicher vertikaler Frame, aber extra links ---
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        var r = centered(super.searchTextRect(forBounds: rect))
        r.origin.y += 2
        super.edit(withFrame: r, in: controlView, editor: textObj, delegate: delegate, event: event)

        if let tv = textObj as? NSTextView {
            tv.textContainerInset = .zero
            tv.textContainer?.lineFragmentPadding = 0
        }
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        var r = centered(super.searchTextRect(forBounds: rect))
        r.origin.x    += editExtraLeft - 2
        r.origin.y    += 2
        r.size.width  -= editExtraLeft - 2
        super.select(withFrame: r, in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)

        if let tv = textObj as? NSTextView {
            tv.textContainerInset = .zero
            tv.textContainer?.lineFragmentPadding = 0
        }
    }

    // Kein Bezel/Hintergrund
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }
}

public struct FocusableSearchField: NSViewRepresentable {
    /// Auf diese Notification kannst du von außen posten, um das Feld zu fokussieren.
    public static let focusNotification = Notification.Name("FocusableSearchField.focusNow")

    public let placeholder: String
    @Binding public var text: String
    public var onSubmit: (() -> Void)?

    public init(_ placeholder: String, text: Binding<String>, onSubmit: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.onSubmit = onSubmit
    }

    public func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(string: text)

        // Angepasste Cell einsetzen (zentriert, borderless)
        let cell = CenteredPlainSearchFieldCell(textCell: "")
        cell.placeholderString = placeholder
        cell.font = .systemFont(ofSize: 16)
        field.cell = cell

        // Optik: borderless, kein Focus-Ring/Hintergrund
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = false

        // Interaktion
        field.isEditable = true
        field.isSelectable = true
        field.isContinuous = false
        field.usesSingleLineMode = true

        // Höhe via AutoLayout
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([ field.heightAnchor.constraint(equalToConstant: 38) ])

        field.target = context.coordinator
        field.action = #selector(Coordinator.didSubmit)

        // Fokus-Observer (selector-basiert, MainActor-sicher)
        context.coordinator.field = field
        context.coordinator.installFocusObserver()

        // (Wichtig für Stabilität) Kein placeholderAttributedString mit baselineOffset setzen!
        // -> Der Placeholder nutzt dieselbe Geometrie wie der Editor, daher kein Springen.

        // Delegate optional nur für Editor-Insets (kein baselineOffset!)
        field.delegate = context.coordinator

        return field
    }

    public func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    // MARK: - Coordinator

    @MainActor
    public final class Coordinator: NSObject, NSSearchFieldDelegate {
        weak var field: NSSearchField?
        var text: Binding<String>
        var onSubmit: (() -> Void)?
        var baselineNudge: CGFloat = 0
        private var observerInstalled = false

        init(text: Binding<String>, onSubmit: (() -> Void)?) {
            self.text = text
            self.onSubmit = onSubmit
        }
 
        // Einmalig registrieren (selector-basiert -> kein Token nötig)
        func installFocusObserver() {
            guard !observerInstalled else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleFocusNow(_:)),
                name: FocusableSearchField.focusNotification,
                object: nil
            )
            observerInstalled = true
        }

        @objc private func handleFocusNow(_ note: Notification) {
            guard let f = field, let win = f.window else { return }

            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(f)

            let moveCaret = {
                let end = (f.stringValue as NSString).length
                if let editor = f.currentEditor() {
                    editor.selectedRange = NSRange(location: end, length: 0)
                }
            }

            if f.currentEditor() == nil {
                DispatchQueue.main.async {
                    moveCaret()
                    // 🔁 falls irgendein später SelectAll kommt, direkt noch einmal neutralisieren
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { moveCaret() }
                }
            } else {
                moveCaret()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { moveCaret() }
            }
        }

        deinit {
            // selector-basierte Registrierung wird so entfernt
            NotificationCenter.default.removeObserver(self)
        }

        @objc func didSubmit(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
            onSubmit?()
        }
        
        // Delegate-Methode: beim Start des Editierens Editor anpassen
        public func controlTextDidBeginEditing(_ notification: Notification) {
            guard let tv = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            tv.textContainerInset = .zero
            tv.textContainer?.lineFragmentPadding = 0

            let full = tv.attributedString()
            let m = NSMutableAttributedString(attributedString: full)
            m.addAttribute(.baselineOffset, value: baselineNudge, range: NSRange(location: 0, length: m.length))
            tv.textStorage?.setAttributedString(m)

            var typing = tv.typingAttributes
            typing[.baselineOffset] = baselineNudge
            typing[.font] = typing[.font] ?? tv.font
            tv.typingAttributes = typing

            // ⤵️ WICHTIG: gleich zu Beginn jede evtl. Vollauswahl neutralisieren
            let end = (tv.string as NSString).length
            tv.selectedRange = NSRange(location: end, length: 0)
        }

        public func controlTextDidChange(_ notification: Notification) {
            guard let tv = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }

            // Baseline beibehalten
            var typing = tv.typingAttributes
            typing[.baselineOffset] = baselineNudge
            tv.typingAttributes = typing

            // ⤵️ Falls irgendwas (Plugins, spätes selectAll, etc.) erneut markiert:
            //     sofort auf Caret-Position ohne Auswahl trimmen.
            if tv.selectedRange.length > 0 {
                let end = (tv.string as NSString).length
                tv.selectedRange = NSRange(location: end, length: 0)
            }
        }
    }
}
