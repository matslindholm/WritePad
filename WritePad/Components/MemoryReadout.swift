import SwiftUI

/// A compact live memory bar: how much the app is using and how much headroom
/// remains before the OS would terminate it. Colors the headroom as it tightens.
struct MemoryReadout: View {
    @State private var monitor = MemoryMonitor()

    var body: some View {
        HStack(spacing: 10) {
            Label(format(monitor.footprintBytes), systemImage: "memorychip")
            Text("used")
                .foregroundStyle(.tertiary)
            Spacer()
            Circle()
                .fill(headroomColor)
                .frame(width: 7, height: 7)
            Text("\(format(monitor.availableBytes)) free")
                .foregroundStyle(headroomColor)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private var headroomColor: Color {
        let mb = monitor.availableBytes / (1024 * 1024)
        if mb < 300 { return .red }
        if mb < 700 { return .orange }
        return .green
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
