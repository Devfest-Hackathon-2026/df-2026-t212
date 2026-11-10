import 'dart:convert';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../core/recipe.dart';
import '../core/renderer.dart';
import 'agent.dart';

/// Agent backed by the OpenAI Responses API with function tools.
///
/// The product targets Gemini; this is a stand-in with the same tool set, so
/// swapping the model provider does not change the app.
class OpenAIAgent implements DevelopAgent {
  OpenAIAgent({
    required this.apiKey,
    required this.model,
    this.judgeModel = 'gpt-6-luna',
    this.maxRenders = 4,
    this.maxTurns = 14,
  });

  final String apiKey;
  final String model;

  /// Small, cheap model that decides which photos are worth [model].
  final String judgeModel;
  final int maxRenders;
  final int maxTurns;

  @override
  String get name => model;

  static const _instructions = '''
You develop photos for After Hue. Everything in a photo turns black and white except the colors of its subject.
The pixels are made by a deterministic renderer; you only choose its settings with the tools. Never describe edits you did not make with tools.

How the renderer keeps color
- Colors are compared in OKLCh. L is lightness 0-1, C is chroma (0 is grey, 0.1 is clearly colored, 0.2 is vivid), H is hue in degrees.
- Each kept color keeps hues within `width` degrees of it at full strength, then fades to mono over `softness` more degrees. Nothing is cut at 0 or 1.
- Near-grey pixels have unreliable hue, so color fades in with chroma above `chroma_min`.
- Optional gates: `chroma_min` and `lightness` [low, high] separate a distractor that shares a hue but differs in chroma or lightness (skin vs strawberry, floor vs pink paint).
- `set_area` limits where color may stay, with a soft edge. Use it when the same color exists outside the subject.

How to work
1. Look at the photo. The yellow grid labels are normalized coordinates (x to the right, y down). Decide the subject: what the photographer pointed the camera at.
2. Decide the subject's palette. Keep the colors that make the subject what it is. A single-colored object keeps one color. A painted or multi-colored object keeps its palette (a blue and pink painted piano keeps both). Food keeps what makes it look good (a strawberry crepe keeps the strawberries and the golden crepe). 1 to 3 colors.
3. Measure before deciding. Use `probe` on the subject's colors AND on nearby things of similar color (distractors). Use `hue_histogram` for an overview.
4. add_color at a point on the subject (or by hex). Choose width and softness so subject hues are inside and distractor hues fall outside. Typical: width 8-18, softness 6-16.
5. If a distractor shares the hue, try gates first, then set_area: a polygon or ellipses around the subject, edge 0.01-0.04 of the short side. Fit the area closely; a loose area leaks the background's color.
6. render. Look at the result and the weight map. Fix blotches of color on the background, color bleeding onto skin, floors or walls, and parts of the subject that went grey. Re-render. At most $_maxRendersText renders.
7. finish with: subject (2-5 plain English words), why (one or two plain sentences about which colors you kept and what you excluded), focus ([x, y] center of the subject).

Atmosphere: set_mono_tone atmosphere keeps the light's color as a faint tint in the black-and-white part. Raise it (0.6-0.9) for warm evening light, dusk, night, or rain where the light is the mood; lower it (0-0.2) for a hard graphic look or when a tint would compete with the kept color. Leave it at 0.4 otherwise. Vignette (0.2-0.5) gently draws the eye to a central subject in a busy or bright frame; leave it at 0 when the subject is near an edge. vignette_radius sets where it starts: keep 0.8, or 1.0-1.2 to touch only the corners of a wide scene.

Already-accented photos still get developed. If no subject stands out, keep the most meaningful color anyway.
''';

  static const _maxRendersText = 'four';

  /// Added for a revision: the photo is already developed and the person
  /// asks for a change, in words, with marks, or both.
  static const _revising = '''

Revising
This time the photo is already developed and the photographer asks for a change. The current settings are already loaded; the first image is the current result, the second the original photo with the grid and numbered marks. Skip steps 1-2 above: the subject is whatever the request and the marks say.
- Change only what is asked. Keep the other colors, the area and the tone as they are unless they are in the way.
- Marks point at objects, not pixels. Name to yourself the object under each mark and its outline, then act on the whole object.
  keep (green ring): that whole object keeps its color.
  remove (red ring): that whole object goes black and white, even if it shares a hue with something kept.
  picked (cyan ring): the photographer picked a color there and nothing changed, usually because the object lies outside the area. Make that whole object keep its color.
- Tools for this: add or narrow colors, gates (lightness, chroma_min) to split objects that share a hue, and set_area. set_area replaces the whole area, so include the existing shapes you still want. Fit the area to the objects that keep color; whatever lies outside goes black and white.
- The request may be in any language. Write subject, why and change in plain English.
- After each render the tool output lists every mark's keep weight with ok or NOT YET. Aim for all ok without changing the rest of the photo.
- Render at least once, then finish with change: one short sentence, under 12 words, on what you changed.
''';

  static final List<Map<String, dynamic>> _tools = [
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
      'edge': {'type': 'number', 'description': 'feather as fraction of the short side'},
    }, []),
    _fn('set_mono_tone', 'Tone of the black-and-white part.', {
      'contrast': {'type': 'number', 'description': '-0.3 to 0.4. Default 0.1.'},
      'atmosphere': {
        'type': 'number',
        'description': '0 to 1. How much of the light\'s color the black-and-white part keeps as a faint tint. Default 0.4.',
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

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, List<String> req) => {
        'type': 'function',
        'name': name,
        'description': desc,
        'parameters': {'type': 'object', 'properties': props, 'required': req},
      };

  Future<Map<String, dynamic>> _call(Map<String, dynamic> body) async {
    final res = await http
        .post(
          Uri.parse('https://api.openai.com/v1/responses'),
          headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 120));
    if (res.statusCode != 200) {
      throw AgentError('OpenAI ${res.statusCode}: ${res.body.length > 300 ? res.body.substring(0, 300) : res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }


  @override
  Future<Verdict> judge(Rgba photo) async {
    final jpeg = await plainJpeg(photo);
    final res = await _call({
      'model': judgeModel,
      'instructions': judgeInstructions,
      'reasoning': {'effort': 'low'},
      'input': [
        {
          'role': 'user',
          'content': [
            {'type': 'input_image', 'image_url': dataUrl(jpeg), 'detail': 'low'},
          ],
        },
      ],
      'text': {
        'format': {
          'type': 'json_schema',
          'name': 'verdict',
          'strict': true,
          'schema': {
            'type': 'object',
            'additionalProperties': false,
            'properties': {
              'develop': {'type': 'boolean'},
              'subject': {'type': 'string'},
              'reason': {'type': 'string'},
            },
            'required': ['develop', 'subject', 'reason'],
          },
        },
      },
    });
    final text = (res['output'] as List)
        .cast<Map<String, dynamic>>()
        .where((o) => o['type'] == 'message')
        .expand((o) => (o['content'] as List).cast<Map<String, dynamic>>())
        .where((c) => c['type'] == 'output_text')
        .map((c) => c['text'] as String)
        .join();
    final j = jsonDecode(text) as Map<String, dynamic>;
    return Verdict(j['develop'] as bool, subject: j['subject'] as String?, reason: j['reason'] as String?);
  }

  // Static so the isolate closure captures only the photo.
  static Future<EditSession> _session(Rgba photo, {Recipe? start, List<Mark> marks = const []}) =>
      Isolate.run(() => EditSession(photo, start: start, marks: marks));

  @override
  Future<Recipe> develop(Rgba photo, {void Function(String)? log, AgentRun? run}) async {
    Future<T> g<T>(Future<T> f) => run == null ? f : run.guard(f);
    final session = await g(_session(photo));
    final first = await g(gridJpeg(photo));
    var input = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': 'Develop this photo. It is ${photo.width}x${photo.height}.'},
          {'type': 'input_image', 'image_url': dataUrl(first)},
        ],
      },
    ];
    await _work(session, input, _instructions, log: log, run: run);
    if (session.recipe.colors.isEmpty) throw AgentError('agent kept no color');
    return session.recipe;
  }

  @override
  Future<Recipe> revise(Rgba photo, Recipe current, Revision request, {void Function(String)? log, AgentRun? run}) async {
    Future<T> g<T>(Future<T> f) => run == null ? f : run.guard(f);
    final session = await g(_session(photo, start: current, marks: request.marks));
    // Where things stand, without spending one of the agent's renders.
    await g(session.renderAsync(count: false));
    final now = session.last!;
    final marked = await g(gridJpeg(photo, marks: request.marks));
    final text = request.text?.trim();
    String where(Mark m) => '(${m.x.toStringAsFixed(2)}, ${m.y.toStringAsFixed(2)})';
    final marks = [
      for (var k = 0; k < request.marks.length; k++)
        () {
          final m = request.marks[k];
          return switch (m.intent) {
            MarkIntent.keep => '#${k + 1} keep at ${where(m)}: the object there keeps its color.',
            MarkIntent.remove => '#${k + 1} remove at ${where(m)}: the object there goes black and white.',
            MarkIntent.picked => '#${k + 1} picked at ${where(m)}, color '
                '${m.color == null ? '?' : oklabToHex(m.color!.l, m.color!.a, m.color!.b)}: '
                'the photographer picked this color here and nothing changed. The object there should keep its color.',
          };
        }(),
    ];
    final input = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': [
          {
            'type': 'input_text',
            'text': [
              'Revise this development. The photo is ${photo.width}x${photo.height}.',
              'Request: ${text == null || text.isEmpty ? '(no words; follow the marks)' : '"$text"'}',
              if (marks.isNotEmpty) 'Marks:\n${marks.join('\n')}',
              'Current settings: ${jsonEncode(current.toJson())}',
              if (marks.isNotEmpty) 'Marks now: ${session.markReport()}',
            ].join('\n\n'),
          },
          {'type': 'input_image', 'image_url': dataUrl(await g(plainJpeg(now.image)))},
          {'type': 'input_image', 'image_url': dataUrl(marked)},
        ],
      },
    ];
    await _work(session, input, _instructions + _revising, log: log, run: run);
    if (session.recipe.colors.isEmpty) throw AgentError('agent kept no color');
    run?.note = session.change;
    return session.recipe;
  }

  /// The tool loop shared by [develop] and [revise].
  Future<void> _work(EditSession session, List<Map<String, dynamic>> input, String instructions,
      {void Function(String)? log, AgentRun? run}) async {
    Future<T> g<T>(Future<T> f) => run == null ? f : run.guard(f);
    final photo = session.photo;
    String? previous;

    for (var turn = 0; turn < maxTurns && !session.finished; turn++) {
      final res = await g(_call({
        'model': model,
        'instructions': instructions,
        'input': input,
        'tools': _tools,
        if (previous != null) 'previous_response_id': previous,
      }));
      previous = res['id'] as String;
      final calls = (res['output'] as List).cast<Map<String, dynamic>>().where((o) => o['type'] == 'function_call');
      if (calls.isEmpty) {
        input = [
          {'role': 'user', 'content': 'Use the tools. Call finish when the result is good.'},
        ];
        continue;
      }
      input = [];
      var rendered = false;
      for (final c in calls) {
        final name = c['name'] as String;
        Map<String, dynamic> args;
        try {
          args = (jsonDecode(c['arguments'] as String? ?? '{}') as Map).cast<String, dynamic>();
        } catch (_) {
          args = {};
        }
        String out;
        if (name == 'render' && session.renders >= maxRenders) {
          out = 'error: render limit reached. Call finish.';
        } else {
          try {
            out = name == 'render' ? await g(session.renderAsync()) : session.execute(name, args);
          } on AgentCancelled {
            rethrow;
          } catch (e) {
            out = 'error: $e';
          }
        }
        if (name == 'render' && !out.startsWith('error')) rendered = true;
        run?.emit(session.recipe, name);
        log?.call('$name ${c['arguments']} -> ${out.split('\n').first}');
        input.add({'type': 'function_call_output', 'call_id': c['call_id'], 'output': out});
      }
      if (rendered && session.last != null) {
        final r = session.last!;
        input.add({
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'Result, then keep-weight map.'},
            {'type': 'input_image', 'image_url': dataUrl(await g(plainJpeg(r.image)))},
            {'type': 'input_image', 'image_url': dataUrl(await g(plainJpeg(weightImage(r.weight, photo.width, photo.height))))},
          ],
        });
      }
    }
  }
}
