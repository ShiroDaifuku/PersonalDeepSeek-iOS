import AVFoundation
import SwiftUI
import UIKit

enum MascotVideoMode: Equatable {
    case idle
    case thinking

    var resourceName: String {
        switch self {
        case .idle: "MascotIdle"
        case .thinking: "MascotThinking"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: "角色待机动画"
        case .thinking: "角色思考动画"
        }
    }
}

struct MascotVideoView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let mode: MascotVideoMode
    let isPlaying: Bool

    var body: some View {
        LoopingVideoRepresentable(
            resourceName: mode.resourceName,
            isPlaying: isPlaying && !reduceMotion && scenePhase == .active
        )
        .background(Color.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode.accessibilityLabel)
        .accessibilityValue(reduceMotion ? "动画已暂停" : (isPlaying ? "播放中" : "已暂停"))
    }
}

private struct LoopingVideoRepresentable: UIViewRepresentable {
    let resourceName: String
    let isPlaying: Bool

    func makeUIView(context: Context) -> LoopingVideoUIView {
        let view = LoopingVideoUIView()
        view.configure(resourceName: resourceName, isPlaying: isPlaying)
        return view
    }

    func updateUIView(_ uiView: LoopingVideoUIView, context: Context) {
        uiView.configure(resourceName: resourceName, isPlaying: isPlaying)
    }

    static func dismantleUIView(_ uiView: LoopingVideoUIView, coordinator: Void) {
        uiView.stop()
    }
}

private final class LoopingVideoUIView: UIView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var loadedResourceName: String?

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        player.isMuted = true
        player.actionAtItemEnd = .none
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(resourceName: String, isPlaying: Bool) {
        if loadedResourceName != resourceName {
            load(resourceName: resourceName)
        }
        if isPlaying, looper != nil {
            player.play()
        } else {
            player.pause()
            if player.currentTime().seconds.isNaN { player.seek(to: .zero) }
        }
    }

    func stop() {
        player.pause()
    }

    private func load(resourceName: String) {
        player.pause()
        looper = nil
        player.removeAllItems()
        loadedResourceName = resourceName
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mp4") else { return }
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.seek(to: .zero)
    }
}
