import AVFoundation

/// Plays a rendered narration file. Configures the shared audio session for
/// playback so sound comes through even with the ring/silent switch silenced.
@MainActor
final class AudioPreviewPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onFinish: (() -> Void)?

    func play(url: URL) throws {
        stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        #endif
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.play()
        self.player = player
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Playback position in seconds, for dropping markers at the current point.
    var currentTime: Double { player?.currentTime ?? 0 }

    /// Pauses at the current position; `resume()` continues from there.
    func pause() { player?.pause() }

    func resume() { player?.play() }

    func stop() {
        player?.stop()
        player = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // Ignore a delayed finish from a player we've already stopped or
            // replaced (the delegate hops to the main actor, so a stop() or a
            // newly-started chapter can land first).
            guard self.player === player else { return }
            self.onFinish?()
        }
    }
}
