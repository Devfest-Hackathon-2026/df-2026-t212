# Print layout review — 2026-11-10

The user selected concept 1, then requested a second, optional full-photo treatment. Instant remains the default presentation. Photo, Instant, and Full photo are user-selectable; switching preserves the title, place, date, and color choices.

## Reference and rendered evidence

Selected source: `/Users/yohaku/Documents/Codex/2026-11-08/devfest-2026/artifacts/print-concepts-brand-2026-11-10/concept-1.png`.

Evidence directory: `/Users/yohaku/Documents/Codex/2026-11-08/devfest-2026/artifacts/print-concept1-implemented/`.

- `reference-comparison.png`: selected paper and exported Instant image, normalized to the same viewing area.
- `layout-options.png`: actual Instant and Full photo exports, at the same paper size.
- `ui-comparison.png`: previous Print screen and both implemented options, shown as whole screens.
- `phone.png`, `landscape.png`, `small-phone.png`, and corresponding `*-full-photo.png`: real-font widget renders at 393×852, 852×393, and 320×568 logical pixels.
- `concept1-print.jpg` and `full-photo-print.jpg`: output from the production export painter, using actual source-photo texture patches.

## Deliberate differences

The generated reference changed the source photo's geometry. Instant defaults to Fit and preserves the actual photograph, so its visible photo can be narrower than the reference. Title and metadata align with those visible photo edges. Fill remains available for deliberate cropping.

Full photo covers the paper and crops to the previewed area. Its controls state this. Only the area behind the caption is shaded; no caption means no shading. Text is white and badges retain their source texture. This was a separate user-requested option, not a replacement for concept 1.

Secondary print text is darker than the reference for readability. The surrounding app screen is white with a weaker paper shadow. Existing app-wide theme and other screens are unchanged. Optional metadata is not printed unless enabled or entered.

## Review history

The first implementation made the title, metadata, and badges too small. These now scale with the paper's short side; comparison was repeated using the complete paper. A final visual review found the title hierarchy, lower metadata baseline, right-aligned texture badges, and white space consistent with the selected direction.

The three-option style row initially overflowed with Flutter's wide test font. It now wraps when necessary, also supporting larger accessibility text without truncating the choices.

## Interaction and output checks

- Title and place can be edited while the complete paper remains visible; entering Details never enlarges it.
- Date and color choices survive switching between Instant and Full photo.
- Phone, landscape, and small-phone layouts are tested; a simulated keyboard inset checks for overflow and unwanted enlargement.
- Export tests verify default Fit preserves image edges, Fill crops, PDF generation succeeds, and real texture pixels reach saved output.
- Full photo tests verify no paper border, no shading without metadata, and shading confined to the caption region.
- Simulator: actual photo opened, Instant selected, title and place entered, date and colors enabled, iOS print sheet opened with the generated page, then cancelled. Controls recovered after cancellation.
- Physical printing and third-party keyboard behavior are not verified by these checks.

Final test and simulator results are recorded after the last build below.

## Final verification

- `flutter analyze lib test`: no issues.
- Full suite: 71 tests passed. After the final caption-contrast adjustment, the eight print tests passed again, including a white-background contrast regression check.
- Real-font capture run: eight tests passed; final exported images were inspected together at matched paper scale.
- Latest iOS Simulator build installed and launched successfully. Both layouts were selected with the same actual library photo; date and texture-badge choices survived switching back to Instant. The app was left on its Instant preview.
- Simulator paste/AX value injection did not enter the later test title; title editing was verified in the earlier native run and in the final widget tests, not inferred from that failed injection.
- Physical printer output remains unverified. No print job was submitted.

final result: passed

## Spacing follow-up

The title-to-metadata advance was reduced from 8.5 to 8 scaled millimetres (about 2 logical pixels in a phone preview). The complete second row moves left by 0.3 scaled millimetres (about 1 logical pixel). Both Instant and Full photo use the adjustment. The eight print tests passed; the complete-paper comparison was inspected at `/Users/yohaku/Documents/Codex/2026-11-08/devfest-2026/artifacts/print-spacing-2026-11-10/comparison.png`.
