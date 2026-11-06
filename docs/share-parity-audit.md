# Conversation share source audit

Baseline: `4d3d3c65df68e50220a89dfe9b124949316601ed`, build `42168726240` succeeded.
Reference: OpenMinis/OpenMinis `1a71df0f381cefde80bf912b723de6f9831bc177`, iOS `ChatShareModel.swift`, `ChatShareSelectionView.swift`, `ChatExportRenderer.swift` (blob `3a1417ed56bbf34094c1fa91d57e63bb3640fd58`).

| Behavior | Previous Ze | Source-derived replacement |
|---|---|---|
| Selection | Entire messages, all selected | Individual text/tool/thinking/error cells; menu starts empty; message entry selects its round |
| Reply grouping | Every assistant message independent | Consecutive assistant messages share a unit; hidden bridges do not split it |
| Range selection | Last tapped message downward | First visible cell downward; per-row select/deselect below; leading-edge drag with reversal and auto-scroll |
| Tool/thinking controls | Hide all tools; persistent export flags | Fold runs with selection remapping; hide thinking removes selected hidden cells |
| Layout | Single picker with option chips | Selection page, then automatically rendered preview with floating image/PDF selector and four bottom controls |
| Preview | Fit-to-width image / auto-scaled PDF | 1:1, pinch 1...4x, double-tap 2x/back; wide table horizontal scrolling |
| Options | Persistent width/light/header | Persist only format and hide-thinking; device width and app appearance; title on each opening |
| Render | Synchronous row snapshots; 20,000pt clamp; giant stitch before slicing | Actual row/block views, asynchronous attachment layout, one group at a time, original budget and PDF pagination rules |
| PDF | Raster stitched image | Original two-pass layout-manager glyph drawing; PDFKit text extraction validates selectable text |
| Cancellation | No task ownership | SwiftUI task keyed by options; superseded render cannot replace current progress; stable share anchor |
| Streaming | Live reference models | Frozen message/block copies preserving identities and selected state |

Ze-specific adapters use its existing assistant avatar, callback message format, tool fold policy and real markdown/block views. Product branding remains Ze. The reference iOS 26 glass surface is compiler-gated; iOS 16–18 use the original material fallback. Existing `SessionShareSheet` API wraps the new selection page, so the menu remains in the same location.

Validation must separate model tests, complete app compilation, actual rendering/export, and installed-device behavior. Source extraction and fixture generation alone do not establish visual equivalence. Actual image/table/code/tool exports and PDF text/page checks are required before delivery.

## Full-page source review

The complete `ChatShareSelectionView.swift` was diffed against the pinned source,
not only the standalone buttons. Selection navigation title and Cancel/Select All,
56-point top clearance, leading selection strip, centered floating action row,
bottom Share bar, preview navigation/share anchor, floating Image/PDF switch,
four equal-width bottom options, image/PDF 1:1 zoom containers and switch clearance
retain the reference layout. Compiler guards select the original legacy material
when the SDK lacks iOS 26 glass APIs. No rearrangement of these pages was needed.

The renderer review found one concrete header mismatch: using the generic chat
avatar omitted the secondary-background circular disc and rendered emoji at 82%
instead of the export reference's 55%. `ChatExportHeaderView.avatar` now uses the
reference 28-point disc, full-size uploaded image, 55%-size glyph and 0.5-point
ring; Ze's existing image/emoji/logo sources remain the content. Provenance:
`ChatExportRenderer.swift` `ChatExportHeaderView.avatar` and
`Agent/Session/SoulStore.swift` `SoulIconView` at the same pinned commit.

A stale drag-start frame after hiding/folding rows could index beyond `cells`;
the picker now checks the start index before reading it, as it already did for
the current index. This is a bounded correction to the source interaction, with
no layout change. Full-app screenshots/rendering remain a separate CI gate.
