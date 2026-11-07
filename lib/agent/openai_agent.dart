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
  OpenAIAgent({required this.apiKey, required this.model, this.maxRenders = 4, this.maxTurns = 14});

  final String apiKey;
  final String model;
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

Already-accented photos still get developed. If no subject stands out, keep the most meaningful color anyway.
''';

  static const _maxRendersText = 'four';

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
    _fn('set_mono_tone', 'Contrast of the black-and-white part, -0.3 to 0.4. Default 0.1.',
        {'contrast': {'type': 'number'}}, ['contrast']),
    _fn('render', 'Render with the current settings and look at the result.', {}, []),
    _fn('finish', 'Finish developing.', {
      'subject': {'type': 'string'},
      'why': {'type': 'string'},
      'focus': {'type': 'array', 'items': {'type': 'number'}},
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

  // Static so the isolate closure captures only the photo.
  static Future<EditSession> _session(Rgba photo) => Isolate.run(() => EditSession(photo));

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
    String? previous;

    for (var turn = 0; turn < maxTurns && !session.finished; turn++) {
      final res = await g(_call({
        'model': model,
        'instructions': _instructions,
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
    if (session.recipe.colors.isEmpty) throw AgentError('agent kept no color');
    return session.recipe;
  }
}

class AgentError implements Exception {
  AgentError(this.message);
  final String message;
  @override
  String toString() => message;
}
