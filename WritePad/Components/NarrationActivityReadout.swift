import SwiftUI

/// A compact status line for the narration pipeline's pending work: what's
/// rendering now, what's queued behind it, and how many read-along timelines are
/// still being built. Sits just above the memory readout and hides when idle.
struct NarrationActivityReadout: View {
    @Environment(NarrationCoordinator.self) private var narration

    var body: some View {
        let segments = segments
        if !segments.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(segments.joined(separator: "  ·  "))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private var segments: [String] {
        var segments: [String] = []
        if let p = narration.chunkProgress {
            segments.append("Generating \(p.completed)/\(p.total)")
        } else if let p = narration.backgroundRendering {
            segments.append("Generating \(p.completed)/\(p.total) in background")
        }
        let queued = narration.queuedGenerationCount
        if queued > 0 { segments.append("^[\(queued) chapter](inflect: true) queued") }
        let timelines = narration.pendingTimelineCount
        if timelines > 0 { segments.append("Preparing read-along (\(timelines))") }
        return segments
    }
}
