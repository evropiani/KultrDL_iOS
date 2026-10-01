import KultrDLCore
import SwiftUI

/**
 * "For you" at the top of Home: new releases from the user's artists,
 * mixes made for them, albums to try, albums missing from their
 * collection, and old favourites. Long-press anything to steer it.
 */
struct ForYouSection: View {
    @Environment(\.kultr) private var theme

    var body: some View {
        let graph = AppGraph.shared
        let recommender = graph.recommender
        let status = recommender.status
        let feed = recommender.feed
        let c = theme.colors
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("For you", icon: "sparkles") {
                if status.isWorking {
                    ProgressView().tint(c.accent).controlSize(.small).frame(minHeight: 44)
                } else {
                    Button { recommender.refreshInBackground() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(KFont.labelLarge)
                            .foregroundStyle(c.accent)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
            if let line = statusLine(status, feed) {
                Text(line)
                    .font(KFont.bodySmall)
                    .foregroundStyle(c.ink3)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
            if let feed, !feed.isEmpty {
                Shelves(feed: feed)
            } else if !status.isWorking {
                Intro(built: feed != nil)
            }
        }
        .onAppear { recommender.refreshIfStale() }
    }

    private func statusLine(_ status: Recommender.Status, _ feed: Feed?) -> String? {
        switch status {
        case .working(let step): return "\(step)…"
        case .failed(let message): return "Couldn't update: \(message)"
        case .idle:
            guard let feed else { return nil }
            return "Updated \(Format.ago(feed.builtAt))" + (feed.offline ? " · offline, from what's on hand" : "")
        }
    }
}

private struct Shelves: View {
    @Environment(\.kultr) private var theme
    let feed: Feed

    var body: some View {
        let actions = AppGraph.shared.actions
        if !feed.releases.isEmpty {
            SectionHeader("New releases", icon: "bell.badge")
            Shelf(items: feed.releases) { PickCard(pick: $0, showDate: true) }
        }
        if !feed.mixes.isEmpty {
            SectionHeader("Made for you", icon: "music.note.list")
            Shelf(items: feed.mixes, cardWidth: 160) { MixCard(mix: $0) }
        }
        if !feed.albums.isEmpty {
            SectionHeader("Albums for you", icon: "square.stack")
            Shelf(items: feed.albums) { PickCard(pick: $0) }
        }
        if !feed.missing.isEmpty {
            SectionHeader("Missing from your collection", icon: "rectangle.stack.badge.plus")
            Shelf(items: feed.missing) { PickCard(pick: $0) }
        }
        if !feed.rediscover.isEmpty {
            SectionHeader("Rediscover", icon: "clock.arrow.circlepath") {
                Button { actions.play(feed.rediscover) } label: {
                    Text("Play all")
                        .font(KFont.labelLarge)
                        .foregroundStyle(theme.colors.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
            }
            Shelf(items: feed.rediscover) { track in
                SuggestedTrackCard(track: track) {
                    actions.play(feed.rediscover, feed.rediscover.firstIndex { $0.id == track.id } ?? 0)
                }
            }
        }
        Text("Touch and hold a suggestion for “More like this”, “Not interested” or “Never this artist”.")
            .font(KFont.bodySmall)
            .foregroundStyle(theme.colors.ink3)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}

/** Nothing to suggest yet: say where suggestions come from, and how to give them more to go on. */
private struct Intro: View {
    @Environment(\.kultr) private var theme
    let built: Bool

    var body: some View {
        let graph = AppGraph.shared
        let c = theme.colors
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text(built ? "Nothing to suggest yet" : "Suggestions are on their way")
                    .font(KFont.titleMedium)
                    .foregroundStyle(c.ink)
                Text("They grow from what you play, heart, save and download here — and, if you like, from the music on this phone, your Navidrome, Last.fm or ListenBrainz. New releases from your artists show up here too.")
                    .font(KFont.bodyMedium)
                    .foregroundStyle(c.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Pill("Set up", icon: "gearshape", accent: true) { graph.actions.navigate(.recommendations) }
                    Pill("Refresh", icon: "arrow.clockwise") { graph.recommender.refreshInBackground() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
