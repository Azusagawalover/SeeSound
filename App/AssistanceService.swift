import Foundation
import Combine

@MainActor
final class InformationCardService: ObservableObject {
    @Published private(set) var cards: [InformationCard] = []
    @Published private(set) var savedIDs: Set<UUID> = []
    @Published private(set) var error: String?
    private let store: InformationCardStore
    private var blocked = false
    init(store: InformationCardStore = InformationCardStore()) {
        self.store = store
        do { cards = try store.load(); savedIDs = Set(cards.map(\.id)) }
        catch { blocked = true; self.error = "信息卡读取失败，原文件已保留。可删除本地信息卡后重置：\(error.localizedDescription)" }
    }
    func put(_ draft: InformationCard, saveLocally: Bool) throws {
        var card = draft
        if let old = cards.first(where: { $0.id == draft.id }) {
            // Preserve review invalidation and source even for callers outside the editor.
            card = try old.replacing(with: draft)
        }
        try card.validate()
        guard cards.contains(where: { $0.id == card.id }) || cards.count < 30 else { throw DailyError.capacity }
        var next = cards.filter { $0.id != card.id }; next.insert(card, at: 0)
        var ids = savedIDs
        if saveLocally { ids.insert(card.id) } else { ids.remove(card.id) }
        if saveLocally || savedIDs.contains(card.id) {
            guard !blocked else { throw DailyError.invalid }
            try store.save(next.filter { ids.contains($0.id) }, consent: true)
        }
        cards = next; savedIDs = ids
    }
    func review(_ id: UUID, reviewed: Bool) throws {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { throw DailyError.stale }
        var next = cards; next[index].markReviewed(reviewed)
        if savedIDs.contains(id) {
            guard !blocked else { throw DailyError.invalid }
            try store.save(next.filter { savedIDs.contains($0.id) }, consent: true)
        }
        cards = next
    }
    func togglePin(_ id: UUID) throws {
        guard var card = cards.first(where: { $0.id == id }) else { throw DailyError.stale }
        card.pinned = !card.isPinned; try put(card, saveLocally: savedIDs.contains(id))
    }
    func remove(_ id: UUID) throws {
        let next = cards.filter { $0.id != id }
        if savedIDs.contains(id) { try store.save(next.filter { savedIDs.contains($0.id) }, consent: true) }
        cards = next; savedIDs.remove(id)
    }
    func reloadFromDisk() throws {
        let restored = try store.load();let ids = Set(restored.map(\.id))
        let unsaved = cards.filter { !savedIDs.contains($0.id) && !ids.contains($0.id) }
        guard restored.count+unsaved.count <= 30 else { throw DailyError.capacity }
        cards = restored+unsaved;savedIDs = ids;error = nil
        blocked = false
    }
    func reset() throws { try store.reset(); cards.removeAll(); savedIDs.removeAll(); error = nil; blocked = false }
    func discardUnsavedDemonstrations() { cards.removeAll { $0.origin == .demonstration && !savedIDs.contains($0.id) } }
}
