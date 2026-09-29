import Foundation

/**
 * Picks the recording on YouTube Music (or YouTube) that is the catalogue
 * track the user chose: same title, same artist, about the same length,
 * and not a live take, remix or cover unless that is what was asked for.
 */
public enum Matcher {
    /** Versions that make a different recording of the same song. */
    private static let versionWords = [
        "live", "remix", "cover", "karaoke", "instrumental", "acoustic", "sped up", "slowed", "reverb",
        "nightcore", "8d", "extended", "demo", "mashup", "bass boosted", "a cappella", "acapella", "reprise",
        "piano version", "orchestral", "tribute", "lyrics video", "concert",
    ]

    public static let accept = 55.0

    public static func query(_ track: Track) -> String {
        let artist = Text.splitArtists(track.artist).first ?? track.artist
        return "\(artist) \(track.title)".trimmed()
    }

    public static func best(_ target: Track, _ candidates: [Track]) -> Track? {
        candidates.map { ($0, score(target, $0)) }
            .filter { $0.1 >= accept }
            .max { $0.1 < $1.1 }?
            .0
    }

    public static func score(_ target: Track, _ candidate: Track) -> Double {
        var score = 0.0
        let targetTitle = Text.coreTitle(target.title)
        let candidateTitle = Text.coreTitle(candidate.title)
        score += 45 * Text.similarity(targetTitle, candidateTitle)
        if !targetTitle.isEmpty && candidateTitle.contains(targetTitle) { score += 5 }

        // Artist: any of the credited artists on either side.
        let targetArtists = Text.splitArtists(target.artist).map(Text.normalize).filter { !$0.isEmpty }
        let candidateArtistText = Text.normalize(candidate.artist)
        let candidateTitleText = Text.normalize(candidate.title)
        let artistHit = targetArtists.contains { a in
            candidateArtistText.contains(a) || (a.contains(candidateArtistText) && !candidateArtistText.isEmpty)
        }
        if artistHit {
            score += 30
        } else if targetArtists.contains(where: { candidateTitleText.contains($0) }) {
            score += 20
        } else {
            score += 30 * (targetArtists.map { Text.similarity($0, candidateArtistText) }.max() ?? 0) - 5
        }

        if let a = target.durationMs, let b = candidate.durationMs, a > 0, b > 0 {
            let diff = abs(a - b) / 1000
            switch diff {
            case ...2: score += 20
            case ...5: score += 14
            case ...10: score += 6
            case ...20: break
            case ...60: score -= 15
            default: score -= 40
            }
        }

        let targetText = " " + Text.normalize("\(target.title) \(target.album ?? "")") + " "
        let candidateText = " " + Text.normalize(candidate.title) + " "
        for word in versionWords {
            let w = " \(Text.normalize(word)) "
            let inTarget = targetText.contains(w)
            let inCandidate = candidateText.contains(w)
            if inCandidate && !inTarget { score -= 30 }
            if inTarget && !inCandidate { score -= 10 }
        }
        if candidate.source == .youtubeMusic { score += 4 }
        return score
    }
}
