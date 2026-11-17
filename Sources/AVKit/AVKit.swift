@_exported import AVFoundation
import SwiftUI

// AVKit for LSim: `VideoPlayer` shows an AVPlayer's real frames; a tap toggles play/pause like iOS's minimal controls.

public struct VideoPlayer<VideoOverlay: View>: View {
    let player: AVPlayer?
    let overlay: VideoOverlay

    public init(player: AVPlayer?) where VideoOverlay == EmptyView {
        self.player = player
        overlay = EmptyView()
    }

    public init(player: AVPlayer?, @ViewBuilder videoOverlay: () -> VideoOverlay) {
        self.player = player
        overlay = videoOverlay()
    }

    public var body: some View {
        PlayerSurface(player: player) { overlay }
    }
}

/// Reusable video surface (VideoPlayer, player stand-ins): the player's current frame, fitted.
public struct PlayerSurface<Overlay: View>: View {
    let player: AVPlayer?
    let overlay: Overlay
    let showsControls: Bool
    @State private var frame: CVPixelBuffer?
    @State private var playing = false

    public init(player: AVPlayer?, showsControls: Bool = true, @ViewBuilder overlay: () -> Overlay) {
        self.player = player
        self.showsControls = showsControls
        self.overlay = overlay()
    }

    public var body: some View {
        ZStack {
            Color.black
            if let image = frame ?? player?._currentFrame {
                _PixelBufferView(image)
            }
            overlay
            if showsControls, !playing, player?.currentItem != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
                    .padding(18)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard showsControls, let player else { return }
            if player.timeControlStatus == .playing { player.pause() } else { player.play() }
        }
        .onReceive(player?._frames.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { frame = $0 }
        .onReceive(player?.publisher(for: \.timeControlStatus) ?? Just(.paused).eraseToAnyPublisher()) {
            playing = $0 != .paused
        }
    }
}

extension PlayerSurface where Overlay == EmptyView {
    public init(player: AVPlayer?, showsControls: Bool = true) {
        self.init(player: player, showsControls: showsControls) { EmptyView() }
    }
}

/// UIKit full-screen controller: unavailable in the simulator, present so code compiles.
open class AVPlayerViewController {
    public var player: AVPlayer?
    public var showsPlaybackControls = true
    public var videoGravity: AVLayerVideoGravity = .resizeAspect
    public var allowsPictureInPicturePlayback = true
    public var entersFullScreenWhenPlaybackBegins = false
    public var exitsFullScreenWhenPlaybackEnds = false
    public init() {}
}
