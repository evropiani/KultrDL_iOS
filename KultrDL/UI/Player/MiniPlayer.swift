import AVKit
import SwiftUI

/** The playback position, polled while on screen. */
struct PositionReader<Content: View>: View {
    var interval: Double = 0.2
    @ViewBuilder let content: (Int64) -> Content
    @State private var position: Int64 = 0

    var body: some View {
        content(position)
            .task {
                while !Task.isCancelled {
                    position = AppGraph.shared.player.positionMs()
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            }
    }
}

/** "Play on another device": AirPlay speakers, Apple TVs and HomePods. */
struct CastButton: View {
    @Environment(\.kultr) private var theme
    var tint: Color?

    var body: some View {
        RoutePicker(tint: UIColor(tint ?? theme.colors.ink2), active: UIColor(theme.colors.accent))
            .frame(width: 44, height: 44)
            .accessibilityLabel("Play on another device")
    }
}

private struct RoutePicker: UIViewRepresentable {
    let tint: UIColor
    let active: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = active
    }
}

/**
 * What is playing, on the tab bar: artwork, title and artist, play/pause and
 * next. Tap it for the full player; swipe it left for the next track and
 * right for the previous one. [compact] is the slim version shown beside a
 * shrunken tab bar.
 */
struct MiniPlayerContent: View {
    @Environment(\.kultr) private var theme
    let compact: Bool
    @State private var swipe: CGFloat = 0

    var body: some View {
        let graph = AppGraph.shared
        let state = graph.player.state
        let c = theme.colors
        if let song = state.current {
            let playing = state.playWhenReady && !state.ended
            HStack(spacing: 10) {
                Artwork(url: song.artworkUrl, size: compact ? 30 : 38, label: song.album ?? song.title)
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title)
                        .font(.system(size: compact ? 14 : 15, weight: .semibold))
                        .foregroundStyle(c.ink)
                        .lineLimit(1)
                    if !compact, !song.artist.isEmpty {
                        Text(song.artist)
                            .font(.system(size: 13))
                            .foregroundStyle(c.ink3)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: swipe)
                .opacity(1 - min(0.8, Double(abs(swipe)) / 240))
                Button {
                    Haptics.tap()
                    graph.player.toggle()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: compact ? 18 : 21, weight: .semibold))
                        .foregroundStyle(c.ink)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel(playing ? "Pause" : "Play")
                if !compact {
                    Button {
                        Haptics.tap()
                        graph.player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(c.ink)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel("Next")
                }
            }
            .padding(.leading, compact ? 8 : 10)
            .padding(.trailing, 6)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if !compact {
                    PositionReader(interval: 0.5) { position in
                        let fraction = state.durationMs > 0 ? min(1, max(0, Double(position) / Double(state.durationMs))) : 0
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(c.ink4)
                                Capsule().fill(c.accent).frame(width: proxy.size.width * fraction)
                            }
                        }
                        .frame(height: 2)
                    }
                    // Under the title, clear of the artwork and the rounded end.
                    .padding(.leading, 58)
                    .padding(.trailing, 24)
                    .padding(.bottom, 4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { graph.actions.openPlayer() }
            .simultaneousGesture(swipeGesture)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now playing: \(song.title)")
            .accessibilityAction(named: "Open the player") { graph.actions.openPlayer() }
        } else {
            // Nothing loaded (iOS 26.0 keeps the bar's player even then): offer to pick up where you left off.
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(c.ink3)
                    .frame(width: 30, height: 30)
                Text("Not playing")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(c.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    graph.player.resume()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(c.ink)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Resume")
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                if abs(value.translation.width) > abs(value.translation.height) { swipe = value.translation.width }
            }
            .onEnded { value in
                let player = AppGraph.shared.player
                let travelled = value.translation.width
                guard abs(travelled) >= 64 else {
                    withAnimation(theme.spring ?? .default) { swipe = 0 }
                    return
                }
                // Slide out the way the finger went, change track, then bring
                // the new one in from the other side.
                let direction: CGFloat = travelled < 0 ? -1 : 1
                Haptics.tap()
                withAnimation(.easeIn(duration: 0.12)) { swipe = direction * 260 }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    if direction < 0 { player.next() } else { player.previous() }
                    swipe = -direction * 160
                    withAnimation(theme.spring ?? .default) { swipe = 0 }
                }
            }
    }
}
