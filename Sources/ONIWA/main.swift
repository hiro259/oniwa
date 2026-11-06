import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Carbon.HIToolbox
import CoreGraphics
import ONIWACore

/// A single visible list can interleave named sets and individual Spaces.
/// Space persistence uses the monitor-scoped UUID, never its shifting index.
enum SearchListItem: Identifiable {
    case pair(SpacePair)
    case space(SpaceEntry)

    var id: String {
        switch self {
        case .pair(let pair): return "pair:\(pair.id.uuidString)"
        case .space(let space): return space.id
        }
    }

    var orderKey: String {
        switch self {
        case .pair(let pair): return "pair:\(pair.id.uuidString)"
        case .space(let space):
            return space.identity.persistentKey ?? "transient:\(space.id)"
        }
    }
}

@MainActor
final class SearchState: ObservableObject {
    @Published var query = ""
    @Published var groups: [DisplayGroup] = []
    @Published var selectedID: String?
    @Published var editing = false
    @Published var nameDraft = ""
    @Published var tagsDraft: [String] = []
    @Published var editingTagIndex: Int?
    @Published var keywordInput = ""
    @Published var editingApps: [SpaceApp] = []
    @Published var hasEditingLabel = false
    @Published var editingIsSessionOnly = false
    @Published var labelRevision = 0
    @Published var errorMessage: String?
    @Published var isSwitching = false
    @Published var shortcutDescription = "⌥ Space"
    @Published var pairRevision = 0
    @Published var orderingRevision = 0
    @Published var searchFocusRequest = 0
    @Published var pairEditing = false
    @Published var pairNameDraft = ""
    @Published var pairFirstKey = ""
    @Published var pairSecondKey = ""
    @Published var editingPairID: UUID?
    let labels = SpaceLabelStore()
    let pairStore = SpacePairStore()
    let listOrder = SpaceListOrderStore()
    private var lastCurrentIDs: [String: UInt64] = [:]
    private var hasCurrentSnapshot = false
    private var editingIdentity: SpaceIdentity?
    let switcher = SpaceSwitcher()
    var hidePanel: (() -> Void)?
    var onPermissionFailure: (() -> Void)?
    var onVerifiedSpaceSwitch: (() -> Void)?

    /// A new request is emitted for each palette presentation. A Bool focus
    /// binding alone cannot reliably reassert focus after an NSPanel is reused.
    func requestSearchFocus() {
        guard !editing && !pairEditing else { return }
        searchFocusRequest &+= 1
    }

    var all: [SpaceEntry] { groups.flatMap(\.spaces) }
    var results: [SpaceEntry] {
        _ = labelRevision
        return FuzzySearch.ranked(all, query: query) { space in
            let label = labels.label(for: space.identity)
            var fields: [SearchField] = [
                SearchField(text: space.defaultName, kind: .defaultName),
                SearchField(text: space.displayName, kind: .display)
            ]
            if let name = label?.name, !name.isEmpty {
                fields.append(SearchField(text: name, kind: .name))
            }
            if let label {
                fields += label.searchTags.map {
                    SearchField(text: $0, kind: .keyword)
                }
            }
            fields += space.appNames.map { SearchField(text: $0, kind: .app) }
            return fields
        }
    }

    /// Keep individual Spaces in the existing result list. Pair rows are
    /// additional results and share the same keyboard selection mechanism.
    func pairResultID(_ pair: SpacePair) -> String { "pair:\(pair.id.uuidString)" }

    func spaceName(_ space: SpaceEntry) -> String {
        let name = labels.label(for: space.identity)?.name ?? ""
        return name.isEmpty ? space.defaultName : name
    }

    func monitorName(_ space: SpaceEntry) -> String {
        let number = (groups.firstIndex(where: { $0.id == space.displayID }) ?? 0) + 1
        return AppLanguage.ui("モニター\(number)（\(space.displayName)）", "Display \(number) (\(space.displayName))")
    }

    func resolvedSpaces(for pair: SpacePair) -> (SpaceEntry, SpaceEntry)? {
        guard let identities = SpacePairResolver.resolve(pair, in: all.map(\.identity)),
              let first = all.first(where: { $0.identity == identities.0 }),
              let second = all.first(where: { $0.identity == identities.1 })
        else { return nil }
        return (first, second)
    }

    var pairResults: [SpacePair] {
        _ = pairRevision
        return FuzzySearch.ranked(pairStore.pairs, query: query) { pair in
            var fields = [SearchField(text: pair.name, kind: .name)]
            if let (first, second) = resolvedSpaces(for: pair) {
                fields += [
                    SearchField(text: spaceName(first), kind: .keyword),
                    SearchField(text: spaceName(second), kind: .keyword)
                ]
                fields += (first.appNames + second.appNames)
                    .map { SearchField(text: $0, kind: .app) }
            }
            return fields
        }
    }

    /// On an empty query: pinned first in the order they were pinned, then
    /// recently-used items. During a query, pins remain first and fuzzy rank
    /// is retained for other matches.
    var orderedItems: [SearchListItem] {
        _ = orderingRevision
        let candidates: [SearchListItem] =
            pairResults.map { .pair($0) } + results.map { .space($0) }
        // On malformed/duplicate UUIDs, do not crash constructing a
        // dictionary. Preserve every candidate and its original relative order.
        var byKey: [String: [SearchListItem]] = [:]
        for candidate in candidates {
            byKey[candidate.orderKey, default: []].append(candidate)
        }
        let useRecency = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var names: [String: String] = [:]
        for item in candidates {
            switch item {
            case .pair(let pair): names[item.orderKey] = pair.name
            case .space(let space): names[item.orderKey] = spaceName(space)
            }
        }
        return listOrder.orderedKeys(candidates.map(\.orderKey),
                                     useRecency: useRecency, names: names)
            .compactMap { key in
                guard var bucket = byKey[key], !bucket.isEmpty else { return nil }
                let result = bucket.removeFirst()
                byKey[key] = bucket
                return result
            }
    }

    var allResultIDs: [String] { orderedItems.map(\.id) }

    var sortMode: SpaceListSortMode { listOrder.sortMode }

    var canReorderByDrag: Bool {
        sortMode == .custom && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func changeSortMode(_ mode: SpaceListSortMode) {
        guard mode != listOrder.sortMode else { return }
        // Seed the first custom order from the current full list, not a search
        // subset. Preserve the previous custom layout when switching modes.
        let entries: [SearchListItem] = pairStore.pairs.map { .pair($0) }
            + all.map { .space($0) }
        var names: [String: String] = [:]
        for entry in entries {
            switch entry {
            case .pair(let pair): names[entry.orderKey] = pair.name
            case .space(let space): names[entry.orderKey] = spaceName(space)
            }
        }
        let seed = listOrder.orderedKeys(entries.map(\.orderKey), names: names)
        listOrder.setSortMode(mode, visibleKeys: seed)
        orderingRevision += 1
    }

    func reorderRow(from source: String, to destination: String) {
        guard canReorderByDrag, !source.hasPrefix("transient:"),
              !destination.hasPrefix("transient:") else { return }
        let visibleKeys = orderedItems.map(\.orderKey)
        if listOrder.moveCustom(source, to: destination, visibleKeys: visibleKeys) {
            orderingRevision += 1
        }
    }

    func isPinned(_ pair: SpacePair) -> Bool {
        listOrder.isPinned(pairResultID(pair))
    }

    func isPinned(_ space: SpaceEntry) -> Bool {
        guard let key = space.identity.persistentKey else { return false }
        return listOrder.isPinned(key)
    }

    func togglePin(_ pair: SpacePair) {
        listOrder.togglePin(pairResultID(pair))
        orderingRevision += 1
    }

    func togglePin(_ space: SpaceEntry) {
        guard let key = space.identity.persistentKey else { return }
        listOrder.togglePin(key)
        orderingRevision += 1
    }

    /// Track manual macOS Mission Control/keyboard switches too, not just
    /// ONIWA-initiated transitions. The first snapshot is only a baseline.
    func observeCurrentSpaces(_ snapshot: [DisplayGroup]? = nil) {
        let live = snapshot ?? SpaceReader.shared.displays(includeAppNames: false)
        guard !live.isEmpty else { return }
        var changed = false
        for group in live {
            guard let current = group.currentID else { continue }
            if hasCurrentSnapshot, lastCurrentIDs[group.id] != nil,
               lastCurrentIDs[group.id] != current,
               let space = group.spaces.first(where: { $0.systemID == current }),
               let key = space.identity.persistentKey {
                listOrder.markUsed(key)
                changed = true
            }
        }
        lastCurrentIDs = Dictionary(uniqueKeysWithValues: live.compactMap { group in
            group.currentID.map { (group.id, $0) }
        })
        hasCurrentSnapshot = true
        if changed { orderingRevision += 1 }
    }

    var pairEligibleSpaces: [SpaceEntry] {
        // Two-display sets still require real UUIDs. The special blank-UUID
        // desktop anchor is for names/tags/pins only, not pair targets.
        all.filter { $0.identity.uuid != nil }
    }

    var pairSecondChoices: [SpaceEntry] {
        guard let first = pairEligibleSpaces.first(where: {
            $0.identity.persistentKey == pairFirstKey
        }) else { return [] }
        return pairEligibleSpaces.filter { $0.displayID != first.displayID }
    }

    var pairCanSave: Bool {
        guard !SpacePair.cleanedName(pairNameDraft).isEmpty,
              let first = pairEligibleSpaces.first(where: {
                  $0.identity.persistentKey == pairFirstKey
              }),
              let second = pairSecondChoices.first(where: {
                  $0.identity.persistentKey == pairSecondKey
              }),
              let a = SpacePairTarget(identity: first.identity),
              let b = SpacePairTarget(identity: second.identity)
        else { return false }
        let sample = SpacePair(name: pairNameDraft, first: a, second: b)
        return SpacePairResolver.resolve(sample, in: all.map(\.identity)) != nil
    }

    func newPair() {
        let choices = pairEligibleSpaces
        guard let first = choices.first,
              let second = choices.first(where: { $0.displayID != first.displayID })
        else {
            errorMessage = AppLanguage.ui("別々の2画面に、登録できるSpaceが必要です。", "Two displays with available Spaces are required.")
            return
        }
        pairNameDraft = ""
        pairFirstKey = first.identity.persistentKey ?? ""
        pairSecondKey = second.identity.persistentKey ?? ""
        editingPairID = nil
        pairEditing = true
    }

    func beginPairEdit(_ pair: SpacePair) {
        pairNameDraft = pair.name
        pairFirstKey = pair.first.persistentKey
        pairSecondKey = pair.second.persistentKey
        editingPairID = pair.id
        pairEditing = true
    }

    func firstPairSpaceChanged() {
        if !pairSecondChoices.contains(where: {
            $0.identity.persistentKey == pairSecondKey
        }) {
            pairSecondKey = pairSecondChoices.first?.identity.persistentKey ?? ""
        }
    }

    func savePair() {
        // Re-read live Spaces before persisting; never save a position-only or
        // stale target after a display is disconnected or a Space recreated.
        guard pairCanSave,
              let first = pairEligibleSpaces.first(where: {
                  $0.identity.persistentKey == pairFirstKey
              }),
              let second = pairSecondChoices.first(where: {
                  $0.identity.persistentKey == pairSecondKey
              }),
              let a = SpacePairTarget(identity: first.identity),
              let b = SpacePairTarget(identity: second.identity),
              let resolved = SpacePairResolver.resolve(
                  SpacePair(name: pairNameDraft, first: a, second: b),
                  in: SpaceReader.shared.displays(includeAppNames: false)
                      .flatMap(\.spaces).map(\.identity))
        else {
            errorMessage = AppLanguage.ui("セットを保存できません。Spaceを選び直してください。", "Couldn't save the set. Choose the Spaces again.")
            pairEditing = false
            return
        }
        _ = resolved
        let pair = SpacePair(id: editingPairID ?? UUID(),
                             name: pairNameDraft, first: a, second: b)
        guard pairStore.save(pair) else { return }
        pairRevision += 1
        pairEditing = false
        query = ""
        selectedID = pairResultID(pair)
    }

    func deletePair() {
        if let id = editingPairID {
            pairStore.delete(id: id)
            listOrder.remove("pair:\(id.uuidString)")
            pairRevision += 1
            orderingRevision += 1
        }
        pairEditing = false
        editingPairID = nil
        selectedID = allResultIDs.first
    }

    func activatePair(_ pair: SpacePair) {
        guard !isSwitching else { return }
        SpaceSwitchDiagnostics.record(
            "ui-activate pair name=\(SpaceSwitchDiagnostics.safe(pair.name)) "
            + "first=\(SpaceSwitchDiagnostics.shortDisplay(pair.first.displayID)):"
            + "\(String(pair.first.uuid.prefix(8))) "
            + "second=\(SpaceSwitchDiagnostics.shortDisplay(pair.second.displayID)):"
            + "\(String(pair.second.uuid.prefix(8)))"
        )
        guard let targets = resolvedSpaces(for: pair) else {
            errorMessage = AppLanguage.ui("セットのSpaceが見つかりません。セットを編集してください。", "Set Spaces weren't found. Edit the set.")
            return
        }
        let requestedMove = !targets.0.isCurrent || !targets.1.isCurrent
        isSwitching = true
        hidePanel?()
        switcher.switchToPair(pair) { [weak self] outcome in
            guard let self else { return }
            self.isSwitching = false
            switch outcome {
            case .success:
                self.listOrder.markUsed(self.pairResultID(pair))
                self.orderingRevision += 1
                if requestedMove { self.onVerifiedSpaceSwitch?() }
            case .failure(let error):
                self.handleSwitchFailure(error)
            }
        }
    }

    func refresh() {
        groups = SpaceReader.shared.displays()
        observeCurrentSpaces(groups)
        if !groups.isEmpty { labels.reconcile(groups.flatMap(\.spaces).map(\.identity)) }
        errorMessage = SpaceReader.shared.available
            ? (groups.isEmpty ? AppLanguage.ui("Spaceが見つかりません。このmacOSには未対応の可能性があります。", "No Spaces found. This macOS version may be unsupported.") : nil)
            : AppLanguage.ui("Space情報を取得できません。このmacOSには未対応の可能性があります。", "Couldn't read Spaces. This macOS version may be unsupported.")
        if !allResultIDs.contains(selectedID ?? "") {
            selectedID = allResultIDs.first
        }
    }

    /// Keyboard navigation stays active even when the search TextField has focus.
    func moveSelection(by offset: Int) {
        let ids = allResultIDs
        guard !ids.isEmpty else { return }
        let index = ids.firstIndex(of: selectedID ?? "") ?? (offset > 0 ? -1 : 0)
        let next = min(max(index + offset, 0), ids.count - 1)
        selectedID = ids[next]
    }

    func activateSelected() {
        // A stale keyboard selection must NEVER silently activate the first
        // search result. The first result could be a completely different
        // Space (or a pair) after a refresh or a changing query.
        guard let selectedID else {
            SpaceSwitchDiagnostics.record("ui-activate aborted: no selected result")
            return
        }
        if let pair = pairResults.first(where: { pairResultID($0) == selectedID }) {
            activatePair(pair)
        } else if let space = results.first(where: { $0.id == selectedID }) {
            activate(space)
        } else {
            SpaceSwitchDiagnostics.record("ui-activate aborted: stale selected result")
            errorMessage = AppLanguage.ui("選択したSpaceが見つかりません。選び直してください。", "The selected Space is no longer available. Select it again.")
            selectedIDReset()
        }
    }

    private func selectedIDReset() {
        selectedID = allResultIDs.first
    }

    func beginEdit(_ space: SpaceEntry) {
        selectedID = space.id
        editingIdentity = space.identity
        let label = labels.label(for: space.identity)
        nameDraft = label?.name ?? ""
        tagsDraft = label?.searchTags ?? []
        editingTagIndex = nil
        keywordInput = ""
        editingApps = space.apps
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

    /// Clicking a chip loads it into the text field; Enter commits the edit.
    /// An unfinished new tag is committed before editing an existing one, to
    /// avoid discarding text when users move between tags.
    func beginTagEdit(at index: Int) {
        guard tagsDraft.indices.contains(index) else { return }
        let target = tagsDraft[index]
        // Commit any unfinished tag (including a prior edit) before moving
        // focus; preserve the target even if de-duplication changes indices.
        commitPendingKeyword()
        guard let liveIndex = tagsDraft.firstIndex(of: target) else { return }
        editingTagIndex = liveIndex
        keywordInput = tagsDraft[liveIndex]
    }

    /// The only typing delimiter is Return. Spaces remain inside one tag.
    func commitPendingKeyword() {
        let input = SpaceLabel.cleanedTags([keywordInput]).first
        if let index = editingTagIndex, tagsDraft.indices.contains(index) {
            if let input { tagsDraft[index] = input }
        } else if let input {
            tagsDraft.append(input)
        }
        tagsDraft = SpaceLabel.cleanedTags(tagsDraft)
        keywordInput = ""
        editingTagIndex = nil
    }

    /// Clicking a detected app toggles its manual search tag in the draft.
    /// Removal uses the same path as a tag chip's X so an in-progress manual
    /// tag edit maintains its correct index (or is cancelled if removed).
    /// Save remains the only operation that persists the change.
    func toggleDetectedAppTag(_ name: String) {
        guard editing, editingApps.contains(where: { $0.name == name }) else { return }
        if let index = DetectedAppTag.matchingIndex(of: name, in: tagsDraft) {
            removeTag(at: index)
        } else {
            tagsDraft = DetectedAppTag.adding(name, to: tagsDraft)
        }
    }

    func isDetectedAppTagged(_ name: String) -> Bool {
        DetectedAppTag.isAdded(name, to: tagsDraft)
    }

    func removeTag(at index: Int) {
        guard tagsDraft.indices.contains(index) else { return }
        tagsDraft.remove(at: index)
        if let editingTagIndex {
            if editingTagIndex == index {
                keywordInput = ""
                self.editingTagIndex = nil
            } else if editingTagIndex > index {
                self.editingTagIndex = editingTagIndex - 1
            }
        }
    }

    func saveLabel() {
        commitPendingKeyword()
        guard let identity = liveEditingIdentity() else {
            cancelEdit()
            errorMessage = AppLanguage.ui("Spaceが見つかりません。一覧を更新してください。", "Space not found. Refresh the list.")
            return
        }
        labels.update(identity, name: nameDraft, tags: tagsDraft)
        labelRevision += 1
        cancelEdit()
        if !results.contains(where: { $0.id == selectedID }) {
            selectedID = results.first?.id
        }
    }

    func deleteLabel() {
        nameDraft = ""
        tagsDraft = []
        keywordInput = ""
        editingTagIndex = nil
        saveLabel()
    }

    func activate(_ space: SpaceEntry) {
        guard !isSwitching else { return }
        let shownName = SpaceSwitchDiagnostics.safe(spaceName(space))
        let apps = space.appNames.prefix(4).map { SpaceSwitchDiagnostics.safe($0) }
            .joined(separator: ",")
        SpaceSwitchDiagnostics.record(
            "ui-activate single name=\(shownName) "
            + "display=\(SpaceSwitchDiagnostics.shortDisplay(space.displayID)) "
            + "space=\(space.systemID) uuid=\(space.identity.uuid.map { String($0.prefix(8)) } ?? "none") "
            + "apps=[\(apps)] selectedID=\(SpaceSwitchDiagnostics.safe(selectedID ?? "none"))"
        )
        let requestedMove = !space.isCurrent
        isSwitching = true
        hidePanel?()
        switcher.switchTo(space) { [weak self] outcome in
            guard let self else { return }
            self.isSwitching = false
            switch outcome {
            case .success:
                if let key = space.identity.persistentKey {
                    self.listOrder.markUsed(key)
                    self.orderingRevision += 1
                }
                if requestedMove { self.onVerifiedSpaceSwitch?() }
            case .failure(let error):
                self.handleSwitchFailure(error)
            }
        }
    }

    private func handleSwitchFailure(_ error: Error) {
        // A clean Developer ID install can lack keyboard-posting permission even
        // when an older development app with the same bundle ID was approved.
        if PermissionSetupController.needsSetup {
            errorMessage = nil
            onPermissionFailure?()
        } else {
            errorMessage = error.localizedDescription
            showError()
        }
    }

    var showPanel: (() -> Void)?
    func showError() { showPanel?() }
}

/// Search keywords and transient app names deliberately use different chips.
private struct SpaceTag: View {
    let title: String
    let isAutomatic: Bool
    let design: PaletteDesign

    init(title: String, isAutomatic: Bool, design: PaletteDesign = .nativeCalm) {
        self.title = title
        self.isAutomatic = isAutomatic
        self.design = design
    }

    var body: some View {
        HStack(spacing: 2) {
            if isAutomatic {
                Image(systemName: "app")
            } else {
                Text("#")
            }
            Text(title).lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, design == .pureMonochrome || design == .macOSNative ? 2 : 7)
        .padding(.vertical, design == .pureMonochrome || design == .macOSNative ? 1 : 3)
        .background(Color.secondary.opacity(design == .pureMonochrome || design == .macOSNative
            ? 0 : (isAutomatic ? 0.06 : 0.11)), in: Capsule())
        .help(isAutomatic ? AppLanguage.ui("アプリから自動取得", "Detected app (automatic)") : AppLanguage.ui("登録した検索タグ", "Saved search tag"))
    }
}

/// Reorder on hover, not on mouse release. As the dragged row crosses each
/// neighboring row, SwiftUI animates the surrounding rows into their new
/// positions. This is local-only: pin boundaries are never crossed.
private struct LiveSpaceReorderDelegate: DropDelegate {
    let targetKey: String
    let state: SearchState
    @Binding var draggingKey: String?

    private var sourceKey: String? {
        guard state.canReorderByDrag, let key = draggingKey,
              !key.hasPrefix("transient:"), !targetKey.hasPrefix("transient:"),
              state.listOrder.isPinned(key) == state.listOrder.isPinned(targetKey)
        else { return nil }
        return key
    }

    func validateDrop(info: DropInfo) -> Bool {
        sourceKey != nil && info.hasItemsConforming(to: [UTType.plainText.identifier])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info),
              let source = sourceKey, source != targetKey else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            state.reorderRow(from: source, to: targetKey)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        // The list is already in its final order from dropEntered.
        draggingKey = nil
        return true
    }
}

struct SearchView: View {
    @ObservedObject var state: SearchState
    @AppStorage(PaletteDesign.settingsKey) private var paletteRaw = PaletteDesign.macOSNative.rawValue
    @AppStorage(AppLanguage.settingsKey) private var languageRaw = AppLanguage.automaticValue
    private var design: PaletteDesign { PaletteDesign.active(rawValue: paletteRaw) }
    private var language: AppLanguage { AppLanguage.effective(rawValue: languageRaw) }
    private func t(_ ja: String, _ en: String) -> String { language.text(ja, en) }
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isTagInputFocused: Bool
    @FocusState private var isNameInputFocused: Bool
    @FocusState private var isPairNameInputFocused: Bool
    @State private var draggingOrderKey: String?
    @State private var hoveredItemID: String?

    /// macOS Native keeps the same row controls visible for keyboard selection
    /// and pointer hover, including when they refer to different rows.
    private func showsRowControls(for id: String) -> Bool {
        design != .macOSNative || state.selectedID == id || hoveredItemID == id
    }

    private var sortTitle: String {
        switch state.sortMode {
        case .recent: return t("最近使った順", "Recently used")
        case .original: return t("元の並び", "Original order")
        case .name: return t("名前順", "Name")
        case .custom: return t("手動で並べ替え", "Custom order")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: design.stackSpacing) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ONIWA").font(design.headingFont)
                    if design.showsSubtitle {
                        Text(design.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(state.shortcutDescription)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            if design.isRefined {
                HStack(spacing: 11) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(t("Spaceやセットを検索", "Search Spaces or sets"), text: $state.query)
                        .textFieldStyle(.plain)
                        .font(design.searchFont)
                        .focused($isSearchFocused)
                        .onSubmit { state.activateSelected() }
                        .accessibilityLabel(t("Spaceやセットを検索", "Search Spaces or sets"))
                }
                .modifier(RefinedSearchSurface(design: design, isFocused: isSearchFocused))
            } else {
                TextField(t("Spaceやセットを検索", "Search Spaces or sets"), text: $state.query)
                    .textFieldStyle(.roundedBorder)
                    .font(design.searchFont)
                    .controlSize(design == .commandCompact ? .small : .regular)
                    .padding(.vertical, design.hasMaterialSurface ? 4 : 0)
                    .padding(.horizontal, design.hasMaterialSurface ? 5 : 0)
                    .background {
                        if design.hasMaterialSurface {
                            RoundedRectangle(cornerRadius: 11).fill(.regularMaterial)
                        }
                    }
                    .focused($isSearchFocused)
                    .onSubmit { state.activateSelected() }
            }
            HStack(spacing: 6) {
                if design == .macOSNative {
                    Menu {
                        Button(t("最近使った順", "Recently used")) { state.changeSortMode(.recent) }
                        Button(t("元の並び", "Original order")) { state.changeSortMode(.original) }
                        Button(t("名前順", "Name")) { state.changeSortMode(.name) }
                        Button(t("手動で並べ替え", "Custom order")) { state.changeSortMode(.custom) }
                    } label: {
                        Label(sortTitle, systemImage: "arrow.up.arrow.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(t("並び替え: ", "Sort: ") + sortTitle)
                } else {
                    Text(t("並び替え", "Sort"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(t("並び替え", "Sort"), selection: Binding(
                        get: { state.sortMode },
                        set: { state.changeSortMode($0) }
                    )) {
                        Text(t("最近使った順", "Recently used")).tag(SpaceListSortMode.recent)
                        Text(t("元の並び", "Original order")).tag(SpaceListSortMode.original)
                        Text(t("名前順", "Name")).tag(SpaceListSortMode.name)
                        Text(t("手動で並べ替え", "Custom order")).tag(SpaceListSortMode.custom)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
                Spacer()
                if state.canReorderByDrag && design != .macOSNative {
                    Text(t("つまみをドラッグして並べ替え", "Drag the handle to reorder"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = state.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: design.rowSpacing) {
                    ForEach(state.orderedItems) { item in
                        switch item {
                        case .pair(let pair):
                        let destination = state.resolvedSpaces(for: pair)
                        let isCurrent = destination.map { $0.0.isCurrent && $0.1.isCurrent } ?? false
                        HStack(spacing: design == .studioCards ? 13 : 9) {
                            Image(systemName: "square.on.square")
                                .foregroundStyle(design.isRefined && state.pairResultID(pair) == state.selectedID
                                    ? design.controlAccent : Color.secondary)
                                .frame(width: design.leadingIconWidth)
                                .padding(.vertical, design == .studioCards ? 8 : 0)
                                .background {
                                    if design == .studioCards {
                                        RoundedRectangle(cornerRadius: 9)
                                            .fill(Color.accentColor.opacity(0.12))
                                    }
                                }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(pair.name)
                                        .font(design.titleFont)
                                        .fontWeight(state.pairResultID(pair) == state.selectedID
                                            || isCurrent ? .semibold : (design == .modernPrecision
                                                ? .medium : .regular))
                                        .lineLimit(1)
                                    Text(t("セット", "Set"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(design == .pureMonochrome || design == .macOSNative
                                            ? 0 : 0.10), in: Capsule())
                                    if isCurrent {
                                        Label(t("表示中", "current"), systemImage: "checkmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let (first, second) = destination {
                                    Text("\(state.monitorName(first)): \(state.spaceName(first))  +  \(state.monitorName(second)): \(state.spaceName(second))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    let pairApps = SpaceApp.unique(first.apps + second.apps)
                                    if !pairApps.isEmpty {
                                        HStack(spacing: 4) {
                                            ForEach(Array(pairApps.prefix(4)), id: \.name) { app in
                                                SpaceAppChip(app: app)
                                            }
                                            if pairApps.count > 4 {
                                                Text("+\(pairApps.count - 4)")
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                        .lineLimit(1)
                                    }
                                    if design.showsMonitorBadge {
                                        Label(t("2画面セット", "Two-display set"), systemImage: "display.2")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Label(t("Spaceが見つかりません。セットを編集してください", "Spaces unavailable. Edit this set."),
                                          systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if state.canReorderByDrag {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.secondary)
                                    .help(t("ドラッグして並べ替え", "Drag to reorder"))
                                    .onDrag {
                                        draggingOrderKey = "pair:\(pair.id.uuidString)"
                                        return NSItemProvider(
                                            object: "pair:\(pair.id.uuidString)" as NSString)
                                    }
                                    .modifier(PaletteHoverActions(
                                        isVisible: showsRowControls(
                                            for: state.pairResultID(pair))))
                            }
                            HStack(spacing: 9) {
                                Button {
                                    state.togglePin(pair)
                                } label: {
                                    Image(systemName: state.isPinned(pair) ? "pin.fill" : "pin")
                                        .foregroundStyle(design == .macOSNative
                                            ? Color.secondary.opacity(0.78)
                                            : (state.isPinned(pair)
                                                ? design.controlAccent : Color.secondary))
                                }
                                .buttonStyle(.borderless)
                                .help(state.isPinned(pair) ? t("ピン留めを解除", "Unpin") : t("先頭にピン留め", "Pin to top"))
                                .accessibilityLabel(state.isPinned(pair)
                                    ? t("セットのピン留めを解除", "Unpin set") : t("セットをピン留め", "Pin set"))
                                Button {
                                    state.beginPairEdit(pair)
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help(t("セットを編集", "Edit set"))
                            }
                            .modifier(PaletteHoverActions(
                                isVisible: showsRowControls(
                                    for: state.pairResultID(pair))))
                        }
                        .padding(.horizontal, design.rowHorizontalPadding)
                        .padding(.vertical, design.rowVerticalPadding)
                        .modifier(PaletteRowSurface(
                            design: design,
                            isSelected: state.pairResultID(pair) == state.selectedID,
                            isCurrent: isCurrent,
                            isHovered: hoveredItemID == state.pairResultID(pair)))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if state.selectedID == state.pairResultID(pair) {
                                state.activatePair(pair)
                            } else {
                                state.selectedID = state.pairResultID(pair)
                            }
                        }
                        .onHover { hovering in
                            guard design.isRefined else { return }
                            if hovering {
                                hoveredItemID = state.pairResultID(pair)
                            } else if hoveredItemID == state.pairResultID(pair) {
                                hoveredItemID = nil
                            }
                        }
                        .contextMenu {
                            if design == .macOSNative {
                                Button(state.isPinned(pair) ? t("ピン留めを解除", "Unpin") : "ピン留め") {
                                    state.togglePin(pair)
                                }
                                Button("セットを編集") { state.beginPairEdit(pair) }
                            }
                        }
                        .id(state.pairResultID(pair))
                        .onDrop(
                            of: [UTType.plainText.identifier],
                            delegate: LiveSpaceReorderDelegate(
                                targetKey: "pair:\(pair.id.uuidString)",
                                state: state, draggingKey: $draggingOrderKey)
                        )
                        case .space(let space):
                        HStack(spacing: design == .studioCards ? 13 : 9) {
                            Image(systemName: space.kind == 4 ? "arrow.up.left.and.arrow.down.right" : "display")
                                .foregroundStyle(design.isRefined && space.id == state.selectedID
                                    ? design.controlAccent : Color.secondary)
                                .frame(width: design.leadingIconWidth)
                                .padding(.vertical, design == .studioCards ? 8 : 0)
                                .background {
                                    if design == .studioCards {
                                        RoundedRectangle(cornerRadius: 9)
                                            .fill(Color.accentColor.opacity(0.12))
                                    }
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(state.labels.label(for: space.identity)?.name.isEmpty == false
                                         ? (state.labels.label(for: space.identity)?.name ?? space.defaultName)
                                         : space.defaultName)
                                        .font(design.titleFont)
                                        .fontWeight(space.id == state.selectedID || space.isCurrent
                                            ? .semibold : (design == .modernPrecision
                                                ? .medium : .regular))
                                        .lineLimit(1)
                                    if space.isCurrent {
                                        Label("current", systemImage: "checkmark.circle.fill")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(Color.secondary.opacity(design == .pureMonochrome || design == .macOSNative
                                                ? 0 : 0.09), in: Capsule())
                                            .fixedSize()
                                            .help(t("この画面に表示中", "Visible on this display"))
                                    }
                                }
                                HStack(spacing: 6) {
                                    if design.showsMonitorBadge {
                                        Text("M\((state.groups.firstIndex(where: { $0.id == space.displayID }) ?? 0) + 1)")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(Color.secondary.opacity(0.12), in: Capsule())
                                    }
                                    Text("\(space.displayName) · Space \(space.index + 1)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                // Saved search keywords and current apps appear
                                // as tags, but only the manual tags are persisted.
                                let manualTags = state.labels.label(for: space.identity)?.searchTags ?? []
                                if !manualTags.isEmpty || !space.apps.isEmpty {
                                    HStack(spacing: 4) {
                                        ForEach(Array(manualTags.prefix(2)), id: \.self) { tag in
                                            SpaceTag(title: tag, isAutomatic: false, design: design)
                                        }
                                        ForEach(Array(space.apps.prefix(4)), id: \.name) { app in
                                            SpaceAppChip(app: app)
                                        }
                                        let extra = max(0, manualTags.count - 2)
                                            + max(0, space.apps.count - 4)
                                        if extra > 0 {
                                            Text("+\(extra)").font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .lineLimit(1)
                                }
                            }
                            Spacer()
                            if state.canReorderByDrag,
                               let key = space.identity.persistentKey {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.secondary)
                                    .help(t("ドラッグして並べ替え", "Drag to reorder"))
                                    .onDrag {
                                        draggingOrderKey = key
                                        return NSItemProvider(object: key as NSString)
                                    }
                                    .modifier(PaletteHoverActions(
                                        isVisible: showsRowControls(for: space.id)))
                            }
                            HStack(spacing: 9) {
                                Button {
                                    state.togglePin(space)
                                } label: {
                                    Image(systemName: state.isPinned(space) ? "pin.fill" : "pin")
                                        .foregroundStyle(design == .macOSNative
                                            ? Color.secondary.opacity(0.78)
                                            : (state.isPinned(space)
                                                ? design.controlAccent : Color.secondary))
                                }
                                .buttonStyle(.borderless)
                                .disabled(space.identity.persistentKey == nil)
                                .help(space.identity.persistentKey == nil
                                    ? t("このSpaceはピン留めを保存できません", "Pinning cannot be saved for this Space")
                                    : (state.isPinned(space) ? t("ピン留めを解除", "Unpin") : t("先頭にピン留め", "Pin to top")))
                                .accessibilityLabel(state.isPinned(space)
                                    ? t("Spaceのピン留めを解除", "Unpin Space") : t("Spaceをピン留め", "Pin Space"))
                                Button {
                                    state.beginEdit(space)
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help(t("名前とタグを編集", "Edit name and tags"))
                            }
                            .modifier(PaletteHoverActions(
                                isVisible: showsRowControls(for: space.id)))
                        }
                        .padding(.horizontal, design.rowHorizontalPadding)
                        .padding(.vertical, design.rowVerticalPadding)
                        // Neutral current state differs from keyboard selection.
                        .modifier(PaletteRowSurface(
                            design: design,
                            isSelected: space.id == state.selectedID,
                            isCurrent: space.isCurrent,
                            isHovered: hoveredItemID == space.id))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if state.selectedID == space.id { state.activate(space) }
                            else { state.selectedID = space.id }
                        }
                        .onHover { hovering in
                            guard design.isRefined else { return }
                            if hovering {
                                hoveredItemID = space.id
                            } else if hoveredItemID == space.id {
                                hoveredItemID = nil
                            }
                        }
                        .contextMenu {
                            if design == .macOSNative {
                                Button(state.isPinned(space) ? t("ピン留めを解除", "Unpin") : "ピン留め") {
                                    state.togglePin(space)
                                }
                                .disabled(space.identity.persistentKey == nil)
                                Button(t("名前とタグを編集", "Edit name and tags")) { state.beginEdit(space) }
                            }
                        }
                        .id(space.id)
                        .onDrop(
                            of: [UTType.plainText.identifier],
                            delegate: LiveSpaceReorderDelegate(
                                targetKey: space.identity.persistentKey
                                    ?? "transient:\(space.id)",
                                state: state, draggingKey: $draggingOrderKey)
                        )
                        }
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
                Text(t("↑↓ 選択   Enter 切替   Esc 閉じる", "↑↓ Select   Enter Switch   Esc Close"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    state.newPair()
                } label: {
                    Label(t("セットを追加", "Add set"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Button(t("更新", "Refresh")) { state.refresh() }
                    .buttonStyle(.borderless)
            }
        }
        // The native panel already uses .fullSizeContentView. Reclaim the
        // otherwise unused titlebar safe-area inset instead of shrinking rows.
        // Leave a small top margin so the header doesn't touch the window edge.
        .padding(.horizontal, design.contentPadding)
        .padding(.bottom, design.contentPadding)
        .padding(.top, design == .macOSNative ? 14 : design.contentPadding)
        // The window owns the height. Avoid clipping the results when the
        // selected display is smaller than the preferred six-row palette.
        .frame(width: design.panelSize.width)
        .frame(maxHeight: .infinity)
        .background {
            if design == .macOSNative {
                MacOSNativePaletteSurface()
            } else if design.hasMaterialSurface {
                Rectangle().fill(.thinMaterial)
            } else {
                design.canvasColor
            }
        }
        .ignoresSafeArea(.container, edges: design == .macOSNative ? .top : [])
        .onAppear { isSearchFocused = true }
        .onChange(of: state.searchFocusRequest) { request in
            // The view survives orderOut/makeKeyAndOrderFront; onAppear is
            // not guaranteed on each shortcut invocation. Remove any stale
            // focus binding, then restore it after the panel becomes key.
            isSearchFocused = false
            DispatchQueue.main.async {
                guard state.searchFocusRequest == request,
                      let panel = NSApp.keyWindow as? SearchPanel,
                      PaletteFocusPolicy.shouldRestoreSearchFocus(
                          isVisible: panel.isVisible,
                          isKeyWindow: panel.isKeyWindow,
                          isEditingSpace: state.editing,
                          isEditingPair: state.pairEditing)
                else { return }
                isSearchFocused = true
            }
        }
        .onChange(of: paletteRaw) { _ in
            // The text field is replaced when changing between legacy/refined
            // appearances; restore keyboard-first search immediately.
            isSearchFocused = true
            hoveredItemID = nil
        }
        .onChange(of: state.query) { _ in state.selectedID = state.allResultIDs.first }
        .onChange(of: state.orderingRevision) { _ in
            if !state.allResultIDs.contains(state.selectedID ?? "") {
                state.selectedID = state.allResultIDs.first
            }
        }
        .onChange(of: state.labelRevision) { _ in
            if !state.allResultIDs.contains(state.selectedID ?? "") {
                state.selectedID = state.allResultIDs.first
            }
        }
        .onChange(of: state.pairRevision) { _ in
            if !state.allResultIDs.contains(state.selectedID ?? "") {
                state.selectedID = state.allResultIDs.first
            }
        }
        .onMoveCommand { direction in
            if direction == .down { state.moveSelection(by: 1) }
            if direction == .up { state.moveSelection(by: -1) }
        }
        .onExitCommand { state.hidePanel?() }
        .sheet(isPresented: $state.editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text(t("名前と検索タグ", "Name and search tags")).font(.headline)
                TextField(t("表示名（例：趣味）", "Name (e.g. Personal)"), text: $state.nameDraft)
                    .focused($isNameInputFocused)
                    .modifier(NativeSheetFieldSurface(
                        enabled: design == .macOSNative, isFocused: isNameInputFocused))
                Text(t("検索タグ", "Search tags")).font(.subheadline.weight(.medium))
                TextField(state.editingTagIndex == nil
                          ? t("タグを入力してEnterで追加", "Enter a tag and press Return")
                          : t("編集してEnterで確定", "Edit tag and press Return"), text: $state.keywordInput)
                    .focused($isTagInputFocused)
                    .modifier(NativeSheetFieldSurface(
                        enabled: design == .macOSNative, isFocused: isTagInputFocused))
                    .onSubmit {
                        state.commitPendingKeyword()
                        isTagInputFocused = true
                    }
                if !state.tagsDraft.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(state.tagsDraft.indices, id: \.self) { index in
                                // Both edit and delete controls belong to the
                                // SAME pill. The X is intentionally inside its
                                // right edge, not a floating control between tags.
                                HStack(spacing: 5) {
                                    Button {
                                        state.beginTagEdit(at: index)
                                        isTagInputFocused = true
                                    } label: {
                                        Text("#" + state.tagsDraft[index])
                                            .lineLimit(1)
                                    }
                                    .help(t("クリックして編集", "Click to edit tag"))
                                    Button {
                                        state.removeTag(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .help(t("「\(state.tagsDraft[index])」を削除", "Remove \(state.tagsDraft[index])"))
                                    .accessibilityLabel(t("タグ「\(state.tagsDraft[index])」を削除", "Remove tag \(state.tagsDraft[index])"))
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .buttonStyle(.plain)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    Color.secondary.opacity(state.editingTagIndex == index ? 0.20 : 0.10),
                                    in: Capsule()
                                )
                            }
                        }
                    }
                }
                Text(t("タグをクリックして編集、×で削除", "Click a tag to edit; × to remove"))
                    .font(.caption).foregroundStyle(.secondary)
                if !state.editingApps.isEmpty {
                    Text(t("このSpaceで検出されたアプリ", "Apps detected in this Space"))
                        .font(.subheadline.weight(.medium))
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80, maximum: 100),
                                                    spacing: 8)],
                                  alignment: .leading, spacing: 10) {
                            ForEach(state.editingApps, id: \.name) { app in
                                let tagged = state.isDetectedAppTagged(app.name)
                                Button {
                                    state.toggleDetectedAppTag(app.name)
                                } label: {
                                    SpaceAppTile(app: app, isTagged: tagged)
                                }
                                .buttonStyle(.plain)
                                .disabled(DetectedAppTag.tagName(from: app.name) == nil)
                                .help(tagged
                                    ? t("クリックして「\(app.name)」を検索タグから削除",
                                        "Click to remove \(app.name) from search tags")
                                    : t("クリックして「\(app.name)」を検索タグに追加",
                                        "Click to add \(app.name) to search tags"))
                                .accessibilityLabel(tagged
                                    ? t("検索タグを削除: \(app.name)", "Remove search tag: \(app.name)")
                                    : t("検索タグに追加: \(app.name)", "Add search tag: \(app.name)"))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 190)
                    Text(t("アプリ名は検索にも使用されます。", "App names are included in search automatically."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if state.editingIsSessionOnly {
                    Text(t("このSpaceの名前は、ONIWAを終了するまで有効です。", "This Space's name is kept only until ONIWA quits."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(t("⌘S で保存 · Esc でキャンセル", "⌘S Save · Esc Cancel"))
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    if state.hasEditingLabel {
                        Button(t("名前とタグを削除", "Remove name and tags")) { state.deleteLabel() }
                            .foregroundStyle(.red)
                            .modifier(NativeSheetActionStyle(enabled: design == .macOSNative))
                    }
                    Spacer()
                    Button(t("キャンセル", "Cancel")) { state.cancelEdit() }
                        .keyboardShortcut(.cancelAction)
                        .modifier(NativeSheetActionStyle(enabled: design == .macOSNative))
                    // Return in the tag field must keep adding tags, not save
                    // the sheet. Command-S works from either text field.
                    Button(t("保存", "Save")) { state.saveLabel() }
                        .keyboardShortcut("s", modifiers: .command)
                        .help(t("⌘S で保存", "Save with ⌘S"))
                        .modifier(NativeSheetActionStyle(
                            enabled: design == .macOSNative, prominent: true))
                }
            }
            .padding(design == .macOSNative ? 24 : 20)
            .frame(width: design == .macOSNative ? 420 : 380)
            .background {
                if design == .macOSNative {
                    Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                }
            }
        }
        .sheet(isPresented: $state.pairEditing) {
            VStack(alignment: .leading, spacing: 14) {
                Text(state.editingPairID == nil ? t("セットを追加", "Add set") : t("セットを編集", "Edit set")).font(.headline)
                Text(t("2画面で一緒に切り替えるSpaceを選びます。", "Choose Spaces to switch together on two displays."))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(t("セット名（例：ONIWA開発）", "Set name (e.g. ONIWA Work)"), text: $state.pairNameDraft)
                    .focused($isPairNameInputFocused)
                    .modifier(NativeSheetFieldSurface(
                        enabled: design == .macOSNative, isFocused: isPairNameInputFocused))
                Picker(t("画面1", "Display 1"), selection: $state.pairFirstKey) {
                    ForEach(state.pairEligibleSpaces) { space in
                        Text("\(state.monitorName(space)) · \(state.spaceName(space)) · Space \(space.index + 1)")
                            .tag(space.identity.persistentKey ?? "")
                    }
                }
                .onChange(of: state.pairFirstKey) { _ in
                    state.firstPairSpaceChanged()
                }
                Picker(t("画面2", "Display 2"), selection: $state.pairSecondKey) {
                    ForEach(state.pairSecondChoices) { space in
                        Text("\(state.monitorName(space)) · \(state.spaceName(space)) · Space \(space.index + 1)")
                            .tag(space.identity.persistentKey ?? "")
                    }
                }
                if !state.pairCanSave {
                    Text(SpacePair.cleanedName(state.pairNameDraft).isEmpty
                         ? t("セット名を入力してください。", "Enter a set name.")
                         : t("別々のモニターからSpaceを選んでください。",
                             "Choose a Space from each display."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(t("⌘S で保存 · Esc でキャンセル", "⌘S Save · Esc Cancel"))
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    if state.editingPairID != nil {
                        Button(t("セットを削除", "Delete set"), role: .destructive) { state.deletePair() }
                            .modifier(NativeSheetActionStyle(enabled: design == .macOSNative))
                    }
                    Spacer()
                    Button(t("キャンセル", "Cancel")) { state.pairEditing = false }
                        .keyboardShortcut(.cancelAction)
                        .modifier(NativeSheetActionStyle(enabled: design == .macOSNative))
                    Button(t("保存", "Save")) { state.savePair() }
                        .keyboardShortcut("s", modifiers: .command)
                        .help(t("⌘S で保存", "Save with ⌘S"))
                        .disabled(!state.pairCanSave)
                        .modifier(NativeSheetActionStyle(
                            enabled: design == .macOSNative, prominent: true))
                }
            }
            .padding(design == .macOSNative ? 24 : 20)
            .frame(width: design == .macOSNative ? 500 : 460)
            .background {
                if design == .macOSNative {
                    Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                }
            }
        }
    }

 }

/// Native settings slider lives inside the menu so it can update a visible
/// search palette continuously, without adding another window or shortcut.
struct GlassTransparencyMenuControl: View {
    @AppStorage(GlassTransparencySettings.settingsKey)
    private var transparencyPercent = GlassTransparencySettings.defaultPercent
    @AppStorage(AppLanguage.settingsKey)
    private var languageRaw = AppLanguage.automaticValue

    private var language: AppLanguage { AppLanguage.effective(rawValue: languageRaw) }
    private func t(_ ja: String, _ en: String) -> String { language.text(ja, en) }

    private var value: Binding<Double> {
        Binding(
            get: { Double(GlassTransparencySettings.clamped(transparencyPercent)) },
            set: { transparencyPercent = GlassTransparencySettings.clamped(Int($0.rounded())) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(t("背景の透明度", "Background Transparency"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(GlassTransparencySettings.clamped(transparencyPercent))%")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...100, step: 1)
                .accessibilityLabel(t("背景の透明度", "Background Transparency"))
                .accessibilityValue("\(GlassTransparencySettings.clamped(transparencyPercent))%")
            HStack {
                Text(t("不透明", "Opaque"))
                Spacer()
                Text(t("透明", "Transparent"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 252)
    }
}

final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let state = SearchState()
    private var shortcut: GlobalShortcut?
    private var panel: SearchPanel?
    private var isAwaitingPaletteFocus = false
    private var statusItem: NSStatusItem?
    private let permissionSetup = PermissionSetupController()
    private var keyboardMonitor: Any?
    private var spaceEventObserver: SpaceWorkspaceEventObserver?
    private var spaceChangeObserverToken: NSObjectProtocol?
    private var screenParametersObserverToken: NSObjectProtocol?
    private var singleSwitchItems: [SingleSpaceSwitchMode: NSMenuItem] = [:]
    private var pairSwitchItems: [PairSpaceSwitchMode: NSMenuItem] = [:]
    private var singleSwitchRootItem: NSMenuItem?
    private var pairSwitchRootItem: NSMenuItem?
    private var globalInstantExperimentItem: NSMenuItem?
    private var globalMCOneSessionExperimentItem: NSMenuItem?
    private var desktopNumberExperimentItems: [DesktopNumberExperimentMode: NSMenuItem] = [:]
    private var arrowBurstExperimentItems: [ArrowBurstExperimentMode: NSMenuItem] = [:]
    private var mcReverseOrderItem: NSMenuItem?
    private var instantPacingItem: NSMenuItem?
    private var missionControlWaitRootItem: NSMenuItem?
    private var missionControlResetWaitItem: NSMenuItem?
    private var shortcutItems: [GlobalShortcut.Preset: NSMenuItem] = [:]
    private var paletteDesignItems: [PaletteDesign: NSMenuItem] = [:]
    private var languageItems: [AppLanguage: NSMenuItem] = [:]
    private var transparencyMenuRoot: NSMenuItem?

    private var language: AppLanguage { AppLanguage.selected() }
    private func t(_ ja: String, _ en: String) -> String { language.text(ja, en) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Adopt independent, exclusive single/pair selections once.
        SwitchModeSettings.migrateLegacySettingsIfNeeded()
        NSApp.setActivationPolicy(.accessory)
        spaceEventObserver = SpaceWorkspaceEventObserver()
        state.observeCurrentSpaces()
        spaceChangeObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Observe system-initiated Mission Control / keyboard switches too.
            // Do not infer recency from search opening alone.
            DispatchQueue.main.async { self?.state.observeCurrentSpaces() }
        }
        screenParametersObserverToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Refresh the list on hotplug/unplug and keep an open palette on
            // the preferred (or safe fallback) display.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rebuildStatusMenu()
                if self.panel?.isVisible == true {
                    self.positionPaletteOnPreferredDisplay()
                }
            }
        }
        installKeyboardNavigation()
        let shortcut = GlobalShortcut()
        shortcut.onPress = { [weak self] in self?.togglePanel() }
        self.shortcut = shortcut
        state.shortcutDescription = shortcut.current.title
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = ""
            button.image = MenuBarSymbol.makeImage()
            button.imagePosition = .imageOnly
            button.toolTip = "ONIWA"
        }
        statusItem = item
        rebuildStatusMenu()
        state.hidePanel = { [weak self] in self?.dismissPanel() }
        state.showPanel = { [weak self] in self?.presentPanel(resetSearch: false) }
        state.onPermissionFailure = { [weak self] in self?.permissionSetup.show() }
        state.onVerifiedSpaceSwitch = { [weak self] in self?.permissionSetup.recordSuccessfulSwitch() }
        // Always guide users with missing permissions. For copies launched
        // outside Applications, explain the recommended move once per path.
        DispatchQueue.main.async { [weak self] in
            if PermissionSetupController.shouldShowOnLaunch {
                self?.permissionSetup.show()
            }
        }
    }

    /// Rebuild only the status menu; do not re-register shortcuts or observers.
    /// This ensures live language changes also update all menu titles.
    private func rebuildStatusMenu() {
        guard let item = statusItem, let shortcut else { return }
        shortcutItems.removeAll()
        paletteDesignItems.removeAll()
        languageItems.removeAll()
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: t("Spaceを検索…", "Search Spaces…"), action: #selector(openPanel), keyEquivalent: ""))
        let permissionItem = NSMenuItem(
            title: t("権限と初期設定…", "Permissions and setup…"),
            action: #selector(openPermissionSetup),
            keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(NSMenuItem.separator())
        let shortcutRoot = NSMenuItem(title: t("ショートカット", "Shortcuts"), action: nil, keyEquivalent: "")
        let shortcutMenu = NSMenu(title: t("ショートカット", "Shortcuts"))
        for preset in GlobalShortcut.Preset.allCases {
            let option = NSMenuItem(title: preset == .optionSpace ? t("⌥ Space（おすすめ）", "⌥ Space (recommended)") : preset.title,
                                    action: #selector(changeShortcut(_:)),
                                    keyEquivalent: "")
            option.target = self
            option.representedObject = preset.rawValue
            option.state = preset.combination == shortcut.current ? .on : .off
            shortcutItems[preset] = option
            shortcutMenu.addItem(option)
        }
        shortcutMenu.addItem(NSMenuItem.separator())
        let recorderItem = NSMenuItem(title: t("ショートカットを記録…", "Record shortcut…"),
                                      action: #selector(recordShortcut),
                                      keyEquivalent: "")
        recorderItem.target = self
        shortcutMenu.addItem(recorderItem)
        shortcutRoot.submenu = shortcutMenu
        menu.addItem(shortcutRoot)

        // Selecting a screen pins the search palette there, regardless of
        // where the pointer was moved by the Space switcher.
        let displayRoot = NSMenuItem(
            title: t("検索パレットの表示先", "Search palette display"),
            action: nil, keyEquivalent: "")
        let displayMenu = NSMenu(title: t("検索パレットの表示先", "Search palette display"))
        let availableScreens = PaletteDisplayScreens.connected()
        let preference = PaletteDisplaySelection(
            storedValue: UserDefaults.standard.string(forKey: PaletteDisplaySelection.settingsKey))
        let builtInAvailable = availableScreens.contains(where: \.isBuiltIn)
        let builtinItem = NSMenuItem(
            title: builtInAvailable
                ? t("Mac本体のディスプレイ（標準）", "Built-in display (default)")
                : t("メインディスプレイ（標準）", "Primary display (default)"),
            action: #selector(selectPaletteDisplay(_:)), keyEquivalent: "")
        builtinItem.representedObject = PaletteDisplaySelection.builtInValue
        builtinItem.state = preference.preferredDisplayUUID == nil ? .on : .off
        builtinItem.target = self
        displayMenu.addItem(builtinItem)
        if availableScreens.contains(where: { !$0.isBuiltIn }) {
            displayMenu.addItem(NSMenuItem.separator())
        }
        for (index, display) in availableScreens.enumerated() where !display.isBuiltIn {
            let entry = NSMenuItem(
                title: "\(display.name) · \(index + 1)",
                action: #selector(selectPaletteDisplay(_:)), keyEquivalent: "")
            entry.representedObject = PaletteDisplaySelection(
                displayUUID: display.uuid).storedValue
            entry.state = preference.preferredDisplayUUID == display.uuid ? .on : .off
            entry.target = self
            displayMenu.addItem(entry)
        }
        if let preferred = preference.preferredDisplayUUID,
           !availableScreens.contains(where: { $0.uuid == preferred }) {
            displayMenu.addItem(NSMenuItem.separator())
            let unavailable = NSMenuItem(
                title: t("選択した画面は未接続（Mac側に一時表示）",
                         "Selected display disconnected (using Mac temporarily)"),
                action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            unavailable.state = .on
            displayMenu.addItem(unavailable)
        }
        displayRoot.submenu = displayMenu
        menu.addItem(displayRoot)
        // The standard 50ms Control+Arrow Space switcher is unchanged.
        // Omit its noninteractive status row from the everyday menu.

        let designRoot = NSMenuItem(
            title: t("検索パレットのデザイン", "Palette design"), action: nil, keyEquivalent: "")
        let designMenu = NSMenu(title: t("検索パレットのデザイン", "Palette design"))
        let activeDesign = PaletteDesign.active()
        for option in PaletteDesign.visiblePresets {
            let entry = NSMenuItem(
                title: option.title,
                action: #selector(selectPaletteDesign(_:)),
                keyEquivalent: "")
            entry.representedObject = option.rawValue
            entry.state = option == activeDesign ? .on : .off
            entry.toolTip = option.detail
            entry.target = self
            paletteDesignItems[option] = entry
            designMenu.addItem(entry)
        }
        designRoot.submenu = designMenu
        // With a single visible design there is nothing to choose. The
        // submenu returns automatically if additional presets are restored.
        if PaletteDesign.visiblePresets.count > 1 {
            menu.addItem(designRoot)
        }

        // This is a macOS Native-only appearance setting. The embedded
        // SwiftUI slider observes @AppStorage and updates the open panel live.
        let glassRoot = NSMenuItem(title: t("背景の透明度", "Background Transparency"),
                                   action: nil, keyEquivalent: "")
        let glassMenu = NSMenu(title: t("背景の透明度", "Background Transparency"))
        let sliderItem = NSMenuItem()
        let sliderView = NSHostingView(rootView: GlassTransparencyMenuControl())
        sliderView.frame = NSRect(x: 0, y: 0, width: 252, height: 88)
        sliderItem.view = sliderView
        glassMenu.addItem(sliderItem)
        glassMenu.addItem(NSMenuItem.separator())
        let resetGlass = NSMenuItem(
            title: t("標準の透明度に戻す（20%）", "Reset transparency (20%)"),
            action: #selector(resetGlassTransparency), keyEquivalent: "")
        resetGlass.target = self
        glassMenu.addItem(resetGlass)
        glassRoot.submenu = glassMenu
        glassRoot.isEnabled = activeDesign == .macOSNative
        glassRoot.toolTip = t("macOS Nativeのみで使用できます。",
                              "Available for macOS Native only.")
        transparencyMenuRoot = glassRoot
        menu.addItem(glassRoot)

        let languageRoot = NSMenuItem(title: t("言語", "Language"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu(title: t("言語", "Language"))
        let followingSystem = AppLanguage.isFollowingSystem()
        let automatic = NSMenuItem(
            title: t("自動（macOSの言語）", "Automatic (macOS language)"),
            action: #selector(followSystemLanguage), keyEquivalent: "")
        automatic.target = self
        automatic.state = followingSystem ? .on : .off
        languageMenu.addItem(automatic)
        languageMenu.addItem(NSMenuItem.separator())
        for option in AppLanguage.allCases {
            let entry = NSMenuItem(title: option.title,
                                   action: #selector(selectLanguage(_:)),
                                   keyEquivalent: "")
            entry.representedObject = option.rawValue
            entry.state = !followingSystem && option == language ? .on : .off
            entry.target = self
            languageItems[option] = entry
            languageMenu.addItem(entry)
        }
        languageRoot.submenu = languageMenu
        menu.addItem(languageRoot)

        #if ONIWA_LEGACY_SWITCHING_UI
        menu.addItem(NSMenuItem.separator())
        // Archived experiment UI: opt in at build time only.
        // The implementation paths and persisted experiment settings remain.
        // Both saved modes are suspended while it is ON, not overwritten.
        let globalInstant = NSMenuItem(
            title: "全画面：実験的な瞬時切り替え（優先）",
            action: #selector(toggleGlobalInstantExperiment), keyEquivalent: "")
        globalInstant.toolTip = "単独Spaceも2画面セットも、毎回gestureを試します。"
            + "安全に未移動を確認できた操作だけキーボードに切り替えます。"
            + "OFFで以前の切り替え方式に戻ります。"
        globalInstant.state = SwitchModeSettings.globalInstantExperimentEnabled ? .on : .off
        globalInstant.target = self
        globalInstantExperimentItem = globalInstant
        menu.addItem(globalInstant)

        let mcOneSession = NSMenuItem(
            title: "全画面：Mission Control 1回・2画面診断実験（優先）",
            action: #selector(toggleGlobalMCOneSessionExperiment), keyEquivalent: "")
        mcOneSession.toolTip = "2画面セットではMission Controlを1回だけ表示して2つのSpaceをAXPress。"
            + "安全に未移動と確認できた画面だけキーボードで補完します。"
            + "単独SpaceではMission Control直接方式を使用します。"
        mcOneSession.state =
            SwitchModeSettings.globalMCOneSessionExperimentEnabled ? .on : .off
        mcOneSession.target = self
        globalMCOneSessionExperimentItem = mcOneSession
        menu.addItem(mcOneSession)

        for (mode, title) in [
            (ArrowBurstExperimentMode.ms100,
             "全画面：⌃←/→ 高速連打 100ms（実験・優先）"),
            (.ms50,
             "全画面：⌃←/→ 高速連打 50ms（実験・優先）")
        ] {
            let entry = NSMenuItem(
                title: title,
                action: #selector(selectArrowBurstExperiment(_:)),
                keyEquivalent: "")
            entry.representedObject = mode.rawValue
            entry.state = SwitchModeSettings.arrowBurstExperimentMode == mode
                ? .on : .off
            entry.toolTip = "連続したSpaceへControl+矢印を100msまたは50ms間隔で送信します。"
                + "途中のSpaceを毎回待たず、最後にSpace IDと全画面の安定性を検証。"
                + "フルスクリーンSpaceも対象。異常時は追加のキーを送らず停止します。"
                + "セットでは1画面の到達確認後に2画面目へ移動します。"
            entry.target = self
            arrowBurstExperimentItems[mode] = entry
            menu.addItem(entry)
        }

        for (mode, title) in [
            (DesktopNumberExperimentMode.rapid,
             "全画面：番号指定ショートカット・2画面高速連続（実験）"),
            (.sequential,
             "全画面：番号指定ショートカット・2画面逐次確認（実験）")
        ] {
            let entry = NSMenuItem(
                title: title,
                action: #selector(selectDesktopNumberExperiment(_:)),
                keyEquivalent: "")
            entry.representedObject = mode.rawValue
            entry.state = SwitchModeSettings.desktopNumberExperimentMode == mode
                ? .on : .off
            entry.toolTip = "macOSの『デスクトップNへ移動』ショートカットを使用。"
                + "システム設定→キーボード→キーボードショートカット→Mission Controlで"
                + "Control+1〜9を有効化してください。フルスクリーンや未設定は"
                + "安全確認付きのキーボード矢印移動に切り替えます。"
                + (mode == .rapid
                    ? "2画面へ到達確認を待たず連続送信します（厳密な同時送信ではありません）。"
                    : "1画面目の移動と安定性を確認してから2画面目へ送信します。")
            entry.target = self
            desktopNumberExperimentItems[mode] = entry
            menu.addItem(entry)
        }
        menu.addItem(NSMenuItem.separator())

        // Radio-style groups: one active choice per group, persisted separately.
        let singleRoot = NSMenuItem(
            title: singleModeMenuTitle(SwitchModeSettings.single),
            action: nil, keyEquivalent: "")
        singleSwitchRootItem = singleRoot
        let singleMenu = NSMenu(title: "単独Spaceの切り替え")
        let singleOptions: [(SingleSpaceSwitchMode, String)] = [
            (.keyboard, "キーボード移動"),
            (.instant, "瞬時切り替え（試験的）"),
            (.missionControl, "Mission Control直接移動（試験的）")
        ]
        for (mode, title) in singleOptions {
            let option = NSMenuItem(title: title,
                                    action: #selector(selectSingleSwitchMode(_:)),
                                    keyEquivalent: "")
            option.representedObject = mode.rawValue
            option.state = SwitchModeSettings.single == mode ? .on : .off
            option.target = self
            singleSwitchItems[mode] = option
            singleMenu.addItem(option)
        }
        singleRoot.submenu = singleMenu
        singleRoot.isEnabled = !SwitchModeSettings.anyGlobalExperimentEnabled
        menu.addItem(singleRoot)

        let pairRoot = NSMenuItem(
            title: pairModeMenuTitle(SwitchModeSettings.pair),
            action: nil, keyEquivalent: "")
        pairSwitchRootItem = pairRoot
        let pairMenu = NSMenu(title: "2画面セットの切り替え")
        let pairOptions: [(PairSpaceSwitchMode, String)] = [
            (.keyboard, "ディスプレイ移動式（キーボード）"),
            (.hybrid, "混合式（内蔵MC＋拡張キーボード・試験的）"),
            (.missionControlTwice, "Mission Control 2回方式")
        ]
        for (mode, title) in pairOptions {
            let option = NSMenuItem(title: title,
                                    action: #selector(selectPairSwitchMode(_:)),
                                    keyEquivalent: "")
            option.representedObject = mode.rawValue
            option.state = SwitchModeSettings.pair == mode ? .on : .off
            option.target = self
            pairSwitchItems[mode] = option
            pairMenu.addItem(option)
        }
        pairRoot.submenu = pairMenu
        pairRoot.isEnabled = !SwitchModeSettings.anyGlobalExperimentEnabled
        menu.addItem(pairRoot)

        let detailRoot = NSMenuItem(title: "詳細設定", action: nil,
                                    keyEquivalent: "")
        let detailMenu = NSMenu(title: "詳細設定")
        let pacing = NSMenuItem(title: "瞬時切り替え・間隔テスト（450ms）",
                                action: #selector(toggleInstantPacingProbe),
                                keyEquivalent: "")
        pacing.toolTip = "通常の単独瞬時切り替えの診断用です。"
            + "全画面実験モードでは安全のため常に450msの確認を行います。"
        pacing.state = InstantSwitchSettings.pacingProbeEnabled ? .on : .off
        pacing.isEnabled = !SwitchModeSettings.anyGlobalExperimentEnabled
            && SwitchModeSettings.single == .instant
        pacing.target = self
        instantPacingItem = pacing
        detailMenu.addItem(pacing)

        let reverseOrder = NSMenuItem(
            title: "MC一回実験：2画面目のAXPressを先に送る（比較用）",
            action: #selector(toggleMCReversePressOrder), keyEquivalent: "")
        reverseOrder.toolTip = "診断実験で押す順番を入れ替えます。"
            + "OFF=セット1→セット2、ON=セット2→セット1。"
            + "結果を診断ログに記録します。"
        reverseOrder.state = SwitchModeSettings.mcReversePressOrder ? .on : .off
        reverseOrder.isEnabled = SwitchModeSettings.globalMCOneSessionExperimentEnabled
        reverseOrder.target = self
        mcReverseOrderItem = reverseOrder
        detailMenu.addItem(reverseOrder)

        let waitRoot = NSMenuItem(title: "Mission Control待機時間：300ms（推奨）",
                                  action: nil, keyEquivalent: "")
        waitRoot.toolTip = "サムネイル検出後の追加待機時間です。総表示時間とは異なります。"
        missionControlWaitRootItem = waitRoot
        let waitMenu = NSMenu(title: "Mission Control待機時間")
        let customWait = NSMenuItem(title: "待機時間を設定…",
                                    action: #selector(promptMissionControlCustomWait),
                                    keyEquivalent: "")
        customWait.target = self
        waitMenu.addItem(customWait)
        let resetWait = NSMenuItem(title: "300ms（推奨）にリセット",
                                   action: #selector(resetMissionControlWait),
                                   keyEquivalent: "")
        resetWait.target = self
        missionControlResetWaitItem = resetWait
        waitMenu.addItem(resetWait)
        waitRoot.submenu = waitMenu
        detailMenu.addItem(waitRoot)
        detailRoot.submenu = detailMenu
        menu.addItem(detailRoot)
        updateMissionControlWaitMenuState()
        #endif

        menu.addItem(NSMenuItem.separator())
        // Keep both support tools accessible without cluttering the usual menu.
        let diagnosticsRoot = NSMenuItem(
            title: t("診断", "Diagnostics"), action: nil, keyEquivalent: "")
        let diagnosticsMenu = NSMenu(title: t("診断", "Diagnostics"))
        let diagnosis = NSMenuItem(title: t("ショートカット診断…", "Shortcut diagnostics…"),
                                   action: #selector(showShortcutDiagnosis),
                                   keyEquivalent: "")
        diagnosis.target = self
        diagnosticsMenu.addItem(diagnosis)
        let switchLog = NSMenuItem(title: t("切り替え診断ログを開く…", "Open switching log…"),
                                   action: #selector(openSwitchLog),
                                   keyEquivalent: "")
        switchLog.target = self
        diagnosticsMenu.addItem(switchLog)
        diagnosticsRoot.submenu = diagnosticsMenu
        menu.addItem(diagnosticsRoot)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: t("ONIWAを終了", "Quit ONIWA"), action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        item.menu = menu
    }

    @objc private func resetGlassTransparency() {
        GlassTransparencySettings.persist(GlassTransparencySettings.defaultPercent)
    }

    @objc private func selectPaletteDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let selection = PaletteDisplaySelection(storedValue: raw)
        // A monitor may be disconnected between opening the menu and clicking.
        if let id = selection.preferredDisplayUUID,
           !PaletteDisplayScreens.connected().contains(where: { $0.uuid == id }) {
            return
        }
        UserDefaults.standard.set(selection.storedValue,
                                  forKey: PaletteDisplaySelection.settingsKey)
        if panel?.isVisible == true { positionPaletteOnPreferredDisplay() }
        // Rebuild only after the tracked menu closes.
        DispatchQueue.main.async { [weak self] in self?.rebuildStatusMenu() }
    }

    private func positionPaletteOnPreferredDisplay() {
        guard let panel else { return }
        let preference = PaletteDisplaySelection(
            storedValue: UserDefaults.standard.string(forKey: PaletteDisplaySelection.settingsKey))
        guard let screen = PaletteDisplayScreens.resolve(preference) else { return }
        // Center in the usable region, not the full screen behind the Dock or
        // menu bar. Clamp in case a display has an unusually small resolution.
        let available = screen.visibleFrame
        // On smaller displays (including Sidecar), fit within the usable
        // screen; the result list keeps scrolling rather than being clipped.
        let preferred = PaletteDesign.active().panelSize
        let fittedHeight = min(preferred.height, max(240, available.height - 24))
        panel.setContentSize(NSSize(width: preferred.width, height: fittedHeight))
        let width = panel.frame.width
        let height = panel.frame.height
        let x = max(available.minX, min(available.midX - width / 2, available.maxX - width))
        let y = max(available.minY, min(available.midY - height / 2, available.maxY - height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func followSystemLanguage() {
        AppLanguage.followSystem()
        // @AppStorage refreshes open SwiftUI views. Rebuild the menu after
        // closing the tracked menu, without touching shortcuts or observers.
        DispatchQueue.main.async { [weak self] in self?.rebuildStatusMenu() }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = AppLanguage(rawValue: raw) else { return }
        choice.persist()
        // @AppStorage refreshes SearchView and any open sheet immediately.
        // Rebuild after the old menu closes to avoid mutating the tracked NSMenu.
        DispatchQueue.main.async { [weak self] in self?.rebuildStatusMenu() }
    }

    private func singleModeSummary(_ mode: SingleSpaceSwitchMode) -> String {
        switch mode {
        case .keyboard: return "キーボード"
        case .instant: return "瞬時切り替え"
        case .missionControl: return "Mission Control直接"
        }
    }

    private func pairModeSummary(_ mode: PairSpaceSwitchMode) -> String {
        switch mode {
        case .keyboard: return "キーボード"
        case .hybrid: return "混合式"
        case .missionControlTwice: return "Mission Control 2回"
        }
    }

    private func singleModeMenuTitle(_ mode: SingleSpaceSwitchMode) -> String {
        let paused = SwitchModeSettings.anyGlobalExperimentEnabled ? "（休止中）" : ""
        return "単独Space：\(singleModeSummary(mode))\(paused)"
    }

    private func pairModeMenuTitle(_ mode: PairSpaceSwitchMode) -> String {
        let paused = SwitchModeSettings.anyGlobalExperimentEnabled ? "（休止中）" : ""
        return "2画面セット：\(pairModeSummary(mode))\(paused)"
    }

    private func refreshGlobalExperimentMenuState() {
        let instant = SwitchModeSettings.globalInstantExperimentEnabled
        let mc = SwitchModeSettings.globalMCOneSessionExperimentEnabled
        let numbered = SwitchModeSettings.desktopNumberExperimentMode
        let burst = SwitchModeSettings.arrowBurstExperimentMode
        for (mode, item) in arrowBurstExperimentItems {
            item.state = burst == mode ? .on : .off
        }
        for (mode, item) in desktopNumberExperimentItems {
            item.state = numbered == mode ? .on : .off
        }
        globalInstantExperimentItem?.state = instant ? .on : .off
        globalMCOneSessionExperimentItem?.state = mc ? .on : .off
        singleSwitchRootItem?.isEnabled = !SwitchModeSettings.anyGlobalExperimentEnabled
        pairSwitchRootItem?.isEnabled = !SwitchModeSettings.anyGlobalExperimentEnabled
        singleSwitchRootItem?.title = singleModeMenuTitle(SwitchModeSettings.single)
        pairSwitchRootItem?.title = pairModeMenuTitle(SwitchModeSettings.pair)
        instantPacingItem?.isEnabled =
            !SwitchModeSettings.anyGlobalExperimentEnabled
                && SwitchModeSettings.single == .instant
        mcReverseOrderItem?.isEnabled = mc
    }

    @objc private func toggleGlobalInstantExperiment() {
        SwitchModeSettings.globalInstantExperimentEnabled.toggle()
        refreshGlobalExperimentMenuState()
        SpaceSwitchDiagnostics.record(
            "global-instant setting enabled=\(SwitchModeSettings.globalInstantExperimentEnabled)"
            + " mc-one-enabled=\(SwitchModeSettings.globalMCOneSessionExperimentEnabled)")
    }

    @objc private func toggleGlobalMCOneSessionExperiment() {
        SwitchModeSettings.globalMCOneSessionExperimentEnabled.toggle()
        refreshGlobalExperimentMenuState()
        SpaceSwitchDiagnostics.record(
            "mc-pair-diagnostic setting enabled=\(SwitchModeSettings.globalMCOneSessionExperimentEnabled)"
            + " instant-enabled=\(SwitchModeSettings.globalInstantExperimentEnabled)"
            + " reverse=\(SwitchModeSettings.mcReversePressOrder)")
    }

    @objc private func selectDesktopNumberExperiment(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let selected = DesktopNumberExperimentMode(rawValue: raw),
              selected != .off else { return }
        SwitchModeSettings.desktopNumberExperimentMode =
            SwitchModeSettings.desktopNumberExperimentMode == selected ? .off : selected
        refreshGlobalExperimentMenuState()
        SpaceSwitchDiagnostics.record(
            "desktop-number setting mode=\(SwitchModeSettings.desktopNumberExperimentMode.rawValue)"
            + " mc-one=\(SwitchModeSettings.globalMCOneSessionExperimentEnabled)"
            + " instant=\(SwitchModeSettings.globalInstantExperimentEnabled)")
    }

    @objc private func selectArrowBurstExperiment(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let selected = ArrowBurstExperimentMode(rawValue: raw),
              selected != .off else { return }
        SwitchModeSettings.arrowBurstExperimentMode =
            SwitchModeSettings.arrowBurstExperimentMode == selected ? .off : selected
        refreshGlobalExperimentMenuState()
        SpaceSwitchDiagnostics.record(
            "arrow-burst setting mode=\(SwitchModeSettings.arrowBurstExperimentMode.rawValue)"
            + " intervalMs=\(SwitchModeSettings.arrowBurstExperimentMode.intervalMS)"
            + " numbered=\(SwitchModeSettings.desktopNumberExperimentMode.rawValue)"
            + " mc-one=\(SwitchModeSettings.globalMCOneSessionExperimentEnabled)"
            + " instant=\(SwitchModeSettings.globalInstantExperimentEnabled)")
    }

    @objc private func toggleMCReversePressOrder() {
        guard SwitchModeSettings.globalMCOneSessionExperimentEnabled else { return }
        SwitchModeSettings.mcReversePressOrder.toggle()
        mcReverseOrderItem?.state = SwitchModeSettings.mcReversePressOrder ? .on : .off
        SpaceSwitchDiagnostics.record(
            "mc-pair-diagnostic reverse-order=\(SwitchModeSettings.mcReversePressOrder)")
    }

    @objc private func selectSingleSwitchMode(_ sender: NSMenuItem) {
        guard !SwitchModeSettings.anyGlobalExperimentEnabled else { return }
        guard let raw = sender.representedObject as? String,
              let selected = SingleSpaceSwitchMode(rawValue: raw) else { return }
        SwitchModeSettings.single = selected
        for (mode, item) in singleSwitchItems {
            item.state = mode == selected ? .on : .off
        }
        instantPacingItem?.isEnabled = selected == .instant
        singleSwitchRootItem?.title = singleModeMenuTitle(selected)
        SpaceSwitchDiagnostics.record("single mode setting=\(selected.rawValue)")
    }

    @objc private func selectPairSwitchMode(_ sender: NSMenuItem) {
        guard !SwitchModeSettings.anyGlobalExperimentEnabled else { return }
        guard let raw = sender.representedObject as? String,
              let selected = PairSpaceSwitchMode(rawValue: raw) else { return }
        SwitchModeSettings.pair = selected
        for (mode, item) in pairSwitchItems {
            item.state = mode == selected ? .on : .off
        }
        pairSwitchRootItem?.title = pairModeMenuTitle(selected)
        SpaceSwitchDiagnostics.record("pair mode setting=\(selected.rawValue)")
    }

    @objc private func toggleInstantPacingProbe() {
        guard !SwitchModeSettings.anyGlobalExperimentEnabled
            && SwitchModeSettings.single == .instant else { return }
        InstantSwitchSettings.pacingProbeEnabled.toggle()
        instantPacingItem?.state =
            InstantSwitchSettings.pacingProbeEnabled ? .on : .off
    }

    @objc private func promptMissionControlCustomWait() {
        let alert = NSAlert()
        alert.messageText = t("Mission Controlの待機時間", "Mission Control wait time")
        alert.informativeText = t("100〜1000msで設定してください（推奨：300ms）。",
                                 "Enter 100–1000 ms (recommended: 300 ms).")
        alert.addButton(withTitle: t("設定", "Set"))
        alert.addButton(withTitle: t("キャンセル", "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = String(MissionControlDirectSettings.readinessWaitMilliseconds)
        field.placeholderString = t("例：275", "e.g. 275")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let milliseconds = Int(input),
              MissionControlDirectSettings.isValidReadinessWait(milliseconds) else {
            let warning = NSAlert()
            warning.alertStyle = .warning
            warning.messageText = t("待機時間を変更できませんでした", "Couldn't change wait time")
            warning.informativeText = t("100〜1000の整数を入力してください。設定は変更されていません。", "Enter a number from 100 to 1000. Nothing changed.")
            warning.runModal()
            return
        }

        MissionControlDirectSettings.readinessWaitMilliseconds = milliseconds
        updateMissionControlWaitMenuState()
    }

    @objc private func resetMissionControlWait() {
        MissionControlDirectSettings.readinessWaitMilliseconds =
            MissionControlDirectSettings.defaultReadinessWaitMilliseconds
        updateMissionControlWaitMenuState()
    }

    private func updateMissionControlWaitMenuState() {
        let chosen = MissionControlDirectSettings.readinessWaitMilliseconds
        let recommended = chosen == MissionControlDirectSettings.defaultReadinessWaitMilliseconds
        missionControlWaitRootItem?.title = recommended
            ? t("Mission Control待機時間：300ms（推奨）", "Mission Control wait: 300 ms (recommended)")
            : t("Mission Control待機時間：\(chosen)ms", "Mission Control wait: \(chosen) ms")
        missionControlResetWaitItem?.isEnabled = !recommended
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
        alert.messageText = t("ショートカットを記録", "Record shortcut")
        alert.informativeText = t(
            "使いたいキーを押してください（⌘・⌃・⌥のいずれかが必要）。",
            "Press your shortcut (include ⌘, ⌃ or ⌥)."
        )
        alert.alertStyle = .informational
        alert.accessoryView = recorder
        alert.addButton(withTitle: t("設定する", "Apply"))
        alert.addButton(withTitle: t("キャンセル", "Cancel"))
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
            warning.messageText = t("キーが記録されていません", "No shortcut recorded")
            warning.informativeText = t("記録欄をクリックしてキーの組み合わせを押してください。", "Click the recorder and press your shortcut.")
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
        alert.messageText = t("ショートカットの設定に失敗しました", "Couldn't set shortcut")
        alert.informativeText = shortcut?.registrationError ?? t("macOSまたは別のアプリと競合している可能性があります。", "macOS or another app may be using this shortcut.")
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func applyPaletteWindowStyle(_ choice: PaletteDesign) {
        guard let panel else { return }
        let glass = choice == .macOSNative
        // The transparent panel backing allows ultraThinMaterial to sample
        // the actual desktop rather than an opaque window background.
        panel.isOpaque = !glass
        panel.backgroundColor = glass ? .clear : .windowBackgroundColor
        panel.titlebarAppearsTransparent = glass
        panel.titleVisibility = glass ? .hidden : .visible
    }

    @objc private func selectPaletteDesign(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = PaletteDesign(rawValue: raw) else { return }
        choice.persist()
        for (design, item) in paletteDesignItems {
            item.state = design == choice ? .on : .off
        }
        // SearchView observes the same preference through @AppStorage, so
        // results, current selection, query and keyboard routing are retained.
        transparencyMenuRoot?.isEnabled = choice == .macOSNative
        applyPaletteWindowStyle(choice)
        panel?.setContentSize(NSSize(width: choice.panelSize.width,
                                     height: choice.panelSize.height))
        if panel?.isVisible == true { positionPaletteOnPreferredDisplay() }
    }

    @objc private func openSwitchLog() {
        let url = SpaceSwitchDiagnostics.logURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            let alert = NSAlert()
            alert.messageText = t("切り替え診断ログはまだありません", "No switching log yet")
            alert.informativeText = t("Spaceの切り替えを一度行うと、ローカルに記録されます。", "Switch a Space to create a local diagnostic log.")
            alert.runModal()
        }
    }

    @objc private func showShortcutDiagnosis() {
        let alert = NSAlert()
        alert.messageText = t("ONIWA ショートカット診断", "ONIWA shortcut diagnostics")
        let keyboardStatus = CGPreflightPostEventAccess()
            ? t("許可済み（Core Graphics）", "Granted (Core Graphics)") : t("未許可（アクセシビリティの設定を確認）", "Not granted (check Accessibility settings)")
        let hotkeyStatus = shortcut?.diagnosticSummary()
            ?? t("ショートカット管理が開始されていません。", "Shortcut manager isn't running.")
        alert.informativeText = hotkeyStatus + t("\n\nキー操作の送信権限: ", "\n\nKey posting permission: ") + keyboardStatus
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
              !state.editing, !state.pairEditing, !state.isSwitching else { return event }

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
            dismissPanel()
            return nil
        default:
            return event
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Refresh when the user returns from System Settings, as well as when
        // they explicitly click the Recheck button.
        permissionSetup.refreshIfVisible()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let spaceChangeObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserverToken)
            self.spaceChangeObserverToken = nil
        }
        if let screenParametersObserverToken {
            NotificationCenter.default.removeObserver(screenParametersObserverToken)
            self.screenParametersObserverToken = nil
        }
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }

    @objc private func openPermissionSetup() { permissionSetup.show() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openPanel() { presentPanel() }

    private func dismissPanel() {
        isAwaitingPaletteFocus = false
        panel?.orderOut(nil)
    }

    private func togglePanel() {
        if panel?.isVisible == true { dismissPanel() }
        else { presentPanel() }
    }

    /// Wait until AppKit has really made our panel key before requesting
    /// SwiftUI text-field focus. The pending flag prevents re-focusing the
    /// search field when an editor or another window later becomes active.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let panel, let window = notification.object as? NSWindow,
              window === panel else { return }
        restoreSearchFocusIfReady()
    }

    private func restoreSearchFocusIfReady() {
        guard isAwaitingPaletteFocus, let panel,
              PaletteFocusPolicy.shouldRestoreSearchFocus(
                  isVisible: panel.isVisible,
                  isKeyWindow: panel.isKeyWindow,
                  isEditingSpace: state.editing,
                  isEditingPair: state.pairEditing)
        else { return }
        isAwaitingPaletteFocus = false
        state.requestSearchFocus()
    }

    private func presentPanel(resetSearch: Bool = true) {
        if resetSearch {
            state.query = ""
            state.refresh()
        }
        if panel == nil {
            let preferred = PaletteDesign.active().panelSize
            let window = SearchPanel(contentRect: NSRect(
                x: 0, y: 0, width: preferred.width, height: preferred.height),
                                     styleMask: [.titled, .fullSizeContentView],
                                     backing: .buffered, defer: false)
            window.title = "ONIWA"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: SearchView(state: state))
            panel = window
            applyPaletteWindowStyle(PaletteDesign.active())
        }
        positionPaletteOnPreferredDisplay()
        isAwaitingPaletteFocus = !state.editing && !state.pairEditing
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        // Handles the already-key case; normal activation also calls
        // windowDidBecomeKey when the panel actually acquires key status.
        restoreSearchFocusIfReady()
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
