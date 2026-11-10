# Ask editing — 2026-11-10

## Problem and decision

The old composer removed siblings when its field gained focus. Flutter replaced
EditableText's state even though the externally owned FocusNode still reported
focus; the native text input client could therefore be detached until a second
tap. This was reproduced in the simulator and by checking EditableText identity
in a widget regression test. Checking only FocusNode.hasFocus missed the defect.

Ask is an editing operation on the visible photo. Keep the input and its native
client mounted while keyboard, draft, mark mode and orientation change. Opening
Ask requests focus; an explicit outlined multiline field accepts text and a
labeled Send button submits. Return inserts a newline.

The first redesign still used a tall form and was rejected on a physical phone:
a third-party Japanese keyboard left only a tiny photo, with Send partly clipped.
Typing now shows a single compact row: dismiss keyboard, outlined input, Send.
There is no heading or suggestion bank. The top editor toolbar is hidden while
Ask's software keyboard is open. The field grows to at most three lines (one in
a short landscape viewport); its placeholder stays on one line. Send remains
beside the field instead of below a scrollable form. Dismissing the keyboard
returns space to the photo and exposes Mark photo, Before and Close Ask.
Stable keys retain the native field when those controls appear or disappear.

## Interaction

- Closing Ask preserves its text and marks for this editor session.
- Mark photo reveals explicit Keep color / Remove color choices. Tap an object
  to mark it; the same action on the same mark clears it, a different action
  replaces it. Clear marks clears only marks, not the typed request.
- Pinching never adds marks. The text and photo remain separate: portrait fits
  the photo above the keyboard; landscape puts the composer beside the photo.
- Sending shows the submitted request and the current tool stage. Done continues
  the run and links its outcome through Activity, as before. Reopening a running
  request restores that context. Closing a newly started request's editor with
  Cancel cancels the request; reopening a previously backgrounded request does
  not implicitly cancel it again.
- Stop cancels the request and restores the recipe from before it started.
  Partial agent output is not silently retained. The request can be retried.
- Success offers Hold to compare with the pre-request recipe, Undo edit and Ask
  again. Failure retains the request and marks, offers Edit request and Retry,
  and restores the pre-request recipe. No automatic retries are introduced.
- Crop and saturation stages have explicit progress labels throughout the app.

## Verification

Widget tests cover native input identity, keyboard and orientation changes,
Japanese draft preservation, explicit removal marks,
failure/retry, successful undo, cancellation of partial work, and Done saving
only the retained edit. The existing background Activity tests still cover
leaving the editor during an in-flight request.

Simulator verification used the generated postbox photo: a Japanese saturation
request completed through the real agent, displayed its result, and was undone.
The editor was cancelled afterwards; the library photo was left unchanged.

The compact composer regression uses a 393×852 viewport with a 62-point top
safe area and keyboards of 300, 367 and 430 points. It checks the empty draft,
photo size, a fully visible 44-point Send target, native input identity and a
Japanese multiline draft. Marking and closing/reopening still preserve the draft.
These synthetic insets cover taller third-party keyboards; they do not simulate
a third-party IME itself.

The compact version was inspected with the simulator's Japanese software
keyboard actually visible: empty input, immediate on-screen kana entry, keyboard
dismissal and one-tap re-entry all worked. The final build was visually checked
again after replacing an unavailable Cupertino icon with a bundled Material
keyboard-dismiss icon. No paid request was submitted during this layout check.

Validation: 61 tests passed. Analysis of the changed Dart files reported no
issues. Whole-repository analysis has two existing avoid_print infos in
`tool/render_check.dart` and `tool/vignette_check.dart`.

Debug simulator and release physical iPhone builds were installed and launched.
The third-party keyboard on the physical device still needs user confirmation;
native interaction verification used the simulator's built-in Japanese keyboard.
