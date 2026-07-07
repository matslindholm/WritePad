import Foundation
import Observation
import os

/// Samples the app's real memory footprint (what jetsam counts) and how much
/// headroom remains before the OS would kill the process. Used to watch the
/// neural-model load/inference cost on-device.
@MainActor
@Observable
final class MemoryMonitor {
    private(set) var footprintBytes: UInt64 = 0
    private(set) var availableBytes: UInt64 = 0

    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// Samples once per second until `stop()`. Idempotent.
    func start(interval: Duration = .seconds(1)) {
        guard task == nil else { return }
        sample()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.sample()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func sample() {
        footprintBytes = Self.physFootprint()
        availableBytes = Self.availableMemory()
    }

    /// Headroom before the process would be starved of memory. On iOS this is
    /// the per-app limit the OS enforces (jetsam); on macOS, which has no such
    /// per-app cap, it's the free physical RAM.
    private static func availableMemory() -> UInt64 {
        #if os(iOS)
        return UInt64(max(0, os_proc_available_memory()))
        #else
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageSize
        #endif
    }

    /// Resident memory attributed to the app, matching the jetsam accounting.
    private static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
