import AppKit
import SwiftUI
import Carbon.HIToolbox
import CoreGraphics
import ONIWACore

@MainActor
final class SearchState: ObservableObject {
    @Published var query = ""
    @Published var groups: [DisplayGroup] = []
    @Published var selectedID: String?
    @Published var editing = false
    @Published var nameDraft = ""
    @Published var aliasesDraft = ""
    @Published var hasEditingLabel = false
    @Published var editingIsSessionOnly = false
    @Published var labelRevision = 0
    @Published var errorMessage: String?
    @Published var isSwitching = false
    @Published var shortcutDescription = "⌥ Space"
    let labels = SpaceLabelStore()
    private var editingIdentity: SpaceIdentity?
    let switcher = SpaceSwitcher()
    var hidePanel: (() -> Void)?

    var all: [SpaceEntry] { groups.flatMap(\.spaces) }
    var results: [SpaceEntry] {
        _ = labelRevision
        return FuzzySearch.sorted(all, query: query) { space in
            let label = labels.label(for: space.identity)
            return [label?.name ?? "", label?.aliases ?? "",
                    space.defaultName, space.displayName] + space.appNames
        }
    }

    func refresh() {
        groups = SpaceReader.shared.displays()
        if !groups.isEmpty { labels.reconcile(groups.flatMap(\.spaces).map(\.identity)) }
        errorMessage = SpaceReader.shared.available
            ? (groups.isEmpty ? "No Spaces found. This macOS version may be unsupported." : nil)
            : "Could not load SkyLight. This macOS version may be unsupported."
        if !results.contains(where: { $0.id == selectedID }) {
            selectedID = results.first?.id
        }
    }

    /// Keyboard navigation stays active even when the search TextField has focus.
    func moveSelection(by offset: Int) {
        let options = results
        guard !options.isEmpty else { return }
        let index = options.firstIndex(where: { $0.id == selectedID }) ?? (offset > 0 ? -1 : 0)
        let next = min(max(index + offset, 0), options.count - 1)
        selectedID = options[next].id
    }

    func activateSelected() {
        guard let selected = results.first(where: { $0.id == selectedID })
                ?? results.first else { return }
        activate(selected)
    }

    func beginEdit(_ space: SpaceEntry) {
        selectedID = space.id
        editingIdentity = space.identity
        let label = labels.label(for: space.identity)
        nameDraft = label?.name ?? ""
        aliasesDraft = label?.aliases ?? ""
        hasEditingLabel = label != nil
        editingIsSessionOnly = space.identity.persistentKey == nil
        editing = true
    }

    func cancelEdit() {
        editing = false
        editingIdentity = nil
    }

    /// Verify the selected live Space still exists before saving a name. This
    /// prevents editing a disappeared fullscreen Space from assigning a name
    /// to whatever later occupies its former position.
    private func liveEditingIdentity() -> SpaceIdentity? {
        guard let editingIdentity else { return nil }
        let live = SpaceReader.shared.displays(includeAppNames: false)
            .flatMap(\.spaces).map(\.identity)
        return live.first(where: { $0 == editingIdentity })
    }

    func saveLabel() {
        guard let identity = liveEditingIdentity() else {
            cancelEdit()
            errorMessage = "編集中のSpaceが見つかりません。検索一覧を更新してください。"
            return
        }
        labels.update(identity, name: nameDraft, aliases: aliasesDraft)
        labelRevision += 1
        cancelEdit()
        if !results.contains(where: { $0.id == selectedID }) {
            selectedID = results.first?.id
        }
    }

    func deleteLabel() {
        nameDraft = ""
        aliasesDraft = ""
        saveLabel()
    }

    func activate(_ space: SpaceEntry) {
        guard !isSwitching else { return }
        isSwitching = true
        hidePanel?()
        switcher.switchTo(space) { [weak self] outcome in
            guard let self else { return }
            self.isSwitching = false
            if case .failure(let error) = outcome {
                self.errorMessage = error.localizedDescription
                self.showError()
            }
        }
    }

    var showPanel: (() -> Void)?
    func showError() { showPanel?() }
}

struct SearchView: View {
    @ObservedObject var state: SearchState
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ONIWA").font(.headline)
                Spacer()
                Text(state.shortcutDescription).foregroundStyle(.secondary).font(.caption)
            }
            TextField("Search Spaces, apps, or aliases…", text: $state.query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onSubmit { state.activateSelected() }
            if let error = state.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(state.results) { space in
                        HStack(spacing: 9) {
                            Image(systemName: space.kind == 4 ? "arrow.up.left.and.arrow.down.right" : "display")
                                .foregroundStyle(space.isCurrent ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(state.labels.label(for: space.identity)?.name.isEmpty == false
                                         ? (state.labels.label(for: space.identity)?.name ?? space.defaultName)
                                         : space.defaultName)
                                        .fontWeight(space.id == state.selectedID || space.isCurrent
                                            ? .semibold : .regular)
                                        .lineLimit(1)
                                    if space.isCurrent {
                                        Label("表示中", systemImage: "checkmark.circle.fill")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(Color.green)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.green.opacity(0.14), in: Capsule())
                                            .fixedSize()
                                            .help("このモニターで現在表示されているSpace")
                                    }
                                }
                                let alias = state.labels.label(for: space.identity)?.aliases ?? ""
                                Text([space.displayName, "Space \(space.index + 1)",
                                      space.appNames.joined(separator: ", "), alias]
                                        .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                state.beginEdit(space)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("Rename or add aliases")
                        }
                        .padding(8)
                        // The accent background indicates keyboard selection.
                        // A green border and explicit badge indicate the actual
                        // visible Space, even when a different result is selected.
                        .background(space.id == state.selectedID
                            ? Color.accentColor.opacity(0.16)
                            : (space.isCurrent ? Color.green.opacity(0.06) : Color.clear))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(space.isCurrent ? Color.green.opacity(0.72) : Color.clear,
                                              lineWidth: 1.5)
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if state.selectedID == space.id { state.activate(space) }
                            else { state.selectedID = space.id }
                        }
                        .id(space.id)
                    }
                }
                }
                .onChange(of: state.selectedID) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        scroll.scrollTo(id, anchor: .center)
                    }
                }
            }
            HStack {
                Text("↑↓ 選択   ↵ 切り替え   Esc 閉じる")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { state.refresh() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(width: 500, height: 420)
        .onAppear { isSearchFocused = true }
        .onChange(of: state.query) { _ in state.selectedID = state.results.first?.id }
        .onChange(of: state.labelRevision) { _ in
            if !state.results.contains(where: { $0.id == state.selectedID }) {
                state.selectedID = state.results.first?.id
            }
        }
        .onMoveCommand { direction in
            if direction == .down { state.moveSelection(by: 1) }
            if direction == .up { state.moveSelection(by: -1) }
        }
        .onExitCommand { state.hidePanel?() }
        .sheet(isPresented: $state.editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Spaceの名前と検索用の別名").font(.headline)
                TextField("表示名（例：趣味）", text: $state.nameDraft)
                TextField("検索用の別名（例：shumi chrome）", text: $state.aliasesDraft)
                if state.editingIsSessionOnly {
                    Text("このSpaceには識別用UUIDがありません。誤ったSpaceへの名前引き継ぎを防ぐため、名前はONIWAを終了するまで有効です。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if state.hasEditingLabel {
                        Button("名前と別名を削除") { state.deleteLabel() }
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button("キャンセル") { state.cancelEdit() }
                    Button("保存") { state.saveLabel() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

 }

final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = SearchState()
    private var shortcut: GlobalShortcut?
    private var panel: SearchPanel?
    private var statusItem: NSStatusItem?
    private var keyboardMonitor: Any?
    private var instantSwitchItem: NSMenuItem?
    private var shortcutItems: [GlobalShortcut.Preset: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installKeyboardNavigation()
        let shortcut = GlobalShortcut()
        shortcut.onPress = { [weak self] in self?.togglePanel() }
        self.shortcut = shortcut
        state.shortcutDescription = shortcut.current.title
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "庭"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Search Spaces…", action: #selector(openPanel), keyEquivalent: ""))
        let shortcutRoot = NSMenuItem(title: "ショートカット", action: nil, keyEquivalent: "")
        let shortcutMenu = NSMenu(title: "ショートカット")
        for preset in GlobalShortcut.Preset.allCases {
            let option = NSMenuItem(title: preset == .optionSpace ? "⌥ Space（おすすめ）" : preset.title,
                                    action: #selector(changeShortcut(_:)),
                                    keyEquivalent: "")
            option.target = self
            option.representedObject = preset.rawValue
            option.state = preset.combination == shortcut.current ? .on : .off
            shortcutItems[preset] = option
            shortcutMenu.addItem(option)
        }
        shortcutMenu.addItem(NSMenuItem.separator())
        let recorderItem = NSMenuItem(title: "ショートカットを記録…",
                                      action: #selector(recordShortcut),
                                      keyEquivalent: "")
        recorderItem.target = self
        shortcutMenu.addItem(recorderItem)
        shortcutRoot.submenu = shortcutMenu
        menu.addItem(shortcutRoot)
        let instant = NSMenuItem(title: "瞬時切り替え（試験的）",
                                 action: #selector(toggleInstantSwitch),
                                 keyEquivalent: "")
        instant.toolTip = "ONIWAでのみ瞬時切り替えを使用します。失敗時は通常切り替えに戻ります。"
        instant.state = InstantSwitchSettings.enabled ? .on : .off
        instant.target = self
        instantSwitchItem = instant
        menu.addItem(instant)
        let diagnosis = NSMenuItem(title: "ショートカット診断…",
                                   action: #selector(showShortcutDiagnosis),
                                   keyEquivalent: "")
        diagnosis.target = self
        menu.addItem(diagnosis)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ONIWA", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        item.menu = menu
        statusItem = item
        state.hidePanel = { [weak self] in self?.panel?.orderOut(nil) }
        state.showPanel = { [weak self] in self?.presentPanel(resetSearch: false) }
    }

    @objc private func toggleInstantSwitch() {
        InstantSwitchSettings.enabled.toggle()
        instantSwitchItem?.state = InstantSwitchSettings.enabled ? .on : .off
    }

    @objc private func changeShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = GlobalShortcut.Preset(rawValue: raw),
              let shortcut else { return }
        if shortcut.register(preset.combination) {
            updateShortcutUI()
        } else {
            showShortcutFailure()
        }
    }

    private func updateShortcutUI() {
        guard let shortcut else { return }
        state.shortcutDescription = shortcut.current.title
        for (preset, item) in shortcutItems {
            item.state = preset.combination == shortcut.current ? .on : .off
        }
    }

    @objc private func recordShortcut() {
        guard let shortcut else { return }
        guard shortcut.beginRecording() else {
            showShortcutFailure()
            return
        }

        let recorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 390, height: 102))
        let alert = NSAlert()
        alert.messageText = "ショートカットを記録"
        alert.informativeText = """
        使いたいキーをそのまま押してください。⌘・⌃・⌥のいずれかが必要です。
        初期候補は ⌥ Space。保存できない場合は元のキーに戻します。
        """
        alert.alertStyle = .informational
        alert.accessoryView = recorder
        alert.addButton(withTitle: "設定する")
        alert.addButton(withTitle: "キャンセル")
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(recorder)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            _ = shortcut.endRecording(nil)
            updateShortcutUI()
            return
        }
        guard let candidate = recorder.recorded else {
            _ = shortcut.endRecording(nil)
            let warning = NSAlert()
            warning.messageText = "キーが記録されていません"
            warning.informativeText = "記録欄をクリックしてキーの組み合わせを押してください。"
            warning.runModal()
            return
        }
        if shortcut.endRecording(candidate) {
            updateShortcutUI()
        } else {
            updateShortcutUI()
            showShortcutFailure()
        }
    }

    private func showShortcutFailure() {
        let alert = NSAlert()
        alert.messageText = "ショートカットの設定に失敗しました"
        alert.informativeText = shortcut?.registrationError ?? "macOSまたは別のアプリと競合している可能性があります。"
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func showShortcutDiagnosis() {
        let alert = NSAlert()
        alert.messageText = "ONIWA ショートカット診断"
        let keyboardStatus = CGPreflightPostEventAccess()
            ? "許可済み（Core Graphics）" : "未許可（アクセシビリティの設定を確認）"
        let hotkeyStatus = shortcut?.diagnosticSummary()
            ?? "ショートカット管理が開始されていません。"
        alert.informativeText = hotkeyStatus + "\n\nキー操作の送信権限: " + keyboardStatus
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// The NSWindow field editor receives arrow keys first, so SwiftUI's
    /// onMoveCommand on the containing view is not a dependable way to move
    /// search selection. Only intercept while ONIWA's own panel is key.
    /// Regular text input, editing sheets and other apps are untouched.
    private func installKeyboardNavigation() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyboardEvent(event)
        }
    }

    private func handleKeyboardEvent(_ event: NSEvent) -> NSEvent? {
        guard panel?.isKeyWindow == true,
              !state.editing, !state.isSwitching else { return event }

        // Let macOS's input method handle candidate navigation and Return when
        // a Japanese/Chinese/Korean composition is still active.
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
           editor.hasMarkedText() {
            return event
        }

        // Modified arrows must retain normal text editing behavior.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !modifiers.intersection([.command, .control, .option, .shift]).isEmpty {
            return event
        }

        switch Int(event.keyCode) {
        case kVK_DownArrow:
            state.moveSelection(by: 1)
            return nil
        case kVK_UpArrow:
            state.moveSelection(by: -1)
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            state.activateSelected()
            return nil
        case kVK_Escape:
            panel?.orderOut(nil)
            return nil
        default:
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openPanel() { presentPanel() }

    private func togglePanel() {
        if panel?.isVisible == true { panel?.orderOut(nil) }
        else { presentPanel() }
    }

    private func presentPanel(resetSearch: Bool = true) {
        if resetSearch {
            state.query = ""
            state.refresh()
        }
        if panel == nil {
            let window = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                                     styleMask: [.titled, .fullSizeContentView],
                                     backing: .buffered, defer: false)
            window.title = "ONIWA"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: SearchView(state: state))
            panel = window
        }
        panel?.center()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
enum Launcher {
    static let delegate = AppDelegate()
    static func run() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

MainActor.assumeIsolated { Launcher.run() }
