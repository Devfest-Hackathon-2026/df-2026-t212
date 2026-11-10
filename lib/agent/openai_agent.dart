import 'dart:convert';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../core/recipe.dart';
import '../core/renderer.dart';
import 'agent.dart';
import 'editing_contract.dart';

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
    this.subjectExtractor,
  });

  final SubjectExtractor? subjectExtractor;
  final String apiKey;
  final String model;

  /// Small, cheap model that decides which photos are worth [model].
  final String judgeModel;
  final int maxRenders;
  final int maxTurns;

  @override
  String get name => model;

  Future<Map<String, dynamic>> _call(Map<String, dynamic> body, {AgentRun? run}) async {
    if (run?.cancelled ?? false) throw AgentCancelled();
    final client = http.Client();
    try {
      final request = http.AbortableRequest('POST', Uri.parse('https://api.openai.com/v1/responses'),
          abortTrigger: run?.whenCancelled)
        ..headers.addAll({'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'})
        ..body = jsonEncode(body);
      final response = client.send(request).then(http.Response.fromStream);
      final res = await (run == null ? response : run.guard(response)).timeout(const Duration(seconds: 120));
      if (res.statusCode != 200) {
        throw AgentError('OpenAI ${res.statusCode}: ${res.body.length > 300 ? res.body.substring(0, 300) : res.body}');
      }
      return jsonDecode(res.body) as Map<String, dynamic>;
    } on http.RequestAbortedException {
      throw AgentCancelled();
    } finally {
      client.close();
    }
  }


  @override
  Future<Verdict> judge(Rgba photo, {AgentRun? run}) async {
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
    }, run: run);
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
  static Future<EditSession> _session(Rgba photo, {Recipe? start, List<Mark> marks = const [], ({int width, int height})? originalSize}) =>
      Isolate.run(() => EditSession(photo, start: start, marks: marks, originalSize: originalSize));

  @override
  Future<Recipe> develop(Rgba photo, {void Function(String)? log, AgentRun? run, ({int width, int height})? originalSize}) async {
    Future<T> g<T>(Future<T> f) => run == null ? f : run.guard(f);
    final session = await g(_session(photo, originalSize: originalSize));
    session.subjectExtractor = subjectExtractor;
    final first = await g(gridJpeg(photo));
    var input = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': 'Develop this photo. ${session.sizeDescription}'},
          {'type': 'input_image', 'image_url': dataUrl(first)},
        ],
      },
    ];
    await _work(session, input, developmentInstructions(maxRenders), log: log, run: run);
    if (session.recipe.colors.isEmpty) throw AgentError('agent kept no color');
    return session.recipe;
  }

  @override
  Future<Recipe> revise(Rgba photo, Recipe current, Revision request, {void Function(String)? log, AgentRun? run, ({int width, int height})? originalSize}) async {
    Future<T> g<T>(Future<T> f) => run == null ? f : run.guard(f);
    final session = await g(_session(photo, start: current, marks: request.marks, originalSize: originalSize));
    session.subjectExtractor = subjectExtractor;
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
              'Revise this development. ${session.sizeDescription}',
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
    await _work(session, input, developmentInstructions(maxRenders) + revisionInstructions, log: log, run: run);
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
        'tools': editingTools.map((tool) => {'type': 'function', 'strict': false, ...tool}).toList(),
        'previous_response_id': ?previous,
      }, run: run));
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
            out = name == 'render' ? await g(session.renderAsync()) : name == 'select_subject' ? await g(session.selectSubject(args)) : session.execute(name, args);
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
    if (!session.finished) throw AgentError('The agent did not finish the edit. Please try again.');
  }
}
