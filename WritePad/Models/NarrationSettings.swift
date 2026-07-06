/// Per-render narration knobs. The neural engines pace themselves, so this
/// stays minimal for now; kept as a seam for future rate/pitch controls.
struct NarrationSettings: Equatable, Sendable {
    var speed: Float

    init(speed: Float = 1.0) {
        self.speed = speed
    }
}
