import AVFoundation

/// Plays a rendered narration file. Configures the shared audio session for
/// playback so sound comes through even with the ring/silent switch silenced.
@MainActor
final class AudioPreviewPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onFinish: (() -> Void)?

    func play(url: URL) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.play()
        self.player = player
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Pauses at the current position; `resume()` continues from there.
    func pause() { player?.pause() }

    func resume() { player?.play() }

    func stop() {
        player?.stop()
        player = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinish?() }
    }
}
