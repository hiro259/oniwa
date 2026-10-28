import AppKit
import SwiftUI
import ONIWACore

@MainActor
final class SearchState: ObservableObject {
    @Published var query = ""
    @Published var groups: [DisplayGroup] = []
    @Published var selectedID: String?
    @Published var editing = false
    @Published var nameDraft = ""
    @Published var aliasesDraft = ""
    @Published var errorMessage: String?
    @Published var isSwitching = false
    let labels = LabelStore()
    let switcher = SpaceSwitcher()
    var hidePanel: (() -> Void)?

    var all: [SpaceEntry] { groups.flatMap(\.spaces) }
    var results: [SpaceEntry] {
        FuzzySearch.sorted(all, query: query) { space in
            let label = labels.label(for: space)
            return [label?.name ?? "", label?.aliases ?? "",
                    space.defaultName, space.displayName] + space.appNames
        }
    }

    func refresh() {
        groups = SpaceReader.shared.displays()
        errorMessage = SpaceReader.shared.available
            ? (groups.isEmpty ? "No Spaces found. This macOS version may be unsupported." : nil)
            : "Could not load SkyLight. This macOS version may be unsupported."
        if !results.contains(where: { $0.id == selectedID }) {
            selectedID = results.first?.id
        }
    }

    func beginEdit(_ space: SpaceEntry) {
        selectedID = space.id
        let label = labels.label(for: space)
        nameDraft = label?.name ?? ""
        aliasesDraft = label?.aliases ?? ""
        editing = true
    }

    func saveLabel() {
        guard let space = all.first(where: { $0.id == selectedID }) else { return }
        labels.set(space, name: nameDraft, aliases: aliasesDraft)
        editing = false
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
                self.hidePanel = self.hidePanel // keep state intact
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
                Text("⌃⌘ O").foregroundStyle(.secondary).font(.caption)
            }
            TextField("Search Spaces, apps, or aliases…", text: $state.query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onSubmit { selectCurrent() }
            if let error = state.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(state.results) { space in
                        HStack(spacing: 9) {
                            Image(systemName: space.kind == 4 ? "arrow.up.left.and.arrow.down.right" : "display")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(state.labels.label(for: space)?.name.isEmpty == false
                                         ? (state.labels.label(for: space)?.name ?? space.defaultName)
                                         : space.defaultName)
                                        .fontWeight(space.id == state.selectedID ? .semibold : .regular)
                                    if space.isCurrent {
                                        Text("current").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                let alias = state.labels.label(for: space)?.aliases ?? ""
                                Text([space.displayName, space.appNames.joined(separator: ", "), alias]
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
                        .background(space.id == state.selectedID
                            ? Color.accentColor.opacity(0.16) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if state.selectedID == space.id { state.activate(space) }
                            else { state.selectedID = space.id }
                        }
                    }
                }
            }
            HStack {
                Text("↑↓ Select   ↵ Switch   Esc Close")
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
        .onMoveCommand { direction in
            let options = state.results
            guard !options.isEmpty else { return }
            let i = options.firstIndex(where: { $0.id == state.selectedID }) ?? 0
            if direction == .down { state.selectedID = options[min(i+1, options.count-1)].id }
            if direction == .up { state.selectedID = options[max(i-1, 0)].id }
        }
        .onExitCommand { state.hidePanel?() }
        .sheet(isPresented: $state.editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Name this Space").font(.headline)
                TextField("Display name", text: $state.nameDraft)
                TextField("Aliases (space-separated)", text: $state.aliasesDraft)
                HStack {
                    Spacer()
                    Button("Cancel") { state.editing = false }
                    Button("Save") { state.saveLabel() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    private func selectCurrent() {
        guard let selected = state.results.first(where: { $0.id == state.selectedID })
                ?? state.results.first else { return }
        state.activate(selected)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let shortcut = GlobalShortcut()
        shortcut.onPress = { [weak self] in self?.togglePanel() }
        self.shortcut = shortcut
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "庭"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Search Spaces…", action: #selector(openPanel), keyEquivalent: ""))
        if shortcut.registrationError != nil {
            let warning = NSMenuItem(title: "Shortcut unavailable — open from menu", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ONIWA", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        item.menu = menu
        statusItem = item
        state.hidePanel = { [weak self] in self?.panel?.orderOut(nil) }
        state.showPanel = { [weak self] in self?.openPanel() }
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openPanel() { presentPanel() }

    private func togglePanel() {
        if panel?.isVisible == true { panel?.orderOut(nil) }
        else { presentPanel() }
    }

    private func presentPanel() {
        state.query = ""
        state.refresh()
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
