import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/recipe.dart';
import '../core/renderer.dart';
import 'agent.dart';
import 'editing_contract.dart';

/// Gemini's native content/tool protocol through our Cloud Run service.
/// Google credentials and the selected Vertex model stay on the server.
class GeminiAgent implements DevelopAgent {
  GeminiAgent({required this.baseUrl, required this.tokenProvider,
    this.maxRenders = 4, this.maxTurns = 14, this.subjectExtractor, this.allowed,
    this.requestTimeout = const Duration(seconds: 120)});
  final String baseUrl;
  final Future<String> Function({bool forceRefresh}) tokenProvider;
  final int maxRenders, maxTurns;
  final SubjectExtractor? subjectExtractor;
  final bool Function()? allowed;
  final Duration requestTimeout;
  @override String get name => 'Gemini on Google Cloud';

  Future<Map<String, dynamic>> _call(Map<String, dynamic> body, {AgentRun? run}) async {
    if (run?.cancelled ?? false) throw AgentCancelled();
    if (allowed != null && !allowed!()) throw AgentError('Enable Cloud AI in Settings to use this feature.');
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasAuthority || uri.scheme != 'https') {
      throw AgentError('Ask is not configured. Connect the Google Cloud agent to use it.');
    }
    final client = http.Client();
    final abort = Completer<void>();
    final cancelled = run?.whenCancelled;
    if (cancelled != null) unawaited(cancelled.then((_) { if (!abort.isCompleted) abort.complete(); }));
    try {
      final endpoint = '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/v1/generate';
      final encodedBody = jsonEncode(body);
      Future<String> getToken({bool forceRefresh = false}) {
        final future = tokenProvider(forceRefresh: forceRefresh);
        return run == null ? future : run.guard(future);
      }
      Future<http.Response> send(String token) {
        if (run?.cancelled ?? false) throw AgentCancelled();
        if (allowed != null && !allowed!()) throw AgentError('Enable Cloud AI in Settings to use this feature.');
        final request = http.AbortableRequest('POST', Uri.parse(endpoint), abortTrigger: abort.future)
          ..headers.addAll({'Authorization': 'Bearer $token', 'Content-Type': 'application/json'})
          ..body = encodedBody;
        final response = client.send(request).then(http.Response.fromStream);
        return run == null ? response : run.guard(response);
      }
      Future<http.Response> call() async {
        final token = await getToken();
        var response = await send(token);
        if (response.statusCode == 401) {
          final refreshed = await getToken(forceRefresh: true);
          response = await send(refreshed);
        }
        return response;
      }
      final res = await call().timeout(requestTimeout);
      if (res.statusCode != 200) {
        // Read only a bounded, known error code. Never display upstream text,
        // which could contain credentials or private request details.
        String? code;
        if (res.bodyBytes.length <= 8192) {
          try {
            final decoded = jsonDecode(res.body);
            if (decoded is Map && decoded['error'] is Map) {
              final candidate = (decoded['error'] as Map)['code'];
              if (candidate is String) code = candidate;
            }
          } catch (_) { /* Fall back to a status-based message. */ }
        }
        final message = switch ((res.statusCode, code)) {
          (429, 'daily_limit_reached') => 'Cloud AI has reached its daily service limit. Please try again after the daily reset.',
          (429, 'user_daily_limit_reached') => 'You have reached your daily Cloud AI limit. Please try again after the daily reset.',
          (429, 'rate_limited') => 'Too many Cloud AI requests. Please wait a moment and try again.',
          (503, 'quota_unavailable') => 'Cloud AI cannot check its usage limits. Please try again later; contact the developer if this continues.',
          (401 || 403, _) => 'Google Cloud AI could not authorize this app. Check its AI configuration.',
          (429, _) => 'Google Cloud AI is busy. Please try again shortly.',
          (400 || 413, _) => 'Google Cloud AI could not read this photo or edit request. Please try again.',
          _ => 'Google Cloud AI is temporarily unavailable. Please try again.',
        };
        throw AgentError(message);
      }
      try { return jsonDecode(res.body) as Map<String, dynamic>; }
      catch (_) { throw AgentError('Google Cloud AI returned an unreadable response. Please try again.'); }
    } on AgentCancelled { rethrow; }
    on http.RequestAbortedException { throw AgentCancelled(); }
    on TimeoutException { throw AgentError('Google Cloud AI timed out. Please try again.'); }
    on http.ClientException {
      if (run?.cancelled ?? false) throw AgentCancelled();
      throw AgentError('Could not connect to Google Cloud AI. Check your connection and try again.');
    } finally {
      if (!abort.isCompleted) abort.complete();
      client.close();
    }
  }

  static Map<String, dynamic> _content(Map<String, dynamic> response) {
    final candidates = response['candidates'];
    if (candidates is! List || candidates.isEmpty || candidates.first is! Map) {
      throw AgentError('Google Cloud AI did not return an edit. Please try another request.');
    }
    final candidate = candidates.first as Map;
    final finish = candidate['finishReason'];
    if (finish != null && finish != 'STOP') {
      throw AgentError(finish == 'MAX_TOKENS'
        ? 'The agent could not finish this step. Please try a simpler request.'
        : 'Google Cloud AI could not complete this request. Try another photo or description.');
    }
    final content = candidate['content'];
    if (content is! Map || content['parts'] is! List) {
      throw AgentError('Google Cloud AI returned an incomplete edit. Please try again.');
    }
    return Map<String, dynamic>.from(content);
  }
  static Map<String, dynamic> _image(Uint8List bytes) => {'inlineData': {'mimeType': 'image/jpeg', 'data': base64Encode(bytes)}};
  static Map<String, dynamic> _text(String text) => {'text': text};
  static Map<String, dynamic> _system(String text) => {'parts': [_text(text)]};
  static Map<String, dynamic> _user(List<Map<String, dynamic>> parts) => {'role': 'user', 'parts': parts};

  @override Future<Verdict> judge(Rgba photo, {AgentRun? run}) async {
    Future<T> g<T>(Future<T> f) => run == null ? f : run.guard(f);
    final jpeg = await g(plainJpeg(photo));
    final result = await _call({
      'purpose': 'judge', 'systemInstruction': _system(judgeInstructions),
      'contents': [_user([_image(jpeg)])],
      'generationConfig': {
        'maxOutputTokens': 2048, 'responseMimeType': 'application/json',
        'responseSchema': {'type': 'OBJECT', 'properties': {
          'develop': {'type': 'BOOLEAN'}, 'subject': {'type': 'STRING'}, 'reason': {'type': 'STRING'},
        }, 'required': ['develop', 'subject', 'reason']},
      },
    }, run: run);
    final parts = _content(result)['parts'] as List;
    final text = parts.whereType<Map>().where((p) => p['thought'] != true && p['text'] is String).map((p) => p['text']).join();
    try {
      final data = jsonDecode(text) as Map<String, dynamic>;
      return Verdict(data['develop'] as bool, subject: data['subject'] as String?, reason: data['reason'] as String?);
    } catch (_) { throw AgentError('Google Cloud AI returned an incomplete photo assessment.'); }
  }

  static Future<EditSession> _session(Rgba photo, {Recipe? start,
    List<Mark> marks = const [], ({int width, int height})? originalSize}) =>
    Isolate.run(() => EditSession(photo, start: start, marks: marks, originalSize: originalSize));

  @override Future<Recipe> develop(Rgba photo, {void Function(String)? log, AgentRun? run,
    ({int width, int height})? originalSize}) async {
    Future<T> g<T>(Future<T> f) => run == null ? f : run.guard(f);
    final session = await g(_session(photo, originalSize: originalSize));
    session.subjectExtractor = subjectExtractor;
    final first = await g(gridJpeg(photo));
    final contents = [_user([_text('Develop this photo. ${session.sizeDescription}'), _image(first)])];
    await _work(session, contents, developmentInstructions(maxRenders), log: log, run: run);
    if (session.recipe.colors.isEmpty) throw AgentError('The agent kept no color. Please try again.');
    return session.recipe;
  }

  @override Future<Recipe> revise(Rgba photo, Recipe current, Revision request,
    {void Function(String)? log, AgentRun? run, ({int width, int height})? originalSize}) async {
    Future<T> g<T>(Future<T> f) => run == null ? f : run.guard(f);
    final session = await g(_session(photo, start: current, marks: request.marks, originalSize: originalSize));
    session.subjectExtractor = subjectExtractor;
    await g(session.renderAsync(count: false));
    final currentImage = await g(plainJpeg(session.last!.image));
    final marked = await g(gridJpeg(photo, marks: request.marks));
    final text = request.text?.trim();
    String where(Mark m) => '(${m.x.toStringAsFixed(2)}, ${m.y.toStringAsFixed(2)})';
    final marks = [for (var k = 0; k < request.marks.length; k++) () {
      final m = request.marks[k];
      return switch (m.intent) {
        MarkIntent.keep => '#${k + 1} keep at ${where(m)}: the object there keeps its color.',
        MarkIntent.remove => '#${k + 1} remove at ${where(m)}: the object there goes black and white.',
        MarkIntent.picked => '#${k + 1} picked at ${where(m)}, color ${m.color == null ? '?' : oklabToHex(m.color!.l, m.color!.a, m.color!.b)}: the photographer picked this color here and nothing changed. The object there should keep its color.',
      };
    }()];
    final description = [
      'Revise this development. ${session.sizeDescription}',
      'Request: ${text == null || text.isEmpty ? '(no words; follow the marks)' : '"$text"'}',
      if (marks.isNotEmpty) 'Marks:\n${marks.join('\n')}',
      'Current settings: ${jsonEncode(current.toJson())}',
      if (marks.isNotEmpty) 'Marks now: ${session.markReport()}',
    ].join('\n\n');
    final contents = [_user([_text(description), _image(currentImage), _image(marked)])];
    await _work(session, contents, developmentInstructions(maxRenders) + revisionInstructions, log: log, run: run);
    if (session.recipe.colors.isEmpty) throw AgentError('The agent kept no color. Please try again.');
    run?.note = session.change;
    return session.recipe;
  }

  Future<void> _work(EditSession session, List<Map<String, dynamic>> contents, String instructions,
    {void Function(String)? log, AgentRun? run}) async {
    Future<T> g<T>(Future<T> f) => run == null ? f : run.guard(f);
    for (var turn = 0; turn < maxTurns && !session.finished; turn++) {
      if (run?.cancelled ?? false) throw AgentCancelled();
      final response = await _call({
        'purpose': 'develop', 'systemInstruction': _system(instructions),
        'contents': contents,
        'tools': [{'functionDeclarations': editingTools.map((tool) => {
          'name': tool['name'], 'description': tool['description'], 'parametersJsonSchema': tool['parameters'],
        }).toList()}],
        'generationConfig': {'maxOutputTokens': 8192},
      }, run: run);
      final modelContent = _content(response);
      // Preserve every original part and its thoughtSignature verbatim. Do not
      // rebuild/merge text and function calls or strip unfamiliar model fields.
      contents.add(modelContent);
      final calls = (modelContent['parts'] as List).whereType<Map>().where((p) => p['functionCall'] is Map).map((p) => p['functionCall'] as Map).toList();
      if (calls.isEmpty) {
        contents.add(_user([_text('Use the tools. Call finish when the result is good.')]));
        continue;
      }
      final results = <Map<String, dynamic>>[];
      var rendered = false;
      for (final call in calls) {
        if (run?.cancelled ?? false) throw AgentCancelled();
        final name = call['name'] as String? ?? '';
        final args = call['args'] is Map ? Map<String, dynamic>.from(call['args'] as Map) : <String, dynamic>{};
        String out;
        if (session.finished) {
          out = 'error: the edit is already finished.';
        } else if (name == 'render' && session.renders >= maxRenders) {
          out = 'error: render limit reached. Call finish.';
        } else {
          try {
            out = name == 'render' ? await g(session.renderAsync())
              : name == 'select_subject' ? await g(session.selectSubject(args))
              : session.execute(name, args);
          } on AgentCancelled { rethrow; }
          catch (e) { out = 'error: $e'; }
        }
        if (name == 'render' && !out.startsWith('error:')) rendered = true;
        run?.emit(session.recipe, name);
        log?.call('$name ${jsonEncode(args)} -> ${out.split('\n').first}');
        results.add({'functionResponse': {
          'name': name, if (call['id'] != null) 'id': call['id'], 'response': {'result': out},
        }});
      }
      // Parallel model calls are followed by every matching response in the
      // original order, before any new model turn.
      contents.add(_user(results));
      if (rendered && session.last != null) {
        final result = session.last!;
        // Vertex rejects a user content mixing functionResponse and images
        // with "Requests ending with a model turn are not supported". Keep
        // the complete tool response turn, then send previews as a separate
        // user content. Signed model parts above remain entirely unchanged.
        contents.add(_user([_text('Result, then keep-weight map.'),
          _image(await g(plainJpeg(result.image))),
          _image(await g(plainJpeg(weightImage(result.weight, session.photo.width, session.photo.height)))),
        ]));
      }
    }
    if (!session.finished) throw AgentError('The agent did not finish the edit. Please try again.');
  }
}
