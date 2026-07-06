import Foundation
import MLX

/// Bounds MLX's unified-memory buffer cache. The engines run one autoregressive
/// generation per chunk — hundreds over a book — and MLX keeps every freed
/// buffer in a reuse cache that, uncapped, grows until it exhausts RAM. Capping
/// it and reclaiming after each render keeps memory flat.
enum MLXMemory {
    private static let cacheLimitBytes = 256 * 1024 * 1024

    private static let applyCap: Void = {
        MLX.Memory.cacheLimit = cacheLimitBytes
    }()

    static func configure() { _ = applyCap }

    static func reclaim() { MLX.Memory.clearCache() }
}
