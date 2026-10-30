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
    @Published var pairEditing = false
    @Published var pairNameDraft = ""
    @Published var pairFirstKey = ""
    @Published var pairSecondKey = ""
    @Published var editingPairID: UUID?
    let labels = SpaceLabelStore()
    let pairStore = SpacePairStore()
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

    var allResultIDs: [String] {
        pairResults.map { pairResultID($0) } + results.map(\.id)
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
            pairRevision += 1
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
            if case .failure(let error) = outcome {
                self.errorMessage = error.localizedDescription
                self.showError()
            }
        }
    }

    func refresh() {
        groups = SpaceReader.shared.displays()
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
            if case .failure(let error) = outcome {
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

struct SearchView: View {
    @ObservedObject var state: SearchState
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isTagInputFocused: Bool

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
            if let error = state.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(state.pairResults) { pair in
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
                    }
                    ForEach(state.results) { space in
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
    private var instantSwitchItem: NSMenuItem?
    private var instantPacingItem: NSMenuItem?
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
        let pacing = NSMenuItem(title: "瞬時切り替え・間隔テスト（450ms）",
                                action: #selector(toggleInstantPacingProbe),
                                keyEquivalent: "")
        pacing.toolTip = "高速ジェスチャー間に450msの確認待ちを挿入します。切り替え不具合の切り分け専用です。"
        pacing.state = InstantSwitchSettings.pacingProbeEnabled ? .on : .off
        pacing.target = self
        instantPacingItem = pacing
        menu.addItem(pacing)
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

    @objc private func toggleInstantSwitch() {
        InstantSwitchSettings.enabled.toggle()
        instantSwitchItem?.state = InstantSwitchSettings.enabled ? .on : .off
    }

    @objc private func toggleInstantPacingProbe() {
        InstantSwitchSettings.pacingProbeEnabled.toggle()
        instantPacingItem?.state = InstantSwitchSettings.pacingProbeEnabled ? .on : .off
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
