# WritePad

> **Part of the [writing-process ecosystem](../writing-process/ECOSYSTEM.md).**
> **iPadOS** app that checks out Unblock manuscript repositories from GitHub, keeps
> them recent, and narrates them to an audiobook on-device. A mix of **Manuscript**
> (the library/git operator) and **abm** (the narrator), rebuilt for iPad.
> For how this fits with the other tools and the shared manuscript format, see the
> one map: [`../writing-process/ECOSYSTEM.md`](../writing-process/ECOSYSTEM.md).

SwiftUI, iPad only. Open `WritePad.xcodeproj`.

## What it does

1. **Check out** a manuscript repo from GitHub (paste a personal access token in
   Settings, pick a repo, clone it).
2. **Keep it recent** — a fetch + checkout of the latest commit on the default branch.
3. **Listen** — reads the repo's `Manuscript/*.md` chapters (Unblock Format) directly,
   then narrates a chapter with an in-process neural voice and plays it back.

## Why it can't reuse the macOS apps

iPadOS forbids the foundations both siblings rely on, so WritePad rebuilds them on
sandbox-safe, in-process libraries:

| Concern | macOS sibling | WritePad (iPad) |
|---|---|---|
| Git | shells out to `git` / the `unblock` CLI | **SwiftGit** — pure-Swift, in-process clone/fetch/checkout |
| GitHub | — | **swift-libgh** (`LibGH`) — REST API over `URLSession` |
| TTS | Python MLX sidecar | **swift-kokoro-tts** (English) + **swift-qwen3-tts** (German), in-process via `mlx-swift` |
| Draft source | built `Draft.md` from the Python engine | reads `Manuscript/*.md` chapters directly |

## Dependencies (local SPM packages under `../`)

`../swiftgit` · `../swift-libgh` · `../swift-kokoro-tts` · `../swift-qwen3-tts`, plus
remote `mlx-swift`. The neural engines download their model weights from the Hugging
Face hub into the sandbox cache on first use; the German voice library ships in the
app bundle (`Vendor/Qwen3Voices`).
