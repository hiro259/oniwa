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
    @Published var editingAppNames: [String] = []
    @Published var hasEditingLabel = false
    @Published var editingIsSessionOnly = false
    @Published var labelRevision = 0
    @Published var errorMessage: String?
    @Published var isSwitching = false
    @Published var shortcutDescription = "⌥ Space"
    @Published var pairRevision = 0
    @Published var orderingRevision = 0
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
        return "モニター\(number)（\(space.displayName)）"
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
        all.filter { $0.identity.persistentKey != nil }
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
            errorMessage = "セットには別々の2つのモニターと、UUIDのあるSpaceが必要です。"
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
            errorMessage = "セットを保存できません。対象のSpaceとモニターを確認してください。"
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
        guard resolvedSpaces(for: pair) != nil else {
            errorMessage = "セットのSpaceが見つかりません。鉛筆ボタンから再設定してください。"
            return
        }
        isSwitching = true
        hidePanel?()
        switcher.switchToPair(pair) { [weak self] outcome in
            guard let self else { return }
            self.isSwitching = false
            switch outcome {
            case .success:
                self.listOrder.markUsed(self.pairResultID(pair))
                self.orderingRevision += 1
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                self.showError()
            }
        }
    }

    func refresh() {
        groups = SpaceReader.shared.displays()
        observeCurrentSpaces(groups)
        if !groups.isEmpty { labels.reconcile(groups.flatMap(\.spaces).map(\.identity)) }
        errorMessage = SpaceReader.shared.available
            ? (groups.isEmpty ? "No Spaces found. This macOS version may be unsupported." : nil)
            : "Could not load SkyLight. This macOS version may be unsupported."
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
            errorMessage = "選択したSpaceが検索結果から消えました。候補を選び直してください。"
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
        editingAppNames = space.appNames
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
            errorMessage = "編集中のSpaceが見つかりません。検索一覧を更新してください。"
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
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                self.showError()
            }
        }
    }

    var showPanel: (() -> Void)?
    func showError() { showPanel?() }
}

/// Search keywords and transient app names deliberately use different chips.
private struct SpaceTag: View {
    let title: String
    let isAutomatic: Bool

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
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(isAutomatic ? 0.06 : 0.11), in: Capsule())
        .help(isAutomatic ? "このSpace内のアプリから自動取得（保存されません）" : "登録した検索タグ")
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
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isTagInputFocused: Bool
    @State private var draggingOrderKey: String?


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ONIWA").font(.headline)
                Spacer()
                Text(state.shortcutDescription).foregroundStyle(.secondary).font(.caption)
            }
            TextField("Space・セット・タグを検索…", text: $state.query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onSubmit { state.activateSelected() }
            HStack(spacing: 6) {
                Text("並び替え")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("並び替え", selection: Binding(
                    get: { state.sortMode },
                    set: { state.changeSortMode($0) }
                )) {
                    Text("最近使った順").tag(SpaceListSortMode.recent)
                    Text("元の並び").tag(SpaceListSortMode.original)
                    Text("名前順").tag(SpaceListSortMode.name)
                    Text("自由に並べる").tag(SpaceListSortMode.custom)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170)
                Spacer()
                if state.canReorderByDrag {
                    Text("≡ をドラッグすると順番が入れ替わります")
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
                    LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(state.orderedItems) { item in
                        switch item {
                        case .pair(let pair):
                        let destination = state.resolvedSpaces(for: pair)
                        let isCurrent = destination.map { $0.0.isCurrent && $0.1.isCurrent } ?? false
                        HStack(spacing: 9) {
                            Image(systemName: "square.on.square")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(pair.name)
                                        .fontWeight(state.pairResultID(pair) == state.selectedID
                                            || isCurrent ? .semibold : .regular)
                                        .lineLimit(1)
                                    Text("セット")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.10), in: Capsule())
                                    if isCurrent {
                                        Label("current", systemImage: "checkmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let (first, second) = destination {
                                    Text("\(state.monitorName(first)): \(state.spaceName(first))  +  \(state.monitorName(second)): \(state.spaceName(second))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Label("Spaceが見つかりません · セットを再設定してください",
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
                                    .help("ドラッグして表示順を変更")
                                    .onDrag {
                                        draggingOrderKey = "pair:\(pair.id.uuidString)"
                                        return NSItemProvider(
                                            object: "pair:\(pair.id.uuidString)" as NSString)
                                    }
                            }
                            Button {
                                state.togglePin(pair)
                            } label: {
                                Image(systemName: state.isPinned(pair) ? "pin.fill" : "pin")
                                    .foregroundStyle(state.isPinned(pair)
                                        ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(state.isPinned(pair) ? "ピン留めを解除" : "一覧の先頭にピン留め")
                            .accessibilityLabel(state.isPinned(pair)
                                ? "セットのピン留めを解除" : "セットをピン留め")
                            Button {
                                state.beginPairEdit(pair)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("セットを編集または削除")
                        }
                        .padding(8)
                        .background(state.pairResultID(pair) == state.selectedID
                            ? Color.accentColor.opacity(0.16)
                            : (isCurrent ? Color.secondary.opacity(0.04) : Color.clear))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(isCurrent ? Color.secondary.opacity(0.38) : Color.clear,
                                              lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if state.selectedID == state.pairResultID(pair) {
                                state.activatePair(pair)
                            } else {
                                state.selectedID = state.pairResultID(pair)
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
                        HStack(spacing: 9) {
                            Image(systemName: space.kind == 4 ? "arrow.up.left.and.arrow.down.right" : "display")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(state.labels.label(for: space.identity)?.name.isEmpty == false
                                         ? (state.labels.label(for: space.identity)?.name ?? space.defaultName)
                                         : space.defaultName)
                                        .fontWeight(space.id == state.selectedID || space.isCurrent
                                            ? .semibold : .regular)
                                        .lineLimit(1)
                                    if space.isCurrent {
                                        Label("current", systemImage: "checkmark.circle.fill")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(Color.secondary.opacity(0.09), in: Capsule())
                                            .fixedSize()
                                            .help("このモニターで現在表示されているSpace")
                                    }
                                }
                                Text("\(space.displayName) · Space \(space.index + 1)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                                // Saved search keywords and current apps appear
                                // as tags, but only the manual tags are persisted.
                                let manualTags = state.labels.label(for: space.identity)?.searchTags ?? []
                                let appTags = FuzzySearch.appTags(from: space.appNames,
                                                                 excluding: manualTags)
                                if !manualTags.isEmpty || !appTags.isEmpty {
                                    HStack(spacing: 4) {
                                        ForEach(Array(manualTags.prefix(2)), id: \.self) { tag in
                                            SpaceTag(title: tag, isAutomatic: false)
                                        }
                                        ForEach(Array(appTags.prefix(2)), id: \.self) { app in
                                            SpaceTag(title: app, isAutomatic: true)
                                        }
                                        let extra = max(0, manualTags.count - 2)
                                            + max(0, appTags.count - 2)
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
                                    .help("ドラッグして表示順を変更")
                                    .onDrag {
                                        draggingOrderKey = key
                                        return NSItemProvider(object: key as NSString)
                                    }
                            }
                            Button {
                                state.togglePin(space)
                            } label: {
                                Image(systemName: state.isPinned(space) ? "pin.fill" : "pin")
                                    .foregroundStyle(state.isPinned(space)
                                        ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.borderless)
                            .disabled(space.identity.persistentKey == nil)
                            .help(space.identity.persistentKey == nil
                                ? "UUIDのないSpaceは再起動後のピン留めを保存できません"
                                : (state.isPinned(space) ? "ピン留めを解除" : "一覧の先頭にピン留め"))
                            .accessibilityLabel(state.isPinned(space)
                                ? "Spaceのピン留めを解除" : "Spaceをピン留め")
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
                        // A subtle neutral border and "current" badge indicate the
                        // visible Space, even when another result is selected.
                        .background(space.id == state.selectedID
                            ? Color.accentColor.opacity(0.16)
                            : (space.isCurrent ? Color.secondary.opacity(0.04) : Color.clear))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(space.isCurrent ? Color.secondary.opacity(0.38) : Color.clear,
                                              lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if state.selectedID == space.id { state.activate(space) }
                            else { state.selectedID = space.id }
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
                Text("↑↓ 選択   ↵ 切り替え   Esc 閉じる")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    state.newPair()
                } label: {
                    Label("セットを追加", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Button("Refresh") { state.refresh() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(width: 500, height: 420)
        .onAppear { isSearchFocused = true }
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
                Text("Spaceの名前と検索タグ").font(.headline)
                TextField("表示名（例：趣味）", text: $state.nameDraft)
                Text("検索タグ").font(.subheadline.weight(.medium))
                TextField(state.editingTagIndex == nil
                          ? "タグを入力してEnterで追加（スペースも使用可）"
                          : "タグを編集してEnterで確定", text: $state.keywordInput)
                    .focused($isTagInputFocused)
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
                                    .help("クリックしてタグを編集")
                                    Button {
                                        state.removeTag(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .help("「\(state.tagsDraft[index])」を削除")
                                    .accessibilityLabel("タグ「\(state.tagsDraft[index])」を削除")
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
                Text("Enterで追加・確定。タグをクリックすると再編集、×で削除できます。")
                    .font(.caption).foregroundStyle(.secondary)
                if !state.editingAppNames.isEmpty {
                    Text("開いているアプリ（自動タグ）")
                        .font(.subheadline.weight(.medium))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(FuzzySearch.appTags(from: state.editingAppNames,
                                                        excluding: state.tagsDraft), id: \.self) { app in
                                SpaceTag(title: app, isAutomatic: true)
                            }
                        }
                    }
                    Text("アプリのタグは保存せず、検索パネルを開くたびに更新します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if state.editingIsSessionOnly {
                    Text("このSpaceには識別用UUIDがありません。誤ったSpaceへの名前引き継ぎを防ぐため、名前はONIWAを終了するまで有効です。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if state.hasEditingLabel {
                        Button("名前とタグを削除") { state.deleteLabel() }
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button("キャンセル") { state.cancelEdit() }
                    Button("保存") { state.saveLabel() }
                }
            }
            .padding(20)
            .frame(width: 380)
        }
        .sheet(isPresented: $state.pairEditing) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Spaceセット").font(.headline)
                Text("2つのモニターで同時に使うSpaceを登録します。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("セット名（例：ONIWA開発）", text: $state.pairNameDraft)
                Picker("1つ目のモニター", selection: $state.pairFirstKey) {
                    ForEach(state.pairEligibleSpaces) { space in
                        Text("\(state.monitorName(space)) · \(state.spaceName(space)) · Space \(space.index + 1)")
                            .tag(space.identity.persistentKey ?? "")
                    }
                }
                .onChange(of: state.pairFirstKey) { _ in
                    state.firstPairSpaceChanged()
                }
                Picker("2つ目のモニター", selection: $state.pairSecondKey) {
                    ForEach(state.pairSecondChoices) { space in
                        Text("\(state.monitorName(space)) · \(state.spaceName(space)) · Space \(space.index + 1)")
                            .tag(space.identity.persistentKey ?? "")
                    }
                }
                if !state.pairCanSave {
                    Text("別々のモニターにある、識別可能な2つのSpaceを選んでください。削除されたSpaceやUUIDのないSpaceは登録できません。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if state.editingPairID != nil {
                        Button("セットを削除", role: .destructive) { state.deletePair() }
                    }
                    Spacer()
                    Button("キャンセル") { state.pairEditing = false }
                    Button("保存") { state.savePair() }
                        .disabled(!state.pairCanSave)
                }
            }
            .padding(20)
            .frame(width: 460)
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
    private var spaceEventObserver: SpaceWorkspaceEventObserver?
    private var spaceChangeObserverToken: NSObjectProtocol?
    private var singleSwitchItems: [SingleSpaceSwitchMode: NSMenuItem] = [:]
    private var pairSwitchItems: [PairSpaceSwitchMode: NSMenuItem] = [:]
    private var singleSwitchRootItem: NSMenuItem?
    private var pairSwitchRootItem: NSMenuItem?
    private var instantPacingItem: NSMenuItem?
    private var missionControlWaitRootItem: NSMenuItem?
    private var missionControlResetWaitItem: NSMenuItem?
    private var shortcutItems: [GlobalShortcut.Preset: NSMenuItem] = [:]

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
        // Radio-style groups: one active choice per group, persisted separately.
        let singleRoot = NSMenuItem(
            title: "単独Space：\(singleModeSummary(SwitchModeSettings.single))",
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
        menu.addItem(singleRoot)

        let pairRoot = NSMenuItem(
            title: "2画面セット：\(pairModeSummary(SwitchModeSettings.pair))",
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
        menu.addItem(pairRoot)

        let detailRoot = NSMenuItem(title: "詳細設定", action: nil,
                                    keyEquivalent: "")
        let detailMenu = NSMenu(title: "詳細設定")
        let pacing = NSMenuItem(title: "瞬時切り替え・間隔テスト（450ms）",
                                action: #selector(toggleInstantPacingProbe),
                                keyEquivalent: "")
        pacing.toolTip = "単独Spaceの瞬時切り替え専用。高速ジェスチャー後の450ms安定確認です。"
        pacing.state = InstantSwitchSettings.pacingProbeEnabled ? .on : .off
        pacing.isEnabled = SwitchModeSettings.single == .instant
        pacing.target = self
        instantPacingItem = pacing
        detailMenu.addItem(pacing)

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
        let diagnosis = NSMenuItem(title: "ショートカット診断…",
                                   action: #selector(showShortcutDiagnosis),
                                   keyEquivalent: "")
        diagnosis.target = self
        menu.addItem(diagnosis)
        let switchLog = NSMenuItem(title: "切り替え診断ログを開く…",
                                   action: #selector(openSwitchLog),
                                   keyEquivalent: "")
        switchLog.target = self
        menu.addItem(switchLog)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ONIWA", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        item.menu = menu
        statusItem = item
        state.hidePanel = { [weak self] in self?.panel?.orderOut(nil) }
        state.showPanel = { [weak self] in self?.presentPanel(resetSearch: false) }
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

    @objc private func selectSingleSwitchMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let selected = SingleSpaceSwitchMode(rawValue: raw) else { return }
        SwitchModeSettings.single = selected
        for (mode, item) in singleSwitchItems {
            item.state = mode == selected ? .on : .off
        }
        instantPacingItem?.isEnabled = selected == .instant
        singleSwitchRootItem?.title = "単独Space：\(singleModeSummary(selected))"
        SpaceSwitchDiagnostics.record("single mode setting=\(selected.rawValue)")
    }

    @objc private func selectPairSwitchMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let selected = PairSpaceSwitchMode(rawValue: raw) else { return }
        SwitchModeSettings.pair = selected
        for (mode, item) in pairSwitchItems {
            item.state = mode == selected ? .on : .off
        }
        pairSwitchRootItem?.title = "2画面セット：\(pairModeSummary(selected))"
        SpaceSwitchDiagnostics.record("pair mode setting=\(selected.rawValue)")
    }

    @objc private func toggleInstantPacingProbe() {
        guard SwitchModeSettings.single == .instant else { return }
        InstantSwitchSettings.pacingProbeEnabled.toggle()
        instantPacingItem?.state =
            InstantSwitchSettings.pacingProbeEnabled ? .on : .off
    }

    @objc private func promptMissionControlCustomWait() {
        let alert = NSAlert()
        alert.messageText = "Mission Controlの待機時間"
        alert.informativeText = "100〜1000msの整数で入力してください。"
            + "300msが推奨値です。300ms未満では切り替えに失敗する可能性があります。"
        alert.addButton(withTitle: "設定")
        alert.addButton(withTitle: "キャンセル")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = String(MissionControlDirectSettings.readinessWaitMilliseconds)
        field.placeholderString = "例：275"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let milliseconds = Int(input),
              MissionControlDirectSettings.isValidReadinessWait(milliseconds) else {
            let warning = NSAlert()
            warning.alertStyle = .warning
            warning.messageText = "待機時間を変更できませんでした"
            warning.informativeText = "100〜1000の整数を入力してください。設定は変更されていません。"
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
            ? "Mission Control待機時間：300ms（推奨）"
            : "Mission Control待機時間：\(chosen)ms"
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

    @objc private func openSwitchLog() {
        let url = SpaceSwitchDiagnostics.logURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            let alert = NSAlert()
            alert.messageText = "切り替え診断ログはまだありません"
            alert.informativeText = "Spaceの切り替えを一度行うと、ローカルに記録されます。"
            alert.runModal()
        }
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
            panel?.orderOut(nil)
            return nil
        default:
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let spaceChangeObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserverToken)
            self.spaceChangeObserverToken = nil
        }
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
