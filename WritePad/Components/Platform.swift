import SwiftUI

/// Cross-platform shims so the same views compile on iPadOS and macOS. The
/// navigation-bar toolbar placements and text-input modifiers only exist on
/// iOS; these map them to the closest macOS equivalent (or a no-op).
extension ToolbarItemPlacement {
    /// Leading navigation-bar slot on iPad; the navigation slot on macOS.
    static var barLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    /// Trailing navigation-bar slot on iPad; the primary-action slot on macOS.
    static var barTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

extension View {
    /// Compact inline navigation title on iPad; macOS has no display mode, so
    /// this is a no-op there.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Disables autocapitalization for identifier/token entry on iPad; no-op on
    /// macOS, which has no software-keyboard autocapitalization.
    @ViewBuilder
    func noAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// Gives modal sheets a usable size on macOS, where they otherwise size to
    /// content and clip. No-op on iPad, where sheets fill the presentation.
    @ViewBuilder
    func macSheetFrame() -> some View {
        #if os(macOS)
        frame(minWidth: 560, idealWidth: 620, minHeight: 460, idealHeight: 580)
        #else
        self
        #endif
    }

    /// A large, resizable size for the read-along sheet on macOS, which would
    /// otherwise collapse to its minimum content and clip the transcript. No-op
    /// on iPad, where it fills the screen.
    @ViewBuilder
    func macReadingFrame() -> some View {
        #if os(macOS)
        frame(minWidth: 640, idealWidth: 820, maxWidth: .infinity,
              minHeight: 640, idealHeight: 880, maxHeight: .infinity)
        #else
        self
        #endif
    }
}
