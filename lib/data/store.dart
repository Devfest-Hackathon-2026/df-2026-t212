import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../agent/agent.dart';
import '../agent/apple_judge.dart';
import '../agent/openai_agent.dart';
import '../core/recipe.dart';
import '../core/renderer.dart';
import 'photo_source.dart';

/// [manual]: the person develops it by hand; the agent leaves it alone.
enum Develop { pending, developing, done, failed, manual }

class PhotoItem {
  PhotoItem({
    required this.id,
    required this.taken,
    this.lat,
    this.lng,
    required this.width,
    required this.height,
    this.edit,
    this.auto,
    this.state = Develop.pending,
    this.favorite = false,
    this.seen = false,
    this.attempts = 0,
    this.copyOf,
    this.judged = false,
    this.note,
    this.picked = false,
    this.asked = false,
    this.sceneOf,
  });

  /// Library asset id. Duplicates share the asset and differ in [key].
  final String id;
  final String? copyOf;
  String get key => copyOf == null ? id : '$id#$copyOf';

  final DateTime taken;
  final double? lat, lng;
  final int width, height;

  Recipe? edit;

  /// What the agent proposed, for "Auto".
  Recipe? auto;
  Develop state;
  bool favorite;
  bool seen;
  int attempts;

  /// The agent has looked at it and decided whether to develop it.
  bool judged;

  /// Why the agent left it for a person.
  String? note;

  /// The person chose this photo (imported, took it over, or pressed Auto).
  bool picked;

  /// Queued by "Develop more": still judged, but outside the daily limit.
  bool asked;

  /// Key of the photo that stands for this one's scene. The agent develops
  /// that one; its edit is applied here.
  String? sceneOf;

  /// In the library. Photos the agent was not going to develop on its own
  /// stay out until a person picks them.
  bool get shown => switch (state) {
        Develop.done => hues.isNotEmpty,
        Develop.pending || Develop.developing => true,
        Develop.manual => picked || hues.isNotEmpty,
        Develop.failed => false,
      };

  bool get hasLocation => lat != null && lng != null;
  List<KeptColor> get hues => edit?.colors ?? const [];

  Map<String, dynamic> toJson() => {
        'id': id,
        if (copyOf != null) 'copyOf': copyOf,
        'taken': taken.millisecondsSinceEpoch,
        'lat': lat,
        'lng': lng,
        'w': width,
        'h': height,
        if (edit != null) 'edit': edit!.toJson(),
        if (auto != null) 'auto': auto!.toJson(),
        'state': state == Develop.developing ? Develop.pending.name : state.name,
        'favorite': favorite,
        'seen': seen,
        'attempts': attempts,
        if (judged) 'judged': true,
        if (note != null) 'note': note,
        if (picked) 'picked': true,
        if (asked) 'asked': true,
        if (sceneOf != null) 'sceneOf': sceneOf,
      };

  factory PhotoItem.fromJson(Map<String, dynamic> j) => PhotoItem(
        id: j['id'] as String,
        copyOf: j['copyOf'] as String?,
        taken: DateTime.fromMillisecondsSinceEpoch(j['taken'] as int),
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        width: j['w'] as int,
        height: j['h'] as int,
        edit: j['edit'] == null ? null : Recipe.fromJson(j['edit'] as Map<String, dynamic>),
        auto: j['auto'] == null ? null : Recipe.fromJson(j['auto'] as Map<String, dynamic>),
        state: Develop.values.byName(j['state'] as String),
        favorite: j['favorite'] as bool? ?? false,
        seen: j['seen'] as bool? ?? false,
        attempts: j['attempts'] as int? ?? 0,
        judged: j['judged'] as bool? ?? false,
        note: j['note'] as String?,
        picked: j['picked'] as bool? ?? false,
        asked: j['asked'] as bool? ?? false,
        sceneOf: j['sceneOf'] as String?,
      );
}

/// A group of similar kept colors, made only from what the user collected.
class PaletteEntry {
  PaletteEntry(this.color, this.keys, this.source);
  final KeptColor color;
  final Set<String> keys;

  /// The photo this color was first seen in; its swatch is cut from there.
  final PhotoItem source;
  double get hue => color.hue;
}

enum SortMode { time, hue }

enum SwatchStyle { photo, soft, flat }

/// App state. One instance, shared by Photos and Map.
class Store extends ChangeNotifier {
  Store._();
  static final Store instance = Store._();

  static const _apiKey = String.fromEnvironment('OPENAI_API_KEY');
  static const _model = String.fromEnvironment('OPENAI_MODEL', defaultValue: 'gpt-6.1-terra');
  static const _judgeModel = String.fromEnvironment('OPENAI_JUDGE_MODEL', defaultValue: 'gpt-6-luna');

  late final DevelopAgent agent = _apiKey.isEmpty
      ? LocalAgent()
      : OpenAIAgent(apiKey: _apiKey, model: _model, judgeModel: _judgeModel);
  final DevelopAgent fallback = LocalAgent();

  late Directory _dir;
  bool ready = false;
  bool onboarded = false;
  int months = 12;
  Access access = Access.unknown;

  /// The agent develops new photos on its own. Off: everything waits for a
  /// person (or Auto in Edit).
  bool autoDevelop = true;
  bool skipScreenshots = true;

  /// How swatches look: a piece of the photo, the same piece blurred, or a
  /// flat fill.
  SwatchStyle swatches = SwatchStyle.photo;

  /// Photos taken before this wait in black and white instead of going to
  /// the agent: the first run develops only the newest [firstBatch].
  DateTime? autoSince;
  static const firstBatch = 20;

  /// Most photos the agent develops on its own per day.
  static const dailyLimit = 30;
  String _day = '';
  int _today = 0;
  static String get _todayKey => DateTime.now().toIso8601String().substring(0, 10);
  int get developedToday => _day == _todayKey ? _today : 0;

  final List<PhotoItem> items = [];
  final Map<String, PhotoItem> _byKey = {};

  // Shared between Photos and Map.
  final Set<int> paletteFilter = {};
  SortMode sort = SortMode.time;
  Recipe? clipboard;

  final List<String> agentLog = [];

  Future<void> init() async {
    _dir = await getApplicationSupportDirectory();
    await Directory('${_dir.path}/renders').create(recursive: true);
    final f = File('${_dir.path}/state.json');
    if (await f.exists()) {
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        onboarded = j['onboarded'] as bool? ?? false;
        months = j['months'] as int? ?? 12;
        autoDevelop = j['autoDevelop'] as bool? ?? true;
        skipScreenshots = j['skipScreenshots'] as bool? ?? true;
        swatches = SwatchStyle.values.asNameMap()[j['swatches']] ?? SwatchStyle.photo;
        final since = j['autoSince'] as int?;
        autoSince = since == null ? null : DateTime.fromMillisecondsSinceEpoch(since);
        _day = j['day'] as String? ?? '';
        _today = j['today'] as int? ?? 0;
        for (final it in (j['items'] as List).cast<Map<String, dynamic>>()) {
          _add(PhotoItem.fromJson(it));
        }
      } catch (e) {
        debugPrint('state load failed: $e');
      }
    }
    _sortItems();
    ready = true;
    if (onboarded) {
      access = await PhotoSource.access();
      unawaited(refresh());
    }
    notifyListeners();
  }

  void _add(PhotoItem it) {
    items.add(it);
    _byKey[it.key] = it;
  }

  void _sortItems() => items.sort((a, b) => b.taken.compareTo(a.taken));

  PhotoItem? byKey(String key) => _byKey[key];

  Timer? _saveTimer;
  Future<void>? _saving;
  bool _resetting = false;
  int _generation = 0;

  Future<void> resetForDemo() async {
    _resetting = true;
    _generation++;
    _saveTimer?.cancel();
    try {
      await _saving;
      final fresh = File('${_dir.path}/state.reset.json');
      await fresh.writeAsString('{"items":[]}', flush: true);
      await fresh.rename('${_dir.path}/state.json');

      for (final run in _runs.values) {
        run.cancel();
      }
      _runs.clear();
      _held.clear();
      items.clear();
      _byKey.clear();
      paletteFilter.clear();
      _palette = null;
      sort = SortMode.time;
      clipboard = null;
      agentLog.clear();
      _renders.clear();
      _patches.clear();
      onboarded = false;
      access = Access.unknown;
      months = 12;
      autoDevelop = true;
      skipScreenshots = true;
      swatches = SwatchStyle.photo;
      autoSince = null;
      _day = '';
      _today = 0;
    } finally {
      _resetting = false;
      notifyListeners();
    }
  }

  void _save() {
    if (_resetting) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () async {
      final j = {
        'onboarded': onboarded,
        'months': months,
        'autoDevelop': autoDevelop,
        'skipScreenshots': skipScreenshots,
        'swatches': swatches.name,
        if (autoSince != null) 'autoSince': autoSince!.millisecondsSinceEpoch,
        'day': _day,
        'today': _today,
        'items': items.map((e) => e.toJson()).toList(),
      };
      final previous = _saving;
      final saving = () async {
        await previous;
        await File('${_dir.path}/state.json').writeAsString(jsonEncode(j));
      }();
      _saving = saving;
      try {
        await saving;
      } finally {
        if (_saving == saving) _saving = null;
      }
    });
  }

  Future<void> finishOnboarding() async {
    onboarded = true;
    _save();
    notifyListeners();
    await refresh();
  }

  Future<Access> requestAccess() async {
    access = await PhotoSource.access(request: true);
    notifyListeners();
    return access;
  }

  void setMonths(int m) {
    months = m;
    _save();
    notifyListeners();
    unawaited(refresh());
  }

  void setAutoDevelop(bool on) {
    autoDevelop = on;
    if (on) {
      // From now on: only photos taken after this moment go to the agent.
      autoSince = DateTime.now();
    } else {
      for (final it in items.where((e) => e.state == Develop.pending)) {
        it.state = Develop.manual;
      }
    }
    _save();
    notifyListeners();
  }

  void setSwatches(SwatchStyle v) {
    swatches = v;
    _save();
    notifyListeners();
  }

  void setSkipScreenshots(bool on) {
    skipScreenshots = on;
    _save();
    notifyListeners();
  }

  /// Pull new photos from the library. Only the newest few, and photos taken
  /// later, go to the agent; the rest wait in black and white.
  Future<void> refresh() async {
    if (_resetting || access == Access.denied || access == Access.unknown) return;
    final generation = _generation;
    final refs = await PhotoSource.recent(months: months, skipScreenshots: skipScreenshots);
    if (generation != _generation) return;
    if (autoSince == null) {
      autoSince = refs.isEmpty
          ? DateTime.now()
          : refs[math.min(firstBatch, refs.length) - 1].taken;
      _save();
    }
    bool auto(DateTime taken) => autoDevelop && !taken.isBefore(autoSince!);
    var changed = false;
    final scenes = _SceneBuilder();
    for (final r in refs) {
      if (_byKey.containsKey(r.id)) continue;
      final it = PhotoItem(
        id: r.id,
        taken: r.taken,
        lat: r.lat,
        lng: r.lng,
        width: r.width,
        height: r.height,
        state: auto(r.taken) ? Develop.pending : Develop.manual,
      );
      if (it.state == Develop.pending) scenes.place(it);
      _add(it);
      changed = true;
    }
    // Screenshots that slipped in before: out, unless a person picked them.
    if (skipScreenshots) {
      final shots = await PhotoSource.screenshotIds();
      if (generation != _generation) return;
      for (final it in items.where((e) => shots.contains(e.id) && !e.picked && e.hues.isEmpty).toList()) {
        _runs.remove(it.key)?.cancel();
        items.remove(it);
        _byKey.remove(it.key);
        changed = true;
      }
    }
    // Photos queued by an older build that would now wait.
    for (final it in items.where((e) => e.state == Develop.pending && !e.asked && !auto(e.taken))) {
      it.state = Develop.manual;
      changed = true;
    }
    if (changed) {
      _sortItems();
      _save();
      notifyListeners();
    }
    _pump();
  }

  /// Photos picked by hand, from any date.
  /// Photos picked by hand are developed by hand: they wait in black and
  /// white instead of going to the agent.
  Future<List<PhotoItem>> importRefs(List<PhotoRef> refs) async {
    final added = <PhotoItem>[];
    for (final r in refs) {
      final known = _byKey[r.id];
      if (known != null) {
        // Already known but kept out of the library: bring it in.
        if (!known.shown) {
          known.picked = true;
          if (known.state == Develop.failed) known.state = Develop.manual;
          added.add(known);
        }
        continue;
      }
      final it = PhotoItem(
          id: r.id, taken: r.taken, lat: r.lat, lng: r.lng, width: r.width, height: r.height, state: Develop.manual, picked: true);
      _add(it);
      added.add(it);
    }
    if (added.isNotEmpty) {
      _sortItems();
      _save();
      notifyListeners();
    }
    return added;
  }

  /// Already in the library (photos the agent passed over do not count).
  bool inLibrary(String id) => _byKey[id]?.shown ?? false;

  // ------------------------------------------------------------ developing

  int _running = 0;
  static const _parallel = 2;

  int get pendingCount => items.where((e) => e.state == Develop.pending || e.state == Develop.developing).length;
  int get doneCount => items.where((e) => e.state == Develop.done).length;
  bool get developing => pendingCount > 0;

  final Map<String, AgentRun> _runs = {};
  final Set<String> _held = {};

  /// The agent's run on [it], if one is in progress.
  AgentRun? runFor(PhotoItem it) => _runs[it.key];

  void _pump() {
    if (_resetting) return;
    while (_running < _parallel) {
      final budget = _running + developedToday < dailyLimit;
      final next = items
          .where((e) => e.state == Develop.pending && e.attempts < 3 && !_held.contains(e.key) && (budget || e.asked))
          .firstOrNull;
      if (next == null) return;
      next.state = Develop.developing;
      _running++;
      unawaited(_develop(next).whenComplete(() {
        _running--;
        _pump();
      }));
    }
  }

  static const moreBatch = 30;

  /// Older photos the agent has not looked at yet.
  Iterable<PhotoItem> get _unlooked =>
      items.where((e) => e.state == Develop.manual && !e.judged && !e.picked && e.hues.isEmpty);
  int get unlookedCount => _unlooked.length;

  /// The person asks for more: the next [moreBatch] older photos go through
  /// the same screen and agent. Photos already passed over are not retried.
  void developMore() {
    var queued = 0;
    final scenes = _SceneBuilder();
    for (final it in _unlooked.toList()) {
      if (scenes.place(it)) continue;
      if (queued >= moreBatch) {
        // The next scene starts past the batch: leave it for next time.
        it.sceneOf = null;
        break;
      }
      it.state = Develop.pending;
      it.asked = true;
      it.attempts = 0;
      queued++;
    }
    _save();
    notifyListeners();
    _pump();
  }

  /// Keep the queue off [it] while the person looks at it in Edit.
  void hold(PhotoItem it) => _held.add(it.key);

  /// Give [it] back to the queue if the person left without touching it.
  void release(PhotoItem it) {
    if (!_held.remove(it.key)) return;
    _pump();
  }

  /// The person takes [it] over: stop the agent and keep its work so far.
  void takeOver(PhotoItem it) {
    _held.remove(it.key);
    it.picked = true;
    final run = _runs.remove(it.key);
    run?.cancel();
    if (it.state == Develop.pending || it.state == Develop.developing || it.state == Develop.failed) {
      it.state = Develop.manual;
      _save();
      notifyListeners();
    }
  }

  /// Run the agent on [it] now, outside the queue (Auto in Edit).
  AgentRun developNow(PhotoItem it) {
    final existing = _runs[it.key];
    if (existing != null) return existing;
    _held.remove(it.key);
    it.picked = true;
    it.state = Develop.developing;
    it.attempts = 0;
    final run = AgentRun();
    unawaited(_develop(it, run: run, queued: false));
    notifyListeners();
    return run;
  }

  /// Ask the agent to change [current] for [it] the way [request] says.
  /// The run streams its recipe as it works; [AgentRun.result] holds the
  /// settled one, nothing is saved until the person keeps it.
  AgentRun reviseNow(PhotoItem it, Recipe current, Revision request) {
    _runs.remove(it.key)?.cancel();
    final run = AgentRun()..recipe = current.copy();
    _runs[it.key] = run;
    unawaited(_revise(it, current, request, run));
    return run;
  }

  Future<void> _revise(PhotoItem it, Recipe current, Revision request, AgentRun run) async {
    final generation = _generation;
    final tag = it.id.substring(0, 6);
    _log('$tag revise: ${request.text ?? ''} ${request.marks.map((m) => '${m.intent.name}@${m.x.toStringAsFixed(2)},${m.y.toStringAsFixed(2)}').join(' ')}');
    try {
      final px = await run.guard(PhotoSource.pixels(it.id, 768));
      if (px == null) throw StateError('could not read photo');
      final r = await agent.revise(px, current, request, log: (s) => _log('$tag $s'), run: run);
      if (run.cancelled) return;
      run.result = r;
      run.emit(r, 'finish');
      _log('$tag revised: ${run.note ?? ''}');
    } on AgentCancelled {
      if (generation == _generation) _log('$tag revise taken over');
    } catch (e) {
      run.error = '$e';
      _log('revise failed: $e');
    } finally {
      if (_runs[it.key] == run) _runs.remove(it.key);
      run.close();
    }
  }

  void _log(String s) {
    agentLog.add(s);
    if (agentLog.length > 400) agentLog.removeRange(0, 100);
    debugPrint('[agent] $s');
  }

  Future<void> _develop(PhotoItem it, {AgentRun? run, bool queued = true}) async {
    run ??= AgentRun();
    _runs[it.key] = run;
    notifyListeners();
    try {
      final px = await run.guard(PhotoSource.pixels(it.id, 768));
      if (px == null) throw StateError('could not read photo');
      if (queued && !it.judged) {
        final v = await run.guard(_judge(it, px));
        it.judged = true;
        if (!v.develop) {
          it.state = Develop.manual;
          it.note = v.reason ?? 'No clear subject';
          _log('${it.id.substring(0, 6)} skipped: ${it.note}');
          throw _Skipped();
        }
      }
      Recipe recipe;
      try {
        recipe = await agent.develop(px, log: (s) => _log('${it.id.substring(0, 6)} $s'), run: run);
      } on AgentCancelled {
        rethrow;
      } catch (e) {
        _log('${agent.name} failed: $e');
        if (agent is LocalAgent) rethrow;
        recipe = await fallback.develop(px, run: run);
      }
      if (run.cancelled) throw AgentCancelled();
      it.auto = recipe;
      it.edit = recipe.copy();
      it.state = Develop.done;
      _applyToScene(it);
      if (queued && !it.asked) {
        if (_day != _todayKey) {
          _day = _todayKey;
          _today = 0;
        }
        _today++;
      }
    } on AgentCancelled {
      if (_byKey[it.key] == it) _log('${it.id.substring(0, 6)} taken over');
      return;
    } on _Skipped {
      // Left for a person; saved below.
    } catch (e) {
      it.attempts++;
      it.state = !queued ? Develop.manual : (it.attempts >= 3 ? Develop.failed : Develop.pending);
      _log('develop failed: $e');
    } finally {
      if (_runs[it.key] == run) _runs.remove(it.key);
      run.close();
    }
    _palette = null;
    _save();
    notifyListeners();
  }

  /// Which model screens photos before the agent develops them.
  Future<String> judgeName() async {
    final st = await AppleJudge.status();
    if (st == 'ok') return 'Apple, on this iPhone';
    final why = switch (st) {
      'appleIntelligenceNotEnabled' => 'Apple Intelligence off',
      'modelNotReady' => 'Apple model downloading',
      'noVision' => 'Apple model has no image input',
      'deviceNotEligible' => 'Apple model not supported',
      _ => 'Apple model unavailable',
    };
    return agent is LocalAgent ? 'Color only · $why' : '$_judgeModel · $why';
  }

  /// The rest of [rep]'s scene gets its edit, without another agent run.
  /// Frames more than a few seconds apart may be framed differently, so
  /// they keep the colors but not the area.
  void _applyToScene(PhotoItem rep) {
    final r = rep.edit;
    if (r == null) return;
    for (final o in items.where((e) => e.sceneOf == rep.key && e.hues.isEmpty && e.state == Develop.manual)) {
      final copy = r.copy();
      if (o.taken.difference(rep.taken).abs() > const Duration(seconds: 5)) copy.area = null;
      o
        ..auto = copy.copy()
        ..edit = copy
        ..state = Develop.done
        ..note = null;
    }
  }

  /// Free on-device screen first; only photos with real color reach the
  /// judge model. A judge error lets the photo through.
  Future<Verdict> _judge(PhotoItem it, Rgba px) async {
    final local = await screenOnDevice(px);
    if (!local.develop) return local;
    void say(String who, Verdict v) =>
        _log('${it.id.substring(0, 6)} $who: ${v.develop ? 'yes' : 'no'} · ${v.subject} · ${v.reason}');
    // Apple's on-device model first: free and private.
    try {
      final v = await AppleJudge.judge(px);
      if (v != null) {
        say('apple', v);
        return v;
      }
    } catch (e) {
      _log('apple judge failed: $e');
    }
    try {
      final v = await agent.judge(px);
      say(agent is LocalAgent ? 'device' : _judgeModel, v);
      return v;
    } catch (e) {
      _log('judge failed: $e');
      return const Verdict(true);
    }
  }

  /// Develop again from scratch (used by "Auto" when nothing was proposed).
  Future<void> redevelop(PhotoItem it) async {
    it.state = Develop.pending;
    it.attempts = 0;
    notifyListeners();
    _pump();
  }

  // ------------------------------------------------------------ edits

  void setEdit(PhotoItem it, Recipe r) {
    it.edit = r;
    _held.remove(it.key);
    if (it.state != Develop.done && r.colors.isNotEmpty) it.state = Develop.done;
    _palette = null;
    _save();
    notifyListeners();
  }

  void toggleFavorite(PhotoItem it) {
    it.favorite = !it.favorite;
    _save();
    notifyListeners();
  }

  void markSeen(PhotoItem it) {
    if (it.seen) return;
    it.seen = true;
    _save();
  }

  void remove(PhotoItem it) {
    items.remove(it);
    _byKey.remove(it.key);
    _palette = null;
    _save();
    notifyListeners();
  }

  PhotoItem duplicate(PhotoItem it) {
    final copy = PhotoItem(
      id: it.id,
      copyOf: DateTime.now().millisecondsSinceEpoch.toRadixString(36),
      taken: it.taken,
      lat: it.lat,
      lng: it.lng,
      width: it.width,
      height: it.height,
      edit: it.edit?.copy(),
      auto: it.auto?.copy(),
      state: it.state,
      seen: true,
    );
    final i = items.indexOf(it);
    items.insert(i + 1, copy);
    _byKey[copy.key] = copy;
    _palette = null;
    _save();
    notifyListeners();
    return copy;
  }

  void copyEdit(PhotoItem it) => clipboard = it.edit?.copy();

  void pasteEdit(Iterable<PhotoItem> targets) {
    final c = clipboard;
    if (c == null) return;
    for (final t in targets) {
      // Keep the target's own subject description; take the color settings.
      final r = c.copy()
        ..subject = t.edit?.subject
        ..why = 'Pasted from another photo.'
        ..focus = t.edit?.focus;
      t.edit = r;
      t.state = Develop.done;
    }
    _palette = null;
    _save();
    notifyListeners();
  }

  // ------------------------------------------------------------ palette

  List<PaletteEntry>? _palette;

  /// The user's collected colors, clustered. Ordered by hue.
  List<PaletteEntry> get palette {
    if (_palette != null) return _palette!;
    final entries = <PaletteEntry>[];
    for (final it in items) {
      if (it.state != Develop.done) continue;
      for (final c in it.hues) {
        PaletteEntry? near;
        var best = 0.075;
        for (final e in entries) {
          final d = math.sqrt(math.pow(e.color.l - c.l, 2) + math.pow(e.color.a - c.a, 2) * 2 + math.pow(e.color.b - c.b, 2) * 2);
          if (d < best) {
            best = d;
            near = e;
          }
        }
        if (near == null) {
          entries.add(PaletteEntry(c.copy(), {it.key}, it));
        } else {
          near.keys.add(it.key);
        }
      }
    }
    entries.sort((a, b) => _hueOrder(a.color).compareTo(_hueOrder(b.color)));
    return _palette = entries;
  }

  /// Hue order that starts at red and puts low-chroma colors at the end.
  static double _hueOrder(KeptColor c) => c.chroma < 0.03 ? 1000 + c.l : (c.hue + 360 - 15) % 360;

  void togglePalette(int index) {
    paletteFilter.contains(index) ? paletteFilter.remove(index) : paletteFilter.add(index);
    notifyListeners();
  }

  void clearPalette() {
    paletteFilter.clear();
    notifyListeners();
  }

  void setSort(SortMode m) {
    sort = m;
    notifyListeners();
  }

  /// Developed photos after the shared palette filter.
  List<PhotoItem> get visible {
    final pal = palette;
    final keys = paletteFilter.where((i) => i < pal.length).expand((i) => pal[i].keys).toSet();
    // Photos still developing are shown in black and white until their color comes back.
    final list = items.where((e) => e.shown);
    final filtered = paletteFilter.isEmpty ? list.toList() : list.where((e) => keys.contains(e.key)).toList();
    if (sort == SortMode.hue) {
      double order(PhotoItem e) => e.hues.isEmpty ? 1e9 : _hueOrder(e.hues.first);
      filtered.sort((a, b) => order(a).compareTo(order(b)));
    }
    return filtered;
  }

  // ------------------------------------------------------------ rendering

  final Map<String, Future<File?>> _renders = {};

  /// A rendered JPEG of the photo with its edit, long side [size].
  Future<File?> rendered(PhotoItem it, int size, {Recipe? recipe}) {
    final r = recipe ?? it.edit;
    if (r == null) return Future.value(null);
    final key = '${it.id.replaceAll('/', '_')}_${r.signature}_$size';
    return _renders[key] ??= _renderToFile(it.id, r, size, '${_dir.path}/renders/$key.jpg');
  }

  static Future<File?> _renderToFile(String id, Recipe r, int size, String path) async {
    final f = File(path);
    if (await f.exists()) return f;
    final px = await PhotoSource.pixels(id, size);
    if (px == null) return null;
    final bytes = await Isolate.run(() {
      final out = render(px, r).image;
      final im = img.Image.fromBytes(width: out.width, height: out.height, bytes: out.pixels.buffer, numChannels: 4)
          .convert(numChannels: 3);
      return Uint8List.fromList(img.encodeJpg(im, quality: 88));
    });
    await f.writeAsBytes(bytes);
    return f;
  }

  Future<Uint8List?> original(PhotoItem it, int size) => PhotoSource.jpeg(it.id, size);

  final Map<String, Future<ui.Image?>> _patches = {};

  /// A small square cut from [it] where it looks most like color [c]: what a
  /// swatch or heart is filled with, blurred when [swatches] is soft. Null
  /// if nothing in the photo is close, or swatches are flat.
  /// [light] lifts it to a light tone, keeping its texture, for marks that
  /// sit on a darkened corner (the favorite heart).
  Future<ui.Image?> patch(PhotoItem it, KeptColor c, {bool light = false}) {
    if (swatches == SwatchStyle.flat) return Future.value(null);
    final soft = swatches == SwatchStyle.soft;
    String f(double v) => v.toStringAsFixed(3);
    final key = '${it.id}|${f(c.l)},${f(c.a)},${f(c.b)}|$soft|$light';
    return _patches[key] ??= _makePatch(it.id, c.copy(), soft, light);
  }

  static Future<ui.Image?> _makePatch(String id, KeptColor c, bool soft, bool light) async {
    final px = await PhotoSource.pixels(id, 1024);
    if (px == null) return null;
    final p = await Isolate.run(() {
      var p = colorPatch(px, c);
      if (p == null) return null;
      if (soft) p = boxBlur(p, math.max(1, p.width ~/ 10), passes: 3);
      return light ? liftPatch(p, 0.8) : p;
    });
    if (p == null) return null;
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(p.pixels, p.width, p.height, ui.PixelFormat.rgba8888, done.complete);
    return done.future;
  }
}

class _Skipped implements Exception {}

/// Groups photos, newest first, into scenes: frames taken within 20 seconds
/// of each other at the same place. The first of each scene stands for it.
class _SceneBuilder {
  static const gap = Duration(seconds: 20);
  static const meters = 50.0;

  PhotoItem? _rep, _prev;

  /// True when [it] joins the current scene (and is marked so); false when it
  /// starts a new one.
  bool place(PhotoItem it) {
    final prev = _prev, rep = _rep;
    _prev = it;
    if (prev != null && rep != null && _same(prev, it)) {
      it
        ..sceneOf = rep.key
        ..judged = true
        ..note = 'Same scene as another photo';
      return true;
    }
    _rep = it;
    return false;
  }

  static bool _same(PhotoItem a, PhotoItem b) {
    if (a.taken.difference(b.taken).abs() > gap) return false;
    if (!a.hasLocation || !b.hasLocation) return true;
    const r = 6371000.0;
    final la = a.lat! * math.pi / 180, lb = b.lat! * math.pi / 180;
    final x = (b.lng! - a.lng!) * math.pi / 180 * math.cos((la + lb) / 2);
    final y = lb - la;
    return math.sqrt(x * x + y * y) * r < meters;
  }
}
