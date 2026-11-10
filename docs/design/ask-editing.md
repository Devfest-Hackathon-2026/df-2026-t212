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
labeled Send button submits. Return inserts a newline. Suggestion chips fill the
draft for review rather than submitting a paid request immediately.

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
Japanese draft preservation, suggestion behavior, explicit removal marks,
failure/retry, successful undo, cancellation of partial work, and Done saving
only the retained edit. The existing background Activity tests still cover
leaving the editor during an in-flight request.

Simulator verification used the generated postbox photo: a Japanese saturation
request completed through the real agent, displayed its result, and was undone.
The editor was cancelled afterwards; the library photo was left unchanged.

Final validation: 61 tests passed; static analysis reported no issues. Portrait
and landscape were inspected in the simulator, including the corrected safe
area around the top controls. Debug simulator and release physical iPhone builds
were installed and launched. Physical-device interaction remains user-verified.
