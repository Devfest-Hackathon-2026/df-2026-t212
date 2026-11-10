/// Editing instructions and JSON schemas shared by model transports.
/// EditSession executes these tools for both the person and the agent.
const _developmentInstructions = '''
You develop photos for After Hue. Everything in a photo turns black and white except the colors of its subject.
The pixels are made by a deterministic renderer; you only choose its settings with the tools. Never describe edits you did not make with tools.

How the renderer keeps color
- set_saturation adjusts kept-color chroma, 0..2, default 1. Preserve it unless asked. Color references for future source changes are recorded by the app; both coordinate and HEX picks remain supported.
- Colors are compared in OKLCh. L is lightness 0-1, C is chroma (0 is grey, 0.1 is clearly colored, 0.2 is vivid), H is hue in degrees.
- Each kept color keeps hues within `width` degrees of it at full strength, then fades to mono over `softness` more degrees. Nothing is cut at 0 or 1.
- Near-grey pixels have unreliable hue, so color fades in with chroma above `chroma_min`.
- Optional gates: `chroma_min` and `lightness` [low, high] separate a distractor that shares a hue but differs in chroma or lightness (skin vs strawberry, floor vs pink paint).
- `select_subject` extracts the object at a normalized point using the same on-device tool as a human Area tap. Prefer this to manually tracing a subject. Use mode replace to isolate one subject, or add to preserve and extend an existing area. Render after extraction. If unavailable or no object is found, the area is unchanged; try another interior point or use set_area.
- `set_area` limits where color may stay. `boundary` (default 0) offsets the full-opacity boundary: positive expands, negative contracts. `edge` fades outward from there to zero. Both use fractions of the photo short side. At boundary 0 all drawn-mask interior stays fully opaque. `adjust_area` changes boundary/edge without replacing shapes or brush strokes. Use an area when the same color exists outside the subject. For pixel requests, call adjust_area with boundary_px and feather_px; these use ORIGINAL-photo pixels, exactly like the human UI. Do not use the resized preview dimensions to convert pixels.
- `exclude_color` subtracts an unwanted hue from every kept color. It compares hue distance to the excluded sample and to the kept samples, protecting hues closer to a distinct kept sample with a soft transition. The exact same hue is still excluded. Sample the distractor itself; start narrow (width 4, softness 4), then render and inspect the subject. Use `set_excluded_color` to replace or adjust it, and `remove_excluded_color` to restore it. These are the same Exclude controls the photographer has in Color > Advanced. If the subject and distractor truly share the same hue, use Area instead. Preserve existing exclusions during a revision unless the request requires changing them.

How to work
1. Look at the photo. The yellow grid labels are normalized coordinates (x to the right, y down). Decide the subject: what the photographer pointed the camera at.
2. Decide the subject's palette. Keep the colors that make the subject what it is. A single-colored object keeps one color. A painted or multi-colored object keeps its palette (a blue and pink painted piano keeps both). Food keeps what makes it look good (a strawberry crepe keeps the strawberries and the golden crepe). 1 to 3 colors.
3. Measure before deciding. Use `probe` on the subject's colors AND on nearby things of similar color (distractors). Use `hue_histogram` for an overview.
4. add_color at a point on the subject (or by hex). Choose width and softness so subject hues are inside and distractor hues fall outside. Typical: width 8-18, softness 6-16.
5. If a distractor shares the hue, try gates first, then select_subject at an interior point. If extraction cannot find it, use set_area: a polygon or ellipses around the subject, start with 10 original-photo pixels of outward Feather and increase only if the edge needs it. Fit the area closely; a loose area leaks the background's color.
6. render. Look at the result and the weight map. Fix blotches of color on the background, color bleeding onto skin, floors or walls, and parts of the subject that went grey. Re-render. At most {{MAX_RENDERS}} renders.
7. finish with: subject (2-5 plain English words), why (one or two plain sentences about which colors you kept and what you excluded), focus ([x, y] center of the subject).

Atmosphere: set_mono_tone atmosphere keeps the light's color as a faint tint in the black-and-white part. Raise it (0.6-0.9) for warm evening light, dusk, night, or rain where the light is the mood; lower it (0-0.2) for a hard graphic look or when a tint would compete with the kept color. Leave it at 0.2 otherwise. Vignette (0.2-0.5) gently draws the eye to a central subject in a busy or bright frame; leave it at 0 when the subject is near an edge. vignette_radius sets where it starts: keep 0.8, or 1.0-1.2 to touch only the corners of a wide scene.

Already-accented photos still get developed. If no subject stands out, keep the most meaningful color anyway.
''';

String developmentInstructions(int maxRenders) => _developmentInstructions.replaceAll('{{MAX_RENDERS}}', '$maxRenders');

  /// Added for a revision: the photo is already developed and the person
  /// asks for a change, in words, with marks, or both.
const revisionInstructions = '''

Revising
This time the photo is already developed and the photographer asks for a change. The current settings are already loaded; the first image is the current result, the second the original photo with the grid and numbered marks. Skip steps 1-2 above: the subject is whatever the request and the marks say.
- Change only what is asked. Keep the other colors, the area and the tone as they are unless they are in the way.
- Marks point at objects, not pixels. Name to yourself the object under each mark and its outline, then act on the whole object.
  keep (green ring): that whole object keeps its color.
  remove (red ring): that whole object goes black and white, even if it shares a hue with something kept.
  picked (cyan ring): the photographer picked a color there and nothing changed, usually because the object lies outside the area. Make that whole object keep its color.
- Tools for this: add or narrow kept colors; use exclude_color / set_excluded_color / remove_excluded_color for nearby unwanted hues; use adjust_area for Boundary and outward Feather while preserving all existing shapes and brush strokes. Use set_area only when changing the actual shapes; it replaces the whole area, so include all existing shapes and strokes you still want. Boundary 0 keeps the drawn interior fully opaque; Feather fades only outside that boundary. Preserve unrelated exclusions, boundary, feather and tone.
- The request may be in any language. Write subject, why and change in plain English.
- After each render the tool output lists every mark's keep weight with ok or NOT YET. Aim for all ok without changing the rest of the photo.
- Render at least once, then finish with change: one short sentence, under 12 words, on what you changed.
''';

final List<Map<String, dynamic>> editingTools = [
    _fn('probe', 'Measure OKLCh color at normalized points (median of a small patch).', {
      'points': {
        'type': 'array',
        'items': {'type': 'array', 'items': {'type': 'number'}, 'minItems': 2, 'maxItems': 2},
        'description': '[[x, y], ...] normalized 0-1',
      },
    }, ['points']),
    _fn('hue_histogram', 'Chroma-weighted hue histogram of the whole photo, strongest bins first.', {}, []),
    _fn('add_color', 'Keep a color, picked at a point of the photo or given as hex.', {
      'x': {'type': 'number'},
      'y': {'type': 'number'},
      'hex': {'type': 'string'},
      'width': {'type': 'number', 'description': 'hue degrees kept fully'},
      'softness': {'type': 'number', 'description': 'hue degrees of fade'},
      'chroma_min': {'type': 'number'},
      'lightness': {'type': 'array', 'items': {'type': 'number'}, 'description': '[low, high] OKLab L'},
    }, []),
    _fn('remove_color', 'Stop keeping a color.', {'index': {'type': 'integer'}}, ['index']),
    _fn('exclude_color', 'Subtract a color from all kept ranges. Sample an unwanted color; up to 3 exclusions. Nearby distinct kept samples protect their closer hues; exclusion wins for identical hues.', {
      'x': {'type': 'number', 'minimum': 0, 'maximum': 1},
      'y': {'type': 'number', 'minimum': 0, 'maximum': 1},
      'hex': {'type': 'string'},
      'width': {'type': 'number', 'minimum': 0, 'maximum': 60, 'description': 'Maximum full-exclusion hue radius before protection by nearer kept samples. Default 4.'},
      'softness': {'type': 'number', 'minimum': 0, 'maximum': 60, 'description': 'Edge fade in hue degrees. Default 4.'},
    }, []),
    _fn('set_excluded_color', 'Replace the sampled color or adjust Width and Edge of an existing exclusion. Unspecified values remain unchanged.', {
      'index': {'type': 'integer'},
      'x': {'type': 'number', 'minimum': 0, 'maximum': 1},
      'y': {'type': 'number', 'minimum': 0, 'maximum': 1},
      'hex': {'type': 'string'},
      'width': {'type': 'number', 'minimum': 0, 'maximum': 60},
      'softness': {'type': 'number', 'minimum': 0, 'maximum': 60},
    }, ['index']),
    _fn('remove_excluded_color', 'Remove an exclusion. The kept color ranges determine color again.', {'index': {'type': 'integer'}}, ['index']),
    _fn('set_width', 'Set width of a kept color.', {'index': {'type': 'integer'}, 'value': {'type': 'number'}},
        ['index', 'value']),
    _fn('set_softness', 'Set softness of a kept color.', {'index': {'type': 'integer'}, 'value': {'type': 'number'}},
        ['index', 'value']),
    _fn('set_gate', 'Set chroma_min and/or lightness gate of a kept color. lightness null removes it.', {
      'index': {'type': 'integer'},
      'chroma_min': {'type': 'number'},
      'lightness': {
        'type': ['array', 'null'],
        'items': {'type': 'number'},
      },
    }, ['index']),
    _fn('select_subject', 'Extract the object at a photo coordinate with on-device subject extraction, exactly like tapping Area. Render to inspect; use adjust_area afterward. No change on failure.', {
      'x': {'type': 'number', 'minimum': 0, 'maximum': 1},
      'y': {'type': 'number', 'minimum': 0, 'maximum': 1},
      'mode': {'type': 'string', 'enum': ['replace', 'add'], 'description': 'replace selects just this object; add preserves existing shapes/strokes. Default replace. Boundary/Feather are preserved; a new area starts with Boundary 0 and Feather 10 original-photo pixels.'},
    }, ['x', 'y']),
    _fn('set_area', 'Limit where color may stay. Empty lists clear the area.', {
      'polygons': {
        'type': 'array',
        'items': {
          'type': 'array',
          'items': {'type': 'array', 'items': {'type': 'number'}},
        },
        'description': '[[[x, y], ...], ...] normalized',
      },
      'ellipses': {
        'type': 'array',
        'items': {'type': 'array', 'items': {'type': 'number'}},
        'description': '[[cx, cy, rx, ry], ...] normalized',
      },
      'strokes': {
        'type': 'array',
        'items': {'type': 'object', 'properties': {
          'points': {'type': 'array', 'items': {'type': 'array', 'items': {'type': 'number'}}},
          'radius': {'type': 'number', 'description': 'brush radius as short-side fraction'},
          'erase': {'type': 'boolean'},
        }, 'required': ['points', 'radius']},
        'description': 'Ordered Add/Erase brush strokes, same as the human brush. Preserve existing strokes when replacing the area.',
      },
      'edge': {'type': 'number', 'description': 'outward fade width as fraction of the short side; omit to preserve existing Feather or default to 10 original-photo pixels'},
      'boundary': {'type': 'number', 'minimum': -1, 'maximum': 1, 'description': 'offset of full-opacity boundary, fraction of short side; default 0'},
    }, []),
    _fn('adjust_area', 'Move the full-opacity boundary or change outward feather without replacing existing shapes and strokes. Same as Boundary and Feather in Area. Use *_px for original-photo pixel requests, or fractions; never both for one adjustment.', {
      'boundary_px': {'type': 'number', 'description': 'Signed original-photo pixels; 0 keeps drawn interior at 100%, positive expands, negative contracts.'},
      'feather_px': {'type': 'number', 'minimum': 0, 'description': 'Original-photo pixels from full opacity to zero, outside the Boundary.'},
      'boundary': {'type': 'number', 'minimum': -1, 'maximum': 1, 'description': 'Signed short-side fraction: positive expands, negative contracts, zero keeps the drawn interior fully opaque.'},
      'edge': {'type': 'number', 'minimum': 0, 'maximum': 1, 'description': 'Fade width outside the full-opacity boundary, as short-side fraction.'},
    }, []),
    _fn('set_crop', 'Crop and rotate, same as the human Crop tool. rect is [left,top,right,bottom] normalized in the frame AFTER clockwise quarter turns and straightening. Each side must retain at least 5%. angle is clockwise degrees -45..45, auto-zoomed to avoid blank corners. All sampling, Area and focus coordinates remain in the original source frame. Preserve crop unless asked.', {
      'rect': {'type': 'array', 'items': {'type': 'number'}, 'minItems': 4, 'maxItems': 4},
      'turns': {'type': 'integer', 'minimum': 0, 'maximum': 3},
      'angle': {'type': 'number', 'minimum': -45, 'maximum': 45},
      'reset': {'type': 'boolean'},
    }, []),
    _fn('set_saturation', 'Adjust the saturation of kept colors only. Same as Tone > Saturation. 0 removes kept chroma, 1 preserves source, 2 doubles it. Does not change selection or the monochrome atmosphere.', {'value': {'type': 'number', 'minimum': 0, 'maximum': 2}}, ['value']),
    _fn('set_mono_tone', 'Tone of the black-and-white part.', {
      'contrast': {'type': 'number', 'description': '-0.3 to 0.4. Default 0.1.'},
      'atmosphere': {
        'type': 'number',
        'description': '0 to 1. How much of the light\'s color the black-and-white part keeps as a faint tint. Default 0.2.',
      },
      'vignette': {
        'type': 'number',
        'description': '0 to 1. How dark the edges get, as in Photos. Default 0.',
      },
      'vignette_radius': {
        'type': 'number',
        'description': '0.3 to 1.3. Where the darkening is half way, from the center (corners are 1). Smaller reaches further in. Default 0.8.',
      },
    }, []),
    _fn('render', 'Render with the current settings and look at the result.', {}, []),
    _fn('finish', 'Finish developing.', {
      'subject': {'type': 'string'},
      'why': {'type': 'string'},
      'focus': {'type': 'array', 'items': {'type': 'number'}},
      'change': {'type': 'string', 'description': 'Only when revising: what you changed, one short sentence.'},
    }, ['subject', 'why']),
  ];

Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, List<String> req) => {
        'name': name,
        'description': desc,
        'parameters': {'type': 'object', 'properties': props, 'required': req},
      };

