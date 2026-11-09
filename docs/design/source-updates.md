# Source versions and editing — 2026-11-10

## Implemented behavior

- After Hue retains a content-addressed copy of the Photos version it uses.
  Photos edits cannot silently change that snapshot. Render and swatch cache keys
  include the selected version. State is saved by atomic file replacement.
- Source checks run on app resume, library refresh, or **Check Photos**. Native
  capture reads the current Photos rendition without requesting an iCloud download.
  Unavailable assets are retried later and never replace a valid snapshot.
- Existing edits remain readable. The first snapshot of a legacy item establishes
  a baseline from what Photos currently provides; it cannot reconstruct an older,
  already overwritten rendition. This is not represented as a historical match.
- Keep and Exclude colors retain normalized sample positions and measured OKLab.
  The app adds spatially distributed references for HEX/palette/legacy colors;
  agents can continue using either coordinates or HEX. References do not change
  the rendered result or its cache signature.
- Local matching compares structure, per-reference color changes and the resulting
  selection mask. It preserves the chosen hue widths/edges and adjusts the color
  center and gates. Inconsistent changes, missing references, neutralized colors,
  framing changes or excessive mask changes require review. No paid AI is invoked.
- **Follow changes in Photos** is off initially. When enabled, only accepted local
  matches apply automatically, and never while a detail screen is open or the
  photo is being edited/processed. Changes are grouped in Activity.
- Review shows current and updated versions. Ready items can be applied together;
  uncertain items open the editor. Cancel restores the current source/edit and
  leaves the proposal pending. Keep current acknowledges that Photos revision.
- The previous source and recipe can be restored individually or together. The
  restore dialog explains that edits made after the update are also replaced.
  Undo is one version deep; Photos itself is never modified by these operations.
- Crop has free/preset aspect ratios, draggable corners, repositioning/pinch,
  clockwise quarter turns, -45..45 degree straightening and Reset. The full source
  remains available. Color/Area coordinates stay in the source frame; rendering
  crops after selective-color processing. Preview transforms include hit testing.
- Tone > Saturation (0..200%, default 100%) changes kept chroma, not the selection
  mask or the monochrome atmosphere. Agent tools `set_crop` and `set_saturation`
  use the same recipe and renderer as human controls.

## Verification

- Synthetic tests cover global hue shifts, divergent changes to one color,
  displaced geometry, legacy evidence, serialization and stable render keys.
- Store tests cover frozen source pixels, review, local application, persistence,
  restoration, acknowledged revisions, view protection and automatic matching.
- Crop tests cover rotation/cropping pixels, source-coordinate hit testing,
  ratio controls, invalid agent parameters and saturation/mask independence.
- Simulator: Photos Vivid Warm on the demo postbox -> change detected -> current
  and tracked result compared -> update -> restore. Photos filter also reverted.
  Crop/rotation and Saturation were operated in the native simulator UI.

## Remaining work and limits

- **Before submission: fix Ask UX as a complete interaction flow.** The user says
  the current UX is still poor. Review opening, recognizable input, keyboard and
  photo layout, sending, progress, cancellation/Done and result inspection. This
  is the next priority, ahead of printing/Explore.
- Automatic geometric correspondence is conservative: framing changes wait for
  manual review; arbitrary crop/rotation registration is not implemented yet.
- Source checks require the app to run; no background-execution guarantee or OS
  push notification is introduced here. Notification batching lives in Activity.
- Source versions currently occupy application storage. Retention/quota and
  orphan-file collection should be designed before a large-library release.
- Printing comes after editing, then Explore: public-author-hidden photographs,
  magazine-like presentation, short titles and swatches, optional date/location,
  hearts/bookmarks/sharing, no comments. Personal library sync and Web are deferred.

## Gallery startup performance

- Disk-render hits do not start an original placeholder read. A placeholder is
  deferred briefly and never captures a full-size source just for display.
- Freezing a new baseline preserves its existing cache identity. Accepted source
  changes use a new version identity; older snapshots with no baseline evidence
  retain their existing versioned cache keys rather than guessing equivalence.
- Background source checks begin after the first gallery frames, process one
  item at a time and yield between items. Legacy color-reference derivation is
  deferred until a source change actually needs matching.
- Render cache misses run at most two jobs concurrently; hits bypass the queue.
  Snapshot hashing runs off the UI isolate. Snapshot display thumbnails persist
  on disk and avoid the previous RGBA readback/reconstruction round trip.
- Regression test reproduces an unnecessary full-original read on a cached grid
  tile, then verifies zero captures on that path and cache continuity after
  baseline capture/persistence.
- Final verification: 59 tests pass and static analysis reports no issues.
  Simulator relaunch displayed the gallery while reusing all 280 existing render
  and swatch files (zero new or rewritten entries). Simulator debug and physical
  iPhone release builds were installed and launched. Physical-device startup
  latency has not been measured; no before/after time claim is made.
