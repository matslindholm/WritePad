# WritePad — Claude context

## Ecosystem context

WritePad is the **iPad** member of the writing-process ecosystem — it combines the roles
of **Manuscript** (check out and keep book repos recent) and **abm** (narrate a manuscript
to audio), rebuilt for iPadOS. The single authoritative map of all projects lives at
[`../writing-process/ECOSYSTEM.md`](../writing-process/ECOSYSTEM.md) — read it before
reasoning about how WritePad relates to the other tools or the shared manuscript format.

## This project

SwiftUI, **iPad only** (`TARGETED_DEVICE_FAMILY = 2`). Open `WritePad.xcodeproj`; the app
target uses a file-system-synchronized group, so any file added under `WritePad/` compiles
automatically. Source is organised `Models/`, `Managers/`, `Views/` (MVC — logic in Managers).

Because iPadOS has no `Process` and no Python, WritePad does **not** shell out or run a
sidecar. Everything is in-process and sandbox-safe:

- **Git** via `SwiftGit` (`../swiftgit`) — `RepositoryCheckout` wraps clone/fetch/checkout.
- **GitHub** via `LibGH` (`../swift-libgh`) — `GitHubService` lists the user's repos.
- **TTS** via `KokoroTTS` (English) and `Qwen3TTS` (German), routed by book language in
  `NarrationCoordinator`; weights download from the HF hub, German voices ship in
  `Vendor/Qwen3Voices` (a folder reference, not in the synchronized group).
- **Chapters** read straight from the repo's `Manuscript/*.md` (`ChapterReader`,
  Unblock Format §3–§7): frontmatter parsed, prologue first / epilogue last, `order:`-sorted.

The GitHub token is Keychain-backed (`AppSettings` / `Keychain`). The checked-out library
is a JSON index under Application Support (`ProjectLibrary`).

## Building

The three sibling SPM packages were given iOS platform support and iOS-safe cache paths
(no `homeDirectoryForCurrentUser`). Command-line builds need
`-skipPackagePluginValidation` (mlx-swift's CudaBuild plugin). Deployment target is
iPadOS 26.5, so run on a 26.5 simulator runtime.
