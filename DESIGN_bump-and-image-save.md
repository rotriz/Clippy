# Design Spec — Bump-on-select + Save Image As…

Author: @claude (Planner/Designer) · Implementer: @gemini
Scope: two user-reported issues in Clippy.

---

## Issue 1 — Selected clip should move to the top

### Symptom
When the user pastes/selects an existing clip (via ⌘1–9, ↩, or mouse click), the
clip stays in its current list position. Expected: it floats to the top
(most-recently-used), matching the consecutive-recapture behavior that already
exists at capture time.

### Root cause
`ClipStore.insert(...)` already calls a private `touch(id:)` that bumps
`created_at = now` and `copy_count += 1` — but **only** on consecutive-capture
dedup. Nothing bumps a clip when it is *re-used from history*. Under the default
`SortMode.lastCopiedAt` (`ORDER BY pinned DESC, created_at DESC`) the row
therefore never moves.

### Design

**1. `ClipStore` — expose a public "mark used" mutation.**
Add (reusing the existing `touch` SQL):

```swift
/// A deliberate re-use of an existing clip from history: bump it to the top
/// (created_at = now) and increment the copy counter. Mirrors capture-time
/// dedup so re-pasted clips behave like freshly-copied ones.
func markCopied(id: Int64) {
    queue.sync {
        do {
            try touch(id: id)
            // Keep the dedup fast-path consistent: this clip is now both the
            // newest row AND what's on the system pasteboard, so lastHash must
            // point at it — otherwise the next capture compares against a stale
            // hash and mis-folds (see newestHash()/insert()).
            let h = try db.prepare("SELECT content_hash FROM clips WHERE id = ?1;")
            h.bind(1, id)
            if try h.step() { lastHash = h.string(0) }
        } catch {
            Log.storage.error("markCopied failed: \(String(describing: error), privacy: .public)")
        }
    }
}
```

> ⚠️ **Critical correctness note (do not skip the `lastHash` update).**
> `newestHash()` trusts the in-memory `lastHash` as the hash of the
> newest-by-`created_at` row. After `markCopied` bumps an *old* clip to newest,
> `lastHash` would otherwise still hold a *different* clip's hash, so the next
> capture's dedup check would compare new content against the wrong hash. Always
> set `lastHash` to the bumped clip's `content_hash` inside `markCopied`.

**2. `PasteService` — call `markCopied` on every deliberate re-use:**
- `paste(id:...)` → after a successful `loadClip`, call `store.markCopied(id: id)`.
  (This covers quick-paste ⌘1–9, ↩, and mouse click — all route through `paste`.)
- `copyToClipboard(id:...)` → same (Accessibility-off fallback path).
- `pasteTransformed(id:...)` → `store.markCopied(id: id)` (source clip was used).
- `pasteNext(...)` (stack sequence) → `store.markCopied(id: ids[index])` per item.
- `pasteSnippet(...)` → **no** call (snippets are not clips).

**3. UI refresh — none needed.** The activate flow is `hide()` → `paste()`, and
`PanelController.show()` already calls `model.reload()`, so the next panel open
reflects the new order. (DB writes are synchronous on the store queue, so the
order is persisted before the next show.)

### Behavior notes / acceptance
- Default sort (`lastCopiedAt`): re-used clip jumps to top. ✅ primary fix.
- `firstCopiedAt` sort: position unchanged (correct — that sort is by first copy).
- `numberOfCopies` sort: `copy_count++` may move it up, and the `×N` badge in
  `ClipRowView.metaLine` increments. Acceptable / expected.
- Pinned clips stay in the pinned band (`pinned DESC` leads the ORDER BY).

---

## Issue 2 — Save a clipboard image as a file (png/jpg/…) to a chosen location

### Design
Add a **right-click → "Save Image As…"** action on image rows that opens an
`NSSavePanel`, letting the user pick location + format. Convert on save when the
chosen extension differs from the stored original. Keep MEM-03 discipline: read
full-res bytes only at save time, release immediately after writing.

**1. New helper — `Sources/Clippy/Clipboard/ImageExporter.swift`:**

```swift
import AppKit
import UniformTypeIdentifiers

enum ImageExporter {
    /// Present a save panel for the image clip `id` and write the chosen file.
    /// Loads original bytes on demand and releases them after writing (MEM-03).
    @MainActor
    static func saveImage(id: Int64, store: ClipStore) {
        guard let clip = store.loadClip(id: id), clip.type == .image,
              let srcPath = clip.originalImagePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: srcPath)) else { return }

        let srcExt = (srcPath as NSString).pathExtension.lowercased()

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Clipboard Image"
        panel.allowedContentTypes = [.png, .jpeg, .tiff].compactMap { $0 }
        // Default to the original format.
        if let srcType = UTType(filenameExtension: srcExt) { panel.allowedContentTypes = [srcType] + panel.allowedContentTypes }

        // Background agent (LSUIElement) must activate to show an interactive panel.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let destExt = dest.pathExtension.lowercased()
        do {
            if destExt == srcExt || (destExt == "jpg" && srcExt == "jpeg") || (destExt == "jpeg" && srcExt == "jpg") {
                try data.write(to: dest, options: .atomic)          // same format → copy bytes
            } else if let out = convert(data, to: destExt) {
                try out.write(to: dest, options: .atomic)           // re-encode
            } else {
                try data.write(to: dest, options: .atomic)          // fallback
            }
        } catch {
            Log.storage.error("saveImage failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Re-encode arbitrary image bytes into png/jpeg/tiff via NSBitmapImageRep.
    private static func convert(_ data: Data, to ext: String) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        let type: NSBitmapImageRep.FileType
        switch ext {
        case "jpg", "jpeg": type = .jpeg
        case "tiff", "tif":  type = .tiff
        default:             type = .png
        }
        let props: [NSBitmapImageRep.PropertyKey: Any] =
            (type == .jpeg) ? [.compressionFactor: 0.9] : [:]
        return rep.representation(using: type, properties: props)
    }
}
```

**2. Wire an entry point — context menu on image rows.**
In `HistoryView.clipsList`, add to each row a `.contextMenu` that shows the item
only for images, calling a new closure `onSaveImage`:

```swift
.onTapGesture { onActivate(item.id, false) }
.contextMenu {
    if item.type == .image {
        Button("Save Image As…") { onSaveImage(item.id) }
    }
}
```

Thread `onSaveImage: (_ id: Int64) -> Void` through `HistoryView` exactly like
the existing `onActivate` (add the property, pass it from `PanelController`).

**3. `PanelController` — implement the closure.**
Add to `makePanel()`'s `HistoryView(...)` init:

```swift
onSaveImage: { [weak self] id in self?.saveImage(id: id) }
```

and the method:

```swift
private func saveImage(id: Int64) {
    hide()                                  // get the floating panel out of the way
    ImageExporter.saveImage(id: id, store: model.store)
}
```

**4. Optional (nice-to-have, same closure):** add a "Save…" button to the image
branch of `PreviewItemView.content(_:)`. Skip if it complicates the overlay; the
context menu is the required deliverable.

### Edge cases
- Non-image clip / missing `originalImagePath` / unreadable file → guard returns, no-op.
- User cancels the panel → no-op.
- Conversion failure → fall back to writing original bytes; log on hard failure.
- App is a background agent: `NSApp.activate(ignoringOtherApps:)` before
  `runModal()` is required or the panel won't be interactive. Hiding the Clippy
  panel first avoids it floating over the dialog.

---

## Files touched
| File | Change |
|---|---|
| `Storage/ClipStore.swift` | add `markCopied(id:)` (reuses `touch`, fixes `lastHash`) |
| `Clipboard/PasteService.swift` | call `markCopied` in paste / copyToClipboard / pasteTransformed / pasteNext |
| `Clipboard/ImageExporter.swift` | **new** — NSSavePanel + format conversion |
| `UI/HistoryView.swift` | add `onSaveImage` closure + `.contextMenu` on rows |
| `UI/PanelController.swift` | pass `onSaveImage`, add `saveImage(id:)` |
| `UI/PreviewItemView.swift` | *(optional)* Save button on image preview |

## Verify
1. `swift build -c release` clean.
2. Copy 3 text items A,B,C. Open panel (⌘⇧V), select A (oldest) → A should be top
   on next open. Repeat with ⌘1–9 and mouse click.
3. Confirm the `×N` copy-count badge increments on re-use.
4. Copy an image, right-click its row → "Save Image As…" → save as PNG and as
   JPG to Desktop; verify both files open and are valid.
5. Re-confirm the memory benchmark (`Scripts/mem_benchmark.sh`) is unaffected
   (no full-res bytes retained after save).
