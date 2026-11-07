import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../agent/agent.dart';
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
      );
}

/// A group of similar kept colors, made only from what the user collected.
class PaletteEntry {
  PaletteEntry(this.color, this.keys);
  final KeptColor color;
  final Set<String> keys;
  double get hue => color.hue;
}

enum SortMode { time, hue }

/// App state. One instance, shared by Photos and Map.
class Store extends ChangeNotifier {
  Store._();
  static final Store instance = Store._();

  static const _apiKey = String.fromEnvironment('OPENAI_API_KEY');
  static const _model = String.fromEnvironment('OPENAI_MODEL', defaultValue: 'gpt-6.1-terra');

  late final DevelopAgent agent =
      _apiKey.isEmpty ? LocalAgent() : OpenAIAgent(apiKey: _apiKey, model: _model);
  final DevelopAgent fallback = LocalAgent();

  late Directory _dir;
  bool ready = false;
  bool onboarded = false;
  int months = 12;
  Access access = Access.unknown;

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
  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () async {
      final j = {'onboarded': onboarded, 'months': months, 'items': items.map((e) => e.toJson()).toList()};
      await File('${_dir.path}/state.json').writeAsString(jsonEncode(j));
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

  /// Pull new photos from the library and develop them, newest first.
  Future<void> refresh() async {
    if (access == Access.denied || access == Access.unknown) return;
    final refs = await PhotoSource.recent(months: months);
    var added = false;
    for (final r in refs) {
      if (_byKey.containsKey(r.id)) continue;
      _add(PhotoItem(id: r.id, taken: r.taken, lat: r.lat, lng: r.lng, width: r.width, height: r.height));
      added = true;
    }
    if (added) {
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
      if (_byKey.containsKey(r.id)) continue;
      final it = PhotoItem(id: r.id, taken: r.taken, lat: r.lat, lng: r.lng, width: r.width, height: r.height, state: Develop.manual);
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

  bool contains(String id) => _byKey.containsKey(id);

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
    while (_running < _parallel) {
      final next = items.where((e) => e.state == Develop.pending && e.attempts < 3 && !_held.contains(e.key)).firstOrNull;
      if (next == null) return;
      next.state = Develop.developing;
      _running++;
      unawaited(_develop(next).whenComplete(() {
        _running--;
        _pump();
      }));
    }
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
    it.state = Develop.developing;
    it.attempts = 0;
    final run = AgentRun();
    unawaited(_develop(it, run: run, queued: false));
    notifyListeners();
    return run;
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
    } on AgentCancelled {
      _log('${it.id.substring(0, 6)} taken over');
      return;
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
          entries.add(PaletteEntry(c.copy(), {it.key}));
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
    final list = items.where((e) =>
        (e.state == Develop.done && e.hues.isNotEmpty) ||
        e.state == Develop.pending ||
        e.state == Develop.developing ||
        e.state == Develop.manual);
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
}
