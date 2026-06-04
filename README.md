# Jot

A tiny, native macOS editor for touching up Markdown and HTML — the kind AI keeps generating for you.

## Why this exists

Most of the text you read now is shaped by an LLM somewhere upstream. Internally those systems pass each other Markdown. When they want a human to look at the output, they hand off HTML. Two formats, both meant for software to consume, both occasionally needing a human pass.

The problem: every existing tool for that pass is the wrong shape.

- **Spinning up an LLM** to change a word, fix a typo, re-flow a paragraph, or hide a stray `<div>` is overkill. You know exactly what you want — you just need a place to type it.
- **Sublime / VS Code / Cursor** are fast for source code, but they treat Markdown and HTML as monospace text. No live render, no clean rename, no place to *just see* the prose.
- **Obsidian / Bear / iA Writer** are great for writing, but they each impose a vault, sync, or library model — too heavy when you're touching up a file someone else produced.
- **Anything Electron-based** drags Chromium with it. Cold start in seconds, hundreds of megabytes of RAM, for a 5-second edit.

Jot is the editor for the in-between: a few-MB native macOS app you open instantly to do **the small, manual edits** between AI runs, and then close. No vault, no project, no sync, no LLM.

It also turns out to be a great spot to **jot down ideas by date** — every new file is autosaved into a `~/Documents/<YYYY-MM-DD>/` folder. You never lose a half-finished thought because you forgot to save, and you can find anything by the day you wrote it.

## What it does

- **Three panes**: file tree on the left (rooted at your working folder), plain-text editor in the middle, live HTML preview on the right (via WebKit + marked.js). Both side panels collapse from the toolbar.
- **Autosave by date**: new files land under `<working folder>/<YYYY-MM-DD>/<slug>.md`. The slug is derived from the first non-empty line (with YAML frontmatter `name:` / `title:` honored if present). Nothing is ever in an unsaved buffer.
- **Open from anywhere**: right-click any `.md` / `.html` in Finder → Open With → Jot. If the file sits outside your working folder, Jot copies it into today's folder first and opens the copy — your original (e.g. Downloads) is left untouched.
- **Inline rename**: a pencil next to the centered filename, plus double-click on the file in the sidebar. Rename moves the file on disk and updates the tree. Compared to having to right-click → rename → confirm in Finder, or rename twice across tabs in VS Code, it's instant.
- **HTML Contents Only mode**: a toolbar toggle that appears for `.html` files only. It hides every `<tag>`, every `<style>…</style>` and `<script>…</script>` block, and HTML comments — leaving just the prose visible. The tags stay in the file (saves are non-destructive); they're just rendered invisible while you edit the text.
- **Markdown preview** with full GFM: headings, tables, task lists, nested lists, code fences, blockquotes, strikethrough, autolinks, images. Dark-mode aware. Editor↔preview scroll stays synchronized while you edit Markdown; HTML preview scrolls independently (since it's already the rendered output).
- **Find** with `⌘F`: matches across the buffer are highlighted in yellow while the find bar is open; closing it clears the highlights.
- **Configurable working folder** (`⌘,` Settings): defaults to `~/Documents`, can be anything (with or without git, doesn't matter — Jot doesn't care).
- **Single window**, single document at a time. Sidebar navigates, editor edits. No tab clutter.

## What it deliberately doesn't do

- No LLM integration. If you want an AI rewrite, go upstream.
- No vault, no library, no sync. Files are just files in folders.
- No source-code features (no LSP, no syntax highlighting, no multiple cursors). Use a real code editor for code.
- No multi-window mode. One Jot window per Mac.

## Quick start

```bash
./build.sh
open "Jot.app"
```

Drag `Jot.app` to `/Applications` if you want it permanently registered as an "Open With" target across Finder.

## How files end up where they do

Default layout under your working folder:

```
~/Documents/                ← change in Settings (⌘,)
├── 2026-06-04/
│   ├── lagoon-platform-v2.md       ← derived from YAML `name:` field
│   ├── meeting-notes.md            ← derived from first heading
│   └── imported-report.html        ← copied from Downloads
├── 2026-06-05/
│   └── ...
```

The slug rule:

1. If the file starts with `---\n…\n---`, look inside the YAML frontmatter for `name:` or `title:`. If found, use that.
2. Otherwise, take the first non-empty line, strip leading `#` / `-` / `*` / `+` / `>` / `N.` markdown markers, sanitize to `[a-z0-9-_]`, cap at 40 chars.
3. Collisions get suffixed: `notes.md`, `notes-2.md`, `notes-3.md`, …
4. Empty content writes nothing — no `untitled.md` clutter until you actually type.

## Keyboard

| Shortcut | Action |
|----------|--------|
| `⌘N` | New file |
| `⌘W` | Close current file |
| `⌘F` | Find (highlights all matches in yellow) |
| `⌘G` / `⌘⇧G` | Find next / previous |
| `⌘⇧R` | Reveal current file in Finder |
| `⌘,` | Settings |

## Under the hood

- **UI**: SwiftUI with a single `Window` scene, `NavigationSplitView`.
- **Editor**: `NSTextView` (TextKit 1) wrapped in `NSViewRepresentable`. Display-only attributes (`NSLayoutManager.addTemporaryAttribute`) drive tag-hiding and search highlighting, so the underlying text storage is never mutated — your saves are always the exact bytes you see in source mode.
- **Preview**: `WKWebView` rendering an HTML template that inlines [marked.js 12.0.2](https://github.com/markedjs/marked). Markdown ↔ HTML conversion happens entirely locally; no network at runtime.
- **Sync**: editor and Markdown preview share a `scrollFraction` via a `WKScriptMessageHandler` ↔ `evaluateJavaScript` round-trip. HTML files skip the sync (preview is the rendered output, scrolling it shouldn't pull the source around).
- **Build**: pure Swift Package Manager — `swift build -c release` plus a small `build.sh` that wraps the binary in a `.app` bundle, generates `Jot.icns` from `assets/jot.png` via `sips` + `iconutil`, copies the SPM resource bundle (containing `marked.min.js`) into `Contents/Resources/`, and ad-hoc codesigns. No Xcode required.
- **Footprint**: the built `.app` is around 1 MB of code + 35 KB of bundled JS + the icon. Cold launch is effectively instantaneous.
- **Network**: zero at runtime. The only network call in this repository's lifetime was downloading `marked.min.js` once at build setup.
- **Telemetry**: none.

## Project layout

```
Sources/Jot/
├── AppMain.swift          ← @main App + commands + AppDelegate
├── ContentView.swift      ← three-pane layout, toolbar, empty state
├── DocumentStore.swift    ← EditorDocument + open/save/rename + slug rules
├── FileTreeStore.swift    ← sidebar root + change notifications
├── FileTreeView.swift     ← sidebar UI
├── MarkdownPreview.swift  ← passthrough to WebPreviewView
├── WebPreviewView.swift   ← WKWebView wrapper + marked.js template
├── Settings.swift         ← JotSettings + SettingsView (⌘,)
├── SyncScrolling.swift    ← CodeEditorView (NSTextView) + scroll math + tag-hiding/search
└── Resources/
    └── marked.min.js
assets/jot.png             ← app icon source
Info.plist                 ← document types, bundle metadata
Package.swift, build.sh
```

## Status

Personal tool. Built incrementally to scratch specific itches. Things that could be added if anyone needs them: line-anchored scroll mapping for the long-doc edge case, multi-window mode, file-watcher refresh of the tree when external edits land, configurable themes for the preview, syntax highlighting in code fences. None of those are in scope right now.
