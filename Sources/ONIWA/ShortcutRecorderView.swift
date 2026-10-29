import AppKit
import Carbon.HIToolbox

/// A focused native key recorder. It only captures keyDown while this small
/// dialog is active; it does not install a system-wide event monitor.
final class ShortcutRecorderView: NSView {
    private let instruction = NSTextField(labelWithString: "ここをクリックして、新しいショートカットを押してください")
    private let selection = NSTextField(labelWithString: "キー入力を待っています…")
    private(set) var recorded: HotKeyCombination?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        instruction.alignment = .center
        instruction.font = .systemFont(ofSize: 12)
        instruction.textColor = .secondaryLabelColor

        selection.alignment = .center
        selection.font = .boldSystemFont(ofSize: 19)
        selection.textColor = .labelColor

        for label in [instruction, selection] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            instruction.centerXAnchor.constraint(equalTo: centerXAnchor),
            instruction.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -19),
            instruction.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            instruction.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            selection.centerXAnchor.constraint(equalTo: centerXAnchor),
            selection.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 17)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        selection.stringValue = recorded?.title ?? "キー入力を待っています…"
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard recorded == nil else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        selection.stringValue = text.isEmpty ? "キー入力を待っています…" : text + " …"
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            NSApp.stopModal(withCode: .abort)
            return
        }
        guard let combination = HotKeyCombination.capture(event) else {
            selection.stringValue = "⌘・⌃・⌥ のいずれか＋キーを押してください"
            NSSound.beep()
            return
        }
        recorded = combination
        selection.stringValue = combination.title
    }
}
