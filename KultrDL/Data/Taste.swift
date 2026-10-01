import Foundation
import KultrDLCore
import Observation

struct BlockedArtist: Codable, Hashable {
    var name: String
    var at: Int64 = nowMs()

    init(name: String, at: Int64 = nowMs()) {
        self.name = name
        self.at = at
    }

    enum CodingKeys: String, CodingKey { case name, at }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        at = c.value(.at, nowMs())
    }
}

enum Verdict: String, Codable, Hashable {
    case like = "LIKE", dismiss = "DISMISS"
}

/** "More like this" or "Not interested" on a suggestion. */
struct FeedbackEntry: Codable, Hashable {
    var key: String
    var verdict: Verdict
    var artist: String
    var label: String
    var at: Int64 = nowMs()

    init(key: String, verdict: Verdict, artist: String, label: String) {
        self.key = key
        self.verdict = verdict
        self.artist = artist
        self.label = label
    }

    enum CodingKeys: String, CodingKey { case key, verdict, artist, label, at }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        verdict = try c.decode(Verdict.self, forKey: .verdict)
        artist = c.value(.artist, "")
        label = c.value(.label, "")
        at = c.value(.at, nowMs())
    }
}

/** What the user told KultrDL about their taste; the same JSON as KultrDL for Android's backups. */
struct TasteData: Codable, Hashable {
    var blocked: [BlockedArtist] = []
    var feedback: [FeedbackEntry] = []

    init() {}

    enum CodingKeys: String, CodingKey { case blocked, feedback }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocked = c.value(.blocked, [])
        feedback = c.value(.feedback, [])
    }
}

/**
 * Artists the user never wants to hear, and their answers to suggestions.
 * Kept on the phone, part of backups.
 */
@MainActor
@Observable
final class TasteStore {
    private static let file = "taste.json"
    private static let maxFeedback = 3000

    private(set) var data: TasteData
    /** Blocked artists, ready to filter tracks with. */
    private(set) var blocks: ArtistBlocks
    /** The same blocks for code off the main thread. */
    @ObservationIgnored nonisolated let shared: Shared<ArtistBlocks>

    init() {
        let loaded = Storage.load(TasteData.self, Self.file) ?? TasteData()
        data = loaded
        let blocks = ArtistBlocks(loaded.blocked.map(\.name))
        self.blocks = blocks
        shared = Shared(blocks)
    }

    private func write(_ change: (inout TasteData) -> Void) {
        var next = data
        change(&next)
        guard next != data else { return }
        data = next
        blocks = ArtistBlocks(next.blocked.map(\.name))
        shared.value = blocks
        Storage.save(next, Self.file)
    }

    func isBlocked(_ name: String) -> Bool {
        let key = Credits.key(name)
        return data.blocked.contains { Credits.key($0.name) == key }
    }

    func block(_ names: [String]) {
        write { d in
            var known = Set(d.blocked.map { Credits.key($0.name) })
            for name in names {
                let key = Credits.key(name)
                guard !key.isEmpty, known.insert(key).inserted else { continue }
                d.blocked.append(BlockedArtist(name: name.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    func unblock(_ name: String) {
        let key = Credits.key(name)
        write { d in d.blocked.removeAll { Credits.key($0.name) == key } }
    }

    func like(_ key: String, artist: String, label: String) {
        answer(FeedbackEntry(key: key, verdict: .like, artist: artist, label: label))
    }

    func dismiss(_ key: String, artist: String, label: String) {
        answer(FeedbackEntry(key: key, verdict: .dismiss, artist: artist, label: label))
    }

    private func answer(_ entry: FeedbackEntry) {
        // The newest answer per item, and no more than a few thousand in all.
        write { d in
            d.feedback.removeAll { $0.key == entry.key }
            d.feedback.append(entry)
            if d.feedback.count > Self.maxFeedback { d.feedback.removeFirst(d.feedback.count - Self.maxFeedback) }
        }
    }

    func forget(_ key: String) {
        write { d in d.feedback.removeAll { $0.key == key } }
    }

    var dismissedKeys: Set<String> { Set(data.feedback.filter { $0.verdict == .dismiss }.map(\.key)) }

    func verdict(_ key: String) -> Verdict? { data.feedback.last { $0.key == key }?.verdict }

    /** From a backup: added to what is here. */
    func restore(_ from: TasteData) {
        block(from.blocked.map(\.name))
        write { d in
            let known = Set(d.feedback.map(\.key))
            d.feedback += from.feedback.filter { !known.contains($0.key) }
            if d.feedback.count > Self.maxFeedback { d.feedback.removeFirst(d.feedback.count - Self.maxFeedback) }
        }
    }
}
