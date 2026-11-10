import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../agent/agent.dart';
import '../agent/apple_judge.dart';
import '../agent/gemini_agent.dart';
import '../agent/cloud_auth.dart';
import '../core/recipe.dart';
import '../core/source_tracking.dart';
import '../core/burst_similarity.dart';
import '../core/renderer.dart';
import 'photo_source.dart';
import 'photo_patch_cache.dart';
import 'activity.dart';
import 'subject.dart';

/// [manual]: the person develops it by hand; the agent leaves it alone.
enum Develop { pending, developing, done, failed, manual }

class PhotoItem {
  PhotoItem({
    required this.id,
    required this.taken,
    this.lat,
    this.lng,
    required int width,
    required int height,
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
    this.originalSha256,
    this.exactDuplicateOf,
    this.burstPrint,
    this.captured = false,
    this.sourceRevision, this.baselineSourceRevision, this.sourceModified, this.pendingSource, this.sourceReview,
    this.previousSource, this.previousEdit, this.pendingEdit,
    this.sourceSize, this.pendingSize, this.previousSize,
  // Public dimension parameters stay compatible; getters follow the selected source version.
  // ignore: prefer_initializing_formals
  }) : _width = width, _height = height;

  /// Taken with After Hue's camera. Only these leave the iPhone's library
  /// when deleted here; any other photo is the person's own and stays there.
  final bool captured;
  String? baselineSourceRevision;
  String? sourceRevision, pendingSource, sourceReview, previousSource;
  int? sourceModified;
  Recipe? previousEdit, pendingEdit;
  String get sourceId => sourceRevision == null ? id : 'snapshot:$sourceRevision';

  /// Freezing the initial source changes storage, not the rendered pixels.
  /// Older snapshots without baseline evidence keep their versioned cache key.
  String get sourceCacheId => sourceRevision == null || sourceRevision == baselineSourceRevision ? id : sourceId;

  /// Library asset id. Duplicates share the asset and differ in [key].
  final String id;
  final String? copyOf;
  String get key => copyOf == null ? id : '$id#$copyOf';

  final DateTime taken;
  double? lat, lng;
  final int _width, _height;
  List<int>? sourceSize, pendingSize, previousSize;
  int get width => sourceSize?[0] ?? _width;
  int get height => sourceSize?[1] ?? _height;

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

  /// Explicitly queued by the person, outside the daily limit.
  bool asked;

  /// Key of the photo that stands for this one's scene. The agent develops
  /// that one; its edit is applied here.
  String? sceneOf;

  /// SHA-256 of the original file bytes. Similar photos are grouped separately.
  String? originalSha256;
  String? exactDuplicateOf;
  Uint8List? burstPrint;

  /// In the library. Photos the agent was not going to develop on its own
  /// stay out until a person picks them.
  bool get shown {
    if (exactDuplicateOf != null) return false;
    return switch (state) {
        Develop.done => hues.isNotEmpty,
        Develop.pending || Develop.developing => true,
        Develop.manual => picked || hues.isNotEmpty,
        Develop.failed => false,
      };
  }

  bool get hasLocation => lat != null && lng != null;
  bool get isUndeveloped => state == Develop.manual && edit == null;
  List<KeptColor> get hues => edit?.colors ?? const [];

  Map<String, dynamic> toJson() => {
        'id': id,
        if (sourceRevision != null) 'sourceRevision': sourceRevision,
        if (baselineSourceRevision != null) 'baselineSourceRevision': baselineSourceRevision,
        if (sourceModified != null) 'sourceModified': sourceModified,
        if (pendingSource != null) 'pendingSource': pendingSource,
        if (sourceReview != null) 'sourceReview': sourceReview,
        if (previousSource != null) 'previousSource': previousSource,
        if (previousEdit != null) 'previousEdit': previousEdit!.toJson(),
        if (pendingEdit != null) 'pendingEdit': pendingEdit!.toJson(),
        if (copyOf != null) 'copyOf': copyOf,
        'taken': taken.millisecondsSinceEpoch,
        'lat': lat,
        'lng': lng,
        'w': _width,
        'h': _height,
        if (sourceSize != null) 'sourceSize': sourceSize,
        if (pendingSize != null) 'pendingSize': pendingSize,
        if (previousSize != null) 'previousSize': previousSize,
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
        if (originalSha256 != null) 'originalSha256': originalSha256,
        if (exactDuplicateOf != null) 'exactDuplicateOf': exactDuplicateOf,
        if (burstPrint != null) 'burstPrint': base64Encode(burstPrint!),
        if (captured) 'captured': true,
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
        originalSha256: j['originalSha256'] as String?,
        exactDuplicateOf: j['exactDuplicateOf'] as String?,
        burstPrint: j['burstPrint'] == null ? null : base64Decode(j['burstPrint'] as String),
        captured: j['captured'] as bool? ?? false,
        sourceSize: (j['sourceSize'] as List?)?.cast<int>(), pendingSize: (j['pendingSize'] as List?)?.cast<int>(),
        previousSize: (j['previousSize'] as List?)?.cast<int>(),
        baselineSourceRevision: j['baselineSourceRevision'] as String?,
        sourceRevision: j['sourceRevision'] as String?, sourceModified: j['sourceModified'] as int?,
        pendingSource: j['pendingSource'] as String?, sourceReview: j['sourceReview'] as String?,
        previousSource: j['previousSource'] as String?,
        previousEdit: j['previousEdit'] == null ? null : Recipe.fromJson(Map<String, dynamic>.from(j['previousEdit'])),
        pendingEdit: j['pendingEdit'] == null ? null : Recipe.fromJson(Map<String, dynamic>.from(j['pendingEdit'])),
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


enum SwatchStyle { photo, soft, flat }

/// App state. One instance, shared by Photos and Map.
class Store extends ChangeNotifier {
  Store._();
  static final Store instance = Store._();

  static const _aiUrl = String.fromEnvironment('AFTER_HUE_AI_URL');
  static const _firebaseKey = String.fromEnvironment('FIREBASE_WEB_API_KEY');
  static const _firebaseProject = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _judgeModel = 'Gemini on Google Cloud';

  bool get cloudAiConfigured => _aiUrl.isNotEmpty && _firebaseKey.isNotEmpty && _firebaseProject.isNotEmpty;
  bool cloudAiConsent = false;
  bool cloudAiConsentPromptSeen = false;
  bool get cloudAiBlocked => cloudAiConfigured && !cloudAiConsent;

  DevelopAgent? _agent;
  @visibleForTesting
  set agentForTesting(DevelopAgent value) => _agent = value;
  DevelopAgent get agent {
    if (cloudAiBlocked) return _consentRequired;
    return _agent ??= !cloudAiConfigured
        ? LocalAgent()
        : GeminiAgent(baseUrl: _aiUrl, tokenProvider: CloudAuth(
            apiKey: _firebaseKey, store: SecureCloudRefreshStore(_firebaseProject)).token,
            allowed: () => cloudAiConsent,
            subjectExtractor: (photo, x, y) => Subject.outline(photo, ui.Offset(x, y)));
  }
  final DevelopAgent _consentRequired = _ConsentRequiredAgent();

  File get _consentFile => File('${_dir.path}/cloud-ai-consent.json');

  // A revoked grant must not survive an app kill during the regular debounced
  // state save. Remove the grant first; a missing or invalid file means off.
  bool _writeCloudAiConsent(bool granted, bool seen) {
    try {
      if (!granted && _consentFile.existsSync()) _consentFile.deleteSync();
      final temp = File('${_dir.path}/cloud-ai-consent.pending.json');
      temp.writeAsStringSync(jsonEncode({'granted': granted, 'seen': seen}), flush: true);
      temp.renameSync(_consentFile.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  bool setCloudAiConsent(bool value) {
    // Reject enabling if the choice cannot be saved. Revocation takes effect
    // in memory before touching disk, even if storage fails.
    if (!value) cloudAiConsent = false;
    final saved = _writeCloudAiConsent(value, true);
    cloudAiConsent = value && saved;
    cloudAiConsentPromptSeen = saved;
    if (!cloudAiConsent) {
      for (final entry in _runs.entries.toList()) {
        final item = byKey(entry.key);
        entry.value.cancel();
        if (item != null && item.state == Develop.developing) item.state = Develop.pending;
      }
    }
    _save(); notifyListeners();
    if (cloudAiConsent) _pump();
    return saved;
  }

  void dismissCloudAiConsent() {
    cloudAiConsentPromptSeen = _writeCloudAiConsent(cloudAiConsent, true);
    _save(); notifyListeners();
  }
  final DevelopAgent fallback = LocalAgent();

  late Directory _dir;
  bool ready = false;
  bool onboarded = false;
  int months = 12;
  Access access = Access.unknown;

  /// The agent develops new photos on its own. Off: everything waits for a
  /// person (or Auto in Edit).
  bool autoDevelop = true;
  bool followSourceChanges = false;
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

  /// Library photos the person removed from After Hue. They stay in the
  /// photo library, so a later scan would bring them back; it passes them
  /// by instead. Picking one by hand lets it in again.
  final Set<String> _removed = {};

  /// The pictures of removed photos, so a copy of one stays out as well.
  final Set<String> _removedHashes = {};
  final Map<String, Future<void>> _hashingItems = {};
  Future<void>? _hashIndexTask;

  // Shared between Photos and Map.
  final Set<int> paletteFilter = {};
  bool groupByMonth = true;
  bool groupSimilarPhotos = true;
  final List<PhotoGroup> photoGroups = [];
  final Set<String> _keepSeparate = {};
  Timer? _groupTimer;
  int _groupRevision = 0;
  bool _grouping = false;
  bool _groupAgain = false;
  Recipe? clipboard;

  final List<String> agentLog = [];
  final List<ActivityEntry> activity = [];
  final Map<AgentRun, ActivityEntry> _backgroundEdits = {};
  int get unreadActivity => activity.where((entry) => entry.complete && !entry.read).length;

  ActivityEntry _startActivity(ActivityKind kind, Iterable<PhotoItem> photos, {String? request}) {
    final entry = ActivityEntry(id: DateTime.now().microsecondsSinceEpoch.toString(), kind: kind,
      keys: photos.map((it) => it.key).toSet().toList(), started: DateTime.now(), request: request);
    activity.insert(0, entry);
    while (activity.length > 100 && activity.last.complete) { activity.removeLast(); }
    _save();
    return entry;
  }

  void readActivity(ActivityEntry entry) { entry.read = true; _save(); notifyListeners(); }

  void _finishActivity(PhotoItem item, ActivityOutcome outcome, {String? error}) {
    for (final entry in activity.where((entry) => entry.kind != ActivityKind.editRequest)) {
      entry.finish(item.key, outcome, error: error);
    }
  }

  /// Done closes the editor, but this explicitly commits a running revision
  /// when it finishes. A newer edit/removal still cancels this run normally.
  void continueEditing(PhotoItem item, AgentRun run) {
    if (run.cancelled || _backgroundEdits.containsKey(run)) return;
    final entry = _startActivity(ActivityKind.editRequest, [item], request: run.requestText);
    if (run.result != null) {
      setEdit(item, run.result!.copy());
      entry.finish(item.key, ActivityOutcome.developed);
    } else {
      _backgroundEdits[run] = entry;
    }
    _save(); notifyListeners();
  }

  void _finishBackgroundEdit(PhotoItem item, AgentRun run) {
    final entry = _backgroundEdits.remove(run);
    if (entry == null) return;
    if (byKey(item.key) != item) {
      entry.finish(item.key, ActivityOutcome.removed);
    } else if (run.cancelled) {
      entry.finish(item.key, ActivityOutcome.cancelled);
    } else if (run.result == null) {
      entry.finish(item.key, ActivityOutcome.failed, error: run.error);
    } else {
      item.edit = run.result!.copy();
      item.state = item.hues.isEmpty ? Develop.manual : Develop.done;
      _palette = null;
      _scheduleGrouping();
      entry.finish(item.key, ActivityOutcome.developed);
    }
    _save(); notifyListeners();
  }


  Future<void> init() async {
    _dir = await getApplicationSupportDirectory();
    PhotoSource.snapshots = Directory('${_dir.path}/sources');
    await Directory('${_dir.path}/renders').create(recursive: true);
    _patchCache = PhotoPatchCache(Directory('${_dir.path}/patches'));
    final f = File('${_dir.path}/state.json');
    if (await f.exists()) {
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        activity.addAll(((j['activity'] as List?) ?? []).map((e) => ActivityEntry.fromJson(Map<String, dynamic>.from(e))));
        _explicitBatch.addAll(((j['explicitBatch'] as List?) ?? const []).cast<String>());
        _automaticBatch.addAll(((j['automaticBatch'] as List?) ?? const []).cast<String>());
        onboarded = j['onboarded'] as bool? ?? false;
        months = j['months'] as int? ?? 12;
        autoDevelop = j['autoDevelop'] as bool? ?? true;
        followSourceChanges = j['followSourceChanges'] == true;
        skipScreenshots = j['skipScreenshots'] as bool? ?? true;
        groupByMonth = j['groupByMonth'] as bool? ?? true;
        groupSimilarPhotos = j['groupSimilarPhotos'] as bool? ?? true;
        photoGroups.addAll(((j['photoGroups'] as List?) ?? []).map((g) => PhotoGroup.fromJson(Map<String, dynamic>.from(g))));
        _keepSeparate.addAll(((j['keepSeparate'] as List?) ?? []).cast<String>());
        swatches = SwatchStyle.values.asNameMap()[j['swatches']] ?? SwatchStyle.photo;
        final since = j['autoSince'] as int?;
        autoSince = since == null ? null : DateTime.fromMillisecondsSinceEpoch(since);
        _day = j['day'] as String? ?? '';
        _today = j['today'] as int? ?? 0;
        _removed.addAll(((j['removed'] as List?) ?? const []).cast<String>());
        _removedHashes.addAll(((j['removedHashes'] as List?) ?? const []).cast<String>());
        for (final it in (j['items'] as List).cast<Map<String, dynamic>>()) {
          _add(PhotoItem.fromJson(it));
        }
      } catch (e) {
        debugPrint('state load failed: $e');
      }
    }
    // Consent is separate from debounced app state: absence/corruption means off.
    cloudAiConsent = false;
    cloudAiConsentPromptSeen = false;
    try {
      if (_consentFile.existsSync()) {
        final consent = jsonDecode(_consentFile.readAsStringSync()) as Map<String, dynamic>;
        cloudAiConsent = consent['granted'] == true;
        cloudAiConsentPromptSeen = consent['seen'] == true;
      }
    } catch (_) { /* Treat unreadable consent as not granted. */ }
    // Restore photos hidden by the older timestamp/grey-thumbnail heuristic.
    // Only an exact original-file hash may hide them again.
    for (final item in items.where((it) => it.note == _sameNote && it.originalSha256 == null)) {
      item.picked = true; item.note = null;
    }
    _sortItems();
    // Revisions cannot resume after process termination; report interruption.
    for (final entry in activity.where((e) => !e.complete)) {
      for (final key in entry.keys.where((key) => !entry.outcomes.containsKey(key)).toList()) {
        final item = byKey(key);
        if (item == null) { entry.finish(key, ActivityOutcome.removed); }
        else if (entry.kind == ActivityKind.editRequest) { entry.finish(key, ActivityOutcome.cancelled); }
        else if (item.state == Develop.done) { entry.finish(key, ActivityOutcome.developed); }
        else if (item.state != Develop.pending && item.state != Develop.developing) { entry.finish(key, ActivityOutcome.skipped); }
      }
    }
    _explicitBatch.addAll(items.where((it) => it.picked && it.asked &&
        (it.state == Develop.pending || it.state == Develop.developing)).map((it) => it.key));
    ready = true;
    unawaited(_indexOriginalHashes());
    _scheduleGrouping();
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
    _sourceCheckTimer?.cancel();
    _generation++;
    _checkedPhotoLocations.clear();
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
      _explicitBatch.clear();
      _automaticBatch.clear();
      _held.clear();
      items.clear();
      _byKey.clear();
      _removed.clear();
      _removedHashes.clear();
      _hashingItems.clear();
      _hashIndexTask = null;
      paletteFilter.clear();
      _palette = null;
      groupByMonth = true;
      groupSimilarPhotos = true;
      photoGroups.clear();
      _keepSeparate.clear();
      _groupRevision++;
      _groupTimer?.cancel();
      clipboard = null;
      agentLog.clear();
      activity.clear();
      _backgroundEdits.clear();
      _renders.clear();
      _patchCache = PhotoPatchCache(Directory('${_dir.path}/patches'));
      onboarded = false;
      cloudAiConsent = false;
      cloudAiConsentPromptSeen = false;
      if (_consentFile.existsSync()) _consentFile.deleteSync();
      access = Access.unknown;
      months = 12;
      autoDevelop = true;
      followSourceChanges = false;
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
        'activity': activity.map((entry) => entry.toJson()).toList(),
        'explicitBatch': _explicitBatch.toList(),
        'automaticBatch': _automaticBatch.toList(),
        'onboarded': onboarded,
        'cloudAiConsent': cloudAiConsent,
        'cloudAiConsentPromptSeen': cloudAiConsentPromptSeen,
        'months': months,
        'autoDevelop': autoDevelop,
        'followSourceChanges': followSourceChanges,
        'skipScreenshots': skipScreenshots,
        'groupByMonth': groupByMonth,
        'groupSimilarPhotos': groupSimilarPhotos,
        'photoGroups': photoGroups.map((group) => group.toJson()).toList(),
        'keepSeparate': _keepSeparate.toList(),
        'swatches': swatches.name,
        if (autoSince != null) 'autoSince': autoSince!.millisecondsSinceEpoch,
        'day': _day,
        'today': _today,
        'items': items.map((e) => e.toJson()).toList(),
        'removed': _removed.toList(),
        'removedHashes': _removedHashes.toList(),
      };
      final previous = _saving;
      final saving = () async {
        await previous;
        final temp = File('${_dir.path}/state.pending.json');
        await temp.writeAsString(jsonEncode(j), flush: true);
        await temp.rename('${_dir.path}/state.json');
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

  Future<Access> requestAccess() => updatePhotoAccess(request: true);

  Future<Access> updatePhotoAccess({bool request = false}) async {
    final current = await PhotoSource.access(request: request);
    if (current != access) {
      _checkedPhotoLocations.clear();
      access = current;
      notifyListeners();
    }
    return access;
  }

  /// Repair metadata omitted before photo-EXIF permission was granted. Existing
  /// coordinates and all edits remain unchanged; no image is redeveloped.
  void updatePhotoLocations(Iterable<PhotoRef> refs) {
    final locations = {for (final ref in refs)
      if (PhotoSource.validLocation(ref.lat, ref.lng)) ref.id: ref};
    var changed = false;
    for (final item in items) {
      final ref = locations[item.id];
      if (ref == null || PhotoSource.validLocation(item.lat, item.lng)) continue;
      item.lat = ref.lat;
      item.lng = ref.lng;
      changed = true;
    }
    if (changed) { _save(); notifyListeners(); }
  }

  final _checkedPhotoLocations = <String>{};
  bool _checkingPhotoLocations = false;
  Future<void> backfillPhotoLocations() async {
    if (!Platform.isAndroid || _checkingPhotoLocations || _resetting || !ready) return;
    _checkingPhotoLocations = true;
    final generation = _generation;
    try {
      // A background refresh never opens a permission dialog.
      if (!await PhotoSource.canReadMediaLocation()) return;
      final ids = items.where((item) => !PhotoSource.validLocation(item.lat, item.lng) && !_checkedPhotoLocations.contains(item.id))
          .map((item) => item.id).toSet();
      final found = <PhotoRef>[];
      for (final id in ids) {
        if (_generation != generation || _resetting) return;
        final ref = await PhotoSource.refById(id);
        if (_generation != generation || _resetting) return;
        if (ref != null) { _checkedPhotoLocations.add(id); found.add(ref); }
        if (found.length >= 16) { updatePhotoLocations(found); found.clear(); }
      }
      updatePhotoLocations(found);
    } finally { _checkingPhotoLocations = false; }
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
    updatePhotoLocations(refs);
    bool auto(DateTime taken) => autoDevelop && !taken.isBefore(autoSince!);
    var changed = false;
    final automatic = <PhotoItem>[];
    for (final r in refs) {
      if (_byKey.containsKey(r.id) || _removed.contains(r.id)) continue;
      final it = PhotoItem(
        id: r.id,
        taken: r.taken,
        lat: r.lat,
        lng: r.lng,
        width: r.width,
        height: r.height,
        state: auto(r.taken) ? Develop.pending : Develop.manual,
      );
      _add(it);
      if (it.state == Develop.pending) automatic.add(it);
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
    if (automatic.isNotEmpty) _startActivity(ActivityKind.autoImport, automatic);
    if (changed) {
      _sortItems();
      _save();
      notifyListeners();
    }
    _pump();
    _scheduleGrouping();
    scheduleSourceCheck();
  }

  /// Photos picked by hand, from any date.
  Future<List<PhotoItem>> importRefs(List<PhotoRef> refs, {bool autoDevelop = false}) async {
    updatePhotoLocations(refs);
    unawaited(backfillPhotoLocations());
    await _indexOriginalHashes();
    if (autoDevelop) _beginExplicitBatch();
    final added = <PhotoItem>[], processed = <PhotoItem>[];
    for (final r in refs) {
      _removed.remove(r.id);
      final known = _byKey[r.id];
      if (known?.shown ?? false) continue;
      final it = known ?? PhotoItem(
        id: r.id, taken: r.taken, lat: r.lat, lng: r.lng, width: r.width, height: r.height,
      );
      _prepareExplicitDevelopment(it, auto: autoDevelop);
      if (known == null) _add(it);
      processed.add(it);
      await _hashPhoto(it);
      if (it.exactDuplicateOf == null) added.add(it);
    }
    if (processed.isNotEmpty) {
      final entry = _startActivity(ActivityKind.importBatch, processed);
      for (final item in processed) {
        if (item.exactDuplicateOf != null) { entry.finish(item.key, ActivityOutcome.skipped); }
        else if (!autoDevelop) { entry.finish(item.key, ActivityOutcome.added); }
      }
      _sortItems();
      _save();
      notifyListeners();
      if (autoDevelop) _pump();
    }
    _scheduleGrouping();
    return added;
  }

  List<PhotoItem> get undeveloped => items.where((it) => it.shown && it.isUndeveloped).toList();

  void autoDevelopUndeveloped([Iterable<PhotoItem>? scope]) {
    final batch = (scope ?? undeveloped)
        .where((it) => byKey(it.key) == it && it.shown && it.isUndeveloped).toList();
    if (batch.isEmpty) return;
    _beginExplicitBatch();
    _startActivity(ActivityKind.developBatch, batch);
    for (final it in batch) {
      _prepareExplicitDevelopment(it, auto: true);
    }
    _save();
    notifyListeners();
    _pump();
  }

  void _prepareExplicitDevelopment(PhotoItem it, {required bool auto}) {
    if (auto) _explicitBatch.add(it.key);
    it
      ..picked = true
      ..asked = auto
      ..state = auto ? Develop.pending : Develop.manual
      ..sceneOf = null
      ..exactDuplicateOf = null
      ..attempts = 0
      ..note = null;
  }

  /// A photo taken with After Hue's camera, developed as it was seen. The
  /// person chose its colors, so the agent leaves it alone. Called before the
  /// library refresh finds it, so it is not brought in twice.
  PhotoItem addCaptured({
    required String id,
    required DateTime taken,
    required int width,
    required int height,
    double? lat,
    double? lng,
    required Recipe recipe,
  }) {
    final kept = recipe.colors.isNotEmpty;
    final it = PhotoItem(
      id: id,
      taken: taken,
      lat: lat,
      lng: lng,
      width: width,
      height: height,
      edit: recipe,
      state: kept ? Develop.done : Develop.manual,
      picked: true,
      judged: true,
      seen: true,
      captured: true,
    );
    final known = _byKey[id];
    if (known != null) {
      items.remove(known);
      _byKey.remove(id);
    }
    _removed.remove(id);
    _add(it);
    _sortItems();
    _save();
    notifyListeners();
    _scheduleGrouping();
    return it;
  }

  /// Already in the library (photos the agent passed over do not count).
  bool inLibrary(String id) => _byKey[id]?.shown ?? false;

  // ------------------------------------------------------------ developing

  final Set<String> _explicitBatch = {};
  final Set<String> _automaticBatch = {};

  void _syncAutomaticBatch() {
    if (!_automaticBatch.any((key) {
      final item = byKey(key);
      return item?.state == Develop.pending || item?.state == Develop.developing;
    })) { _automaticBatch.clear(); }
    _automaticBatch.addAll(items.where((it) => !it.picked &&
      (it.state == Develop.pending || it.state == Develop.developing)).map((it) => it.key));
  }

  ({int done, int total, int active}) automaticProgress() {
    final batch = _automaticBatch.map(byKey).whereType<PhotoItem>().toList();
    return (
      done: batch.where((it) => it.state != Develop.pending && it.state != Develop.developing).length,
      total: batch.length,
      active: batch.where((it) => it.state == Develop.developing).length,
    );
  }


  void _beginExplicitBatch() {
    if (!_explicitBatch.any((key) {
      final it = byKey(key);
      return it?.state == Develop.pending || it?.state == Develop.developing;
    })) {
      _explicitBatch.clear();
    }
  }

  ({int done, int total}) developmentProgress([Iterable<PhotoItem>? scope]) {
    final allowed = scope?.map((it) => it.key).toSet();
    final batch = _explicitBatch.where((key) => allowed == null || allowed.contains(key))
        .map(byKey).whereType<PhotoItem>().toList();
    return (done: batch.where((it) => it.edit != null &&
        (it.state == Develop.done || it.state == Develop.manual)).length, total: batch.length);
  }

  int _running = 0;
  static const _parallel = 2;

  int get pendingCount => items.where((e) => e.state == Develop.pending || e.state == Develop.developing).length;
  int get doneCount => items.where((e) => e.state == Develop.done).length;
  bool get developing => !cloudAiBlocked && pendingCount > 0;

  final Map<String, AgentRun> _runs = {};
  final Set<String> _held = {};

  /// The agent's run on [it], if one is in progress.
  AgentRun? runFor(PhotoItem it) => _runs[it.key];

  void _pump() {
    if (_resetting || cloudAiBlocked) return;
    _syncAutomaticBatch();
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
    final batch = <PhotoItem>[];
    var queued = 0;
    for (final it in _unlooked.toList()) {
      if (queued >= moreBatch) {
        // The next scene starts past the batch: leave it for next time.
        it.sceneOf = null;
        break;
      }
      it.state = Develop.pending;
      it.asked = true;
      it.attempts = 0;
      queued++;
      batch.add(it);
    }
    if (batch.isNotEmpty) _startActivity(ActivityKind.developBatch, batch);
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
    if (cloudAiBlocked) {
      final run = AgentRun()..error = 'Enable Cloud AI in Settings to use Auto.';
      scheduleMicrotask(run.close);
      return run;
    }
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
    if (cloudAiBlocked) {
      final run = AgentRun()..error = 'Enable Cloud AI in Settings to use Ask.';
      scheduleMicrotask(run.close);
      return run;
    }
    _runs.remove(it.key)?.cancel();
    final run = AgentRun()..recipe = current.copy()..requestText = request.text..revision = request;
    _runs[it.key] = run;
    notifyListeners();
    unawaited(_revise(it, current, request, run));
    return run;
  }

  Future<void> _revise(PhotoItem it, Recipe current, Revision request, AgentRun run) async {
    final generation = _generation;
    final tag = it.id.substring(0, math.min(6, it.id.length));
    _log('$tag revise: ${request.text ?? ''} ${request.marks.map((m) => '${m.intent.name}@${m.x.toStringAsFixed(2)},${m.y.toStringAsFixed(2)}').join(' ')}');
    try {
      final px = await run.guard(sourcePixels(it, 768));
      if (px == null) throw StateError('could not read photo');
      final r = await agent.revise(px, current, request, originalSize: (width: it.width, height: it.height), log: (s) => _log('$tag $s'), run: run);
      if (run.cancelled) return;
      run.result = await run.guard(withColorReferencesAsync(px, r));
      run.emit(run.result!, 'finish');
      _log('$tag revised: ${run.note ?? ''}');
    } on AgentCancelled {
      if (generation == _generation) _log('$tag revise taken over');
    } catch (e) {
      run.error = '$e';
      _log('revise failed: $e');
    } finally {
      _finishBackgroundEdit(it, run);
      if (_runs[it.key] == run) _runs.remove(it.key);
      notifyListeners();
      run.close();
    }
  }

  /// Index one original at a time without blocking gallery rendering. Stored
  /// hashes are reused, and unknown/unavailable originals are never excluded.
  Future<void> _indexOriginalHashes() {
    if (_hashIndexTask != null) return _hashIndexTask!;
    final generation = _generation;
    final candidates = items.where((it) => it.copyOf == null && it.shown).toList();
    late final Future<void> task;
    task = () async {
      for (final item in candidates) {
        if (generation != _generation || _resetting) return;
        await _hashPhoto(item);
      }
    }().whenComplete(() { if (_hashIndexTask == task) _hashIndexTask = null; });
    _hashIndexTask = task;
    return task;
  }

  Future<void> _hashPhoto(PhotoItem item) {
    if (item.copyOf != null || byKey(item.key) != item) return Future.value();
    return _hashingItems.putIfAbsent(item.key, () => _checkOriginalHash(item)
      .whenComplete(() { _hashingItems.remove(item.key); }));
  }

  Future<void> _checkOriginalHash(PhotoItem item) async {
    final generation = _generation;
    final hash = item.originalSha256 ?? await PhotoSource.originalHash(item.id);
    if (hash == null || generation != _generation || byKey(item.key) != item || _resetting) return;
    final newHash = item.originalSha256 != hash;
    item.originalSha256 = hash;
    if (item.picked) _removedHashes.remove(hash);
    final owner = items.where((other) => other != item && other.copyOf == null &&
      other.shown && other.exactDuplicateOf == null && other.originalSha256 == hash).firstOrNull;
    final duplicate = owner?.key ?? (!item.picked && _removedHashes.contains(hash) ? 'removed' : null);
    if (duplicate != item.exactDuplicateOf) {
      item.exactDuplicateOf = duplicate;
      if (duplicate != null) {
        item.state = Develop.manual;
        item.judged = true;
        item.note = _sameNote;
        _finishActivity(item, ActivityOutcome.skipped);
        _runs.remove(item.key)?.cancel();
        removeFromGroup(item, remember: false);
      }
      _palette = null;
      _save(); notifyListeners();
    } else if (newHash) { _save(); }
  }

  void _log(String s) {
    agentLog.add(s);
    if (agentLog.length > 400) agentLog.removeRange(0, 100);
    debugPrint('[agent] $s');
  }

  Future<void> _develop(PhotoItem it, {AgentRun? run, bool queued = true}) async {
    run ??= AgentRun();
    // Batch Auto is the same explicit request as Auto in Edit, but queued.
    final batchAuto = queued && it.picked && it.asked;
    _runs[it.key] = run;
    notifyListeners();
    try {
      if (queued) {
        await run.guard(_indexOriginalHashes());
        await run.guard(_hashPhoto(it));
        if (it.exactDuplicateOf != null) throw _Skipped();
      }
      final px = await run.guard(sourcePixels(it, 768));
      if (px == null) throw StateError('could not read photo');
      if (queued && !batchAuto && !it.judged) {
        final v = await run.guard(_judge(it, px, run));
        it.judged = true;
        if (!v.develop) {
          it.state = Develop.manual;
          it.note = v.reason ?? 'No clear subject';
          _log('${it.id.substring(0, math.min(6, it.id.length))} skipped: ${it.note}');
          throw _Skipped();
        }
      }
      Recipe recipe = await agent.develop(px, originalSize: (width: it.width, height: it.height),
          log: (s) => _log('${it.id.substring(0, math.min(6, it.id.length))} $s'), run: run);
      if (run.cancelled) throw AgentCancelled();
      final chosen = recipe;
      recipe = await run.guard(withColorReferencesAsync(px, chosen));
      it.auto = recipe;
      it.edit = recipe.copy();
      it.state = batchAuto && recipe.colors.isEmpty ? Develop.manual : Develop.done;
      _scheduleGrouping();
      if (queued && !it.asked) {
        if (_day != _todayKey) {
          _day = _todayKey;
          _today = 0;
        }
        _today++;
      }
    } on AgentCancelled {
      if (_byKey[it.key] == it) _log('${it.id.substring(0, math.min(6, it.id.length))} taken over');
      return;
    } on _Skipped {
      // Left for a person; saved below.
    } catch (e) {
      run.error = '$e';
      it.attempts++;
      if (!queued || (batchAuto && it.attempts >= 3)) {
        it.state = Develop.manual;
      } else {
        it.state = it.attempts >= 3 ? Develop.failed : Develop.pending;
      }
      _log('develop failed: $e');
    } finally {
      if (run.cancelled) {
        _finishActivity(it, byKey(it.key) == it ? ActivityOutcome.cancelled : ActivityOutcome.removed);
      } else if (it.state != Develop.pending) {
        _finishActivity(it, it.state == Develop.done ? ActivityOutcome.developed :
          it.state == Develop.failed || run.error != null ? ActivityOutcome.failed : ActivityOutcome.skipped, error: run.error);
      }
      if (!run.cancelled && it.edit != null && it.state == Develop.done) run.result ??= it.edit!.copy();
      _finishBackgroundEdit(it, run);
      if (_runs[it.key] == run) _runs.remove(it.key);
      notifyListeners();
      run.close();
      _save();
      notifyListeners();
    }
    _palette = null;
    _save();
    notifyListeners();
  }

  /// Which model screens photos before the agent develops them.
  Future<String> judgeName() async {
    final st = await AppleJudge.status();
    if (st == 'ok') return 'Apple, on this iPhone';
    if (st == 'os') return agent is LocalAgent ? 'Color only · on device' : _judgeModel;
    final why = switch (st) {
      'appleIntelligenceNotEnabled' => 'Apple Intelligence off',
      'modelNotReady' => 'Apple model downloading',
      'noVision' => 'Apple model has no image input',
      'deviceNotEligible' => 'Apple model not supported',
      _ => 'Apple model unavailable',
    };
    return agent is LocalAgent ? 'Color only · $why' : '$_judgeModel · $why';
  }

  /// Free on-device screen first; only photos with real color reach the
  /// judge model. A judge error lets the photo through.
  Future<Verdict> _judge(PhotoItem it, Rgba px, AgentRun run) async {
    final local = await run.guard(screenOnDevice(px));
    if (!local.develop) return local;
    void say(String who, Verdict v) =>
        _log('${it.id.substring(0, math.min(6, it.id.length))} $who: ${v.develop ? 'yes' : 'no'} · ${v.subject} · ${v.reason}');
    // Apple's on-device model first: free and private.
    try {
      final v = await run.guard(AppleJudge.judge(px));
      if (v != null) {
        say('apple', v);
        return v;
      }
    } on AgentCancelled {
      rethrow;
    } catch (e) {
      _log('apple judge failed: $e');
    }
    try {
      if (run.cancelled) throw AgentCancelled();
      final v = await agent.judge(px, run: run);
      say(agent is LocalAgent ? 'device' : _judgeModel, v);
      return v;
    } on AgentCancelled {
      rethrow;
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
    it.pendingEdit = null;
    if (it.pendingSource != null) it.sourceReview = 'Your edit changed. Review it against the updated original.';
    final pixels = PhotoSource.cachedPixels(it.sourceId);
    if (pixels != null) { unawaited(_attachReferences(it, r, pixels: pixels)); }
    _scheduleGrouping();
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

  /// A print saved to Photos is an output, not a new photo to auto-develop.
  /// Explicit import can still bring it back, just like a removed library item.
  void ignoreSavedExport(String id) {
    if (!ready) return;
    final imported = items.where((it) => it.id == id).toList();
    for (final item in imported) { remove(item); }
    _removed.add(id);
    _save();
  }

  void remove(PhotoItem it) {
    _finishActivity(it, ActivityOutcome.removed);
    removeFromGroup(it, remember: false);
    _explicitBatch.remove(it.key);
    _automaticBatch.remove(it.key);
    _held.remove(it.key);
    _runs.remove(it.key)?.cancel();
    items.remove(it);
    _byKey.remove(it.key);
    // The last of this photo gone (copies share its id): keep it out.
    if (!items.any((e) => e.id == it.id)) {
      _removed.add(it.id);
      final hash = it.originalSha256;
      if (hash != null) _removedHashes.add(hash);
    }
    _palette = null;
    _save();
    notifyListeners();
  }

  /// Deletes shots After Hue's camera took, from the iPhone too (iOS asks
  /// first, and keeps them in Recently Deleted). Anything else, or a copy
  /// whose photo another item still shows, only leaves After Hue. Returns
  /// the items that went.
  Future<List<PhotoItem>> delete(List<PhotoItem> its) async {
    final going = its.toSet();
    final shared = <PhotoItem>[], last = <PhotoItem>[];
    for (final it in going) {
      (!it.captured || items.any((e) => e.id == it.id && !going.contains(e)) ? shared : last).add(it);
    }
    final deleted = await PhotoSource.delete(last.map((e) => e.id).toSet().toList());
    final gone = [...shared, ...last.where((e) => deleted.contains(e.id))];
    if (last.isNotEmpty && deleted.isEmpty) return const [];
    for (final it in gone) {
      remove(it);
    }
    return gone;
  }

  PhotoItem duplicate(PhotoItem it) {
    final copy = PhotoItem(
      id: it.id,
      copyOf: DateTime.now().millisecondsSinceEpoch.toRadixString(36),
      picked: true,
      taken: it.taken,
      lat: it.lat,
      lng: it.lng,
      width: it.width,
      height: it.height,
      edit: it.edit?.copy(),
      auto: it.auto?.copy(),
      state: it.state,
      seen: true,
      captured: it.captured,
      sourceRevision: it.sourceRevision, baselineSourceRevision: it.baselineSourceRevision, sourceModified: it.sourceModified, sourceSize: it.sourceSize,
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

  void setGroupByMonth(bool value) {
    groupByMonth = value;
    _save();
    notifyListeners();
  }

  /// Developed photos after the shared palette filter.
  List<PhotoItem> get visible {
    final pal = palette;
    final keys = paletteFilter.where((i) => i < pal.length).expand((i) => pal[i].keys).toSet();
    // Photos still developing are shown in black and white until their color comes back.
    final list = items.where((e) => e.shown);
    final filtered = paletteFilter.isEmpty ? list.toList() : list.where((e) => keys.contains(e.key)).toList();
    return filtered;
  }

  PhotoGroup? groupFor(PhotoItem item) => groupSimilarPhotos
      ? photoGroups.where((g) => g.members.contains(item.key) && g.members.where((key) => byKey(key)?.shown == true).length > 1).firstOrNull
      : null;

  List<PhotoItem> groupItems(PhotoGroup group) => group.members.map(byKey).whereType<PhotoItem>()
      .where((it) => it.shown).toList();

  List<PhotoItem> get galleryItems {
    final all = visible;
    if (!groupSimilarPhotos) return all;
    final keys = all.map((it) => it.key).toSet();
    final hidden = <String>{};
    for (final group in photoGroups) {
      final members = group.members.where(keys.contains).toList();
      if (members.length < 2) continue;
      final cover = members.contains(group.cover) ? group.cover : members.first;
      hidden.addAll(members.where((key) => key != cover));
    }
    return all.where((it) => !hidden.contains(it.key)).toList();
  }

  void setGroupSimilarPhotos(bool value) {
    groupSimilarPhotos = value;
    _groupRevision++;
    if (value) _scheduleGrouping();
    _save(); notifyListeners();
  }

  void groupPhotos(Iterable<PhotoItem> selection) {
    final chosen = selection.where((it) => byKey(it.key) == it).toList();
    if (chosen.length < 2) return;
    final keys = chosen.map((it) => it.key).toSet();
    for (final group in photoGroups.where((g) => g.members.any(keys.contains)).toList()) {
      keys.addAll(group.members); photoGroups.remove(group);
    }
    _keepSeparate.removeAll(keys);
    groupSimilarPhotos = true;
    photoGroups.add(PhotoGroup(id: chosen.first.key, cover: chosen.first.key, members: keys.toList(), manual: true));
    _groupRevision++; _save(); notifyListeners();
  }

  void setGroupCover(PhotoItem item) {
    final group = groupFor(item);
    if (group == null) return;
    group.cover = item.key; group.manual = true;
    _groupRevision++; _save(); notifyListeners();
  }

  void removeFromGroup(PhotoItem item, {bool remember = true}) {
    if (remember) _keepSeparate.add(item.key);
    for (final group in photoGroups.where((g) => g.members.contains(item.key)).toList()) {
      group.members.remove(item.key);
      group.manual = true;
      if (group.members.length < 2) { photoGroups.remove(group); }
      else if (group.cover == item.key) { group.cover = group.members.first; }
    }
    _groupRevision++;
    if (remember) { _save(); notifyListeners(); }
  }

  void ungroupPhotos(PhotoGroup group) {
    _keepSeparate.addAll(group.members);
    photoGroups.remove(group);
    _groupRevision++; _save(); notifyListeners();
  }

  void _scheduleGrouping() {
    _groupTimer?.cancel();
    if (!groupSimilarPhotos || !ready || items.length < 2) return;
    if (_grouping) { _groupAgain = true; return; }
    _groupTimer = Timer(const Duration(milliseconds: 600), () => unawaited(regroupSimilarPhotos()));
  }

  /// Only inspect thumbnails with a nearby capture time; unrelated library
  /// photos cost no image reads. The whole group must fit a 20-second window.
  Future<void> regroupSimilarPhotos() async {
    _groupTimer?.cancel();
    if (_grouping) { _groupAgain = true; return; }
    if (!groupSimilarPhotos || _resetting) return;
    _grouping = true;
    final revision = _groupRevision, generation = _generation;
    try {
      final locked = photoGroups.where((g) => g.manual).expand((g) => g.members).toSet();
      final candidates = items.where((it) => it.shown && it.copyOf == null &&
          !_keepSeparate.contains(it.key) && !locked.contains(it.key)).toList()
        ..sort((a, b) => b.taken.compareTo(a.taken));
      final groups = <PhotoGroup>[];
      PhotoGroup? current;
      PhotoItem? anchor;
      for (var i = 0; i < candidates.length; i++) {
        final it = candidates[i];
        final previous = i == 0 ? null : candidates[i - 1];
        if (previous == null || it.taken.difference(previous.taken).abs() > const Duration(seconds: 20)) {
          anchor = it; current = null; continue;
        }
        final first = anchor ?? previous;
        if (!_burstMetadata(first, it)) { anchor = it; current = null; continue; }
        for (final photo in [first, it]) {
          if (photo.burstPrint != null) continue;
          final pixels = await sourcePixels(photo, 192);
          if (pixels != null) photo.burstPrint = burstSignature(pixels);
          if (revision != _groupRevision || generation != _generation || !groupSimilarPhotos) return;
        }
        if (first.burstPrint != null && it.burstPrint != null && similarBurst(first.burstPrint!, it.burstPrint!)) {
          if (current == null) {
            current = PhotoGroup(id: first.key, cover: first.key, members: [first.key]);
            groups.add(current);
          }
          current.members.add(it.key);
        } else { anchor = it; current = null; }
      }
      if (revision != _groupRevision || generation != _generation) return;
      photoGroups.removeWhere((g) => !g.manual);
      photoGroups.addAll(groups);
      _save(); notifyListeners();
    } finally {
      _grouping = false;
      if (_groupAgain) { _groupAgain = false; _scheduleGrouping(); }
    }
  }

  static bool _burstMetadata(PhotoItem a, PhotoItem b) {
    if (a.taken.difference(b.taken).abs() > const Duration(seconds: 20)) return false;
    if ((a.width / a.height - b.width / b.height).abs() > .03) return false;
    if (a.hasLocation && b.hasLocation) {
      final latitude = (a.lat! + b.lat!) * math.pi / 360;
      final dx = (a.lng! - b.lng!) * math.cos(latitude), dy = a.lat! - b.lat!;
      if (math.sqrt(dx * dx + dy * dy) * 111000 > 50) return false;
    }
    return true;
  }

  // ------------------------------------------------------------ rendering

  final Map<String, Future<void>> _capturingSources = {};
  bool _checkingSources = false;
  Timer? _sourceCheckTimer;

  /// Let the first gallery frames and visible cache reads finish first.
  void scheduleSourceCheck() {
    _sourceCheckTimer?.cancel();
    _sourceCheckTimer = Timer(const Duration(seconds: 3), () {
      unawaited(backfillPhotoLocations());
      unawaited(checkSourceChanges(background: true));
    });
  }
  int openPhotoViews = 0;

  Future<void> ensureSource(PhotoItem item) async {
    if (item.sourceRevision != null) return;
    return _capturingSources.putIfAbsent(item.key, () async {
      final generation = _generation;
      final snapshot = await PhotoSource.capture(item.id);
      if (snapshot == null || generation != _generation || byKey(item.key) != item || item.sourceRevision != null) return;
      item.sourceRevision = snapshot.revision;
      item.baselineSourceRevision = snapshot.revision;
      item.sourceSize = snapshot.size;
      item.sourceModified = snapshot.modified;
      _save();
    }).whenComplete(() { _capturingSources.remove(item.key); });
  }

  Future<Rgba?> sourcePixels(PhotoItem item, int size) async {
    await ensureSource(item);
    return PhotoSource.pixels(item.sourceId, size);
  }

  Future<void> _attachReferences(PhotoItem item, Recipe recipe, {Rgba? pixels}) async {
    final generation = _generation;
    final revision = item.sourceRevision;
    final px = pixels ?? await sourcePixels(item, 384);
    if (px == null) return;
    final enriched = await withColorReferencesAsync(px, recipe);
    if (generation != _generation || byKey(item.key) != item || item.edit != recipe ||
        (revision != null && revision != item.sourceRevision)) { return; }
    item.edit = enriched;
    _save();
  }

  void saveSourceReview() { _save(); notifyListeners(); }

  void setFollowSourceChanges(bool value) {
    followSourceChanges = value;
    _save(); notifyListeners();
  }

  /// Scans are serialized and bounded to imported photos. They never invoke an
  /// agent. A missing historical source gets a new baseline, not a guessed edit.
  Future<void> checkSourceChanges({bool background = false}) async {
    if (_checkingSources || _resetting || !ready) return;
    _checkingSources = true;
    final generation = _generation;
    final changed = <PhotoItem>[];
    final captured = <String, ({String revision, int modified, List<int>? size})?>{};
    try {
      for (final item in List<PhotoItem>.of(items.where((it) => it.shown))) {
        if (background) await Future<void>.delayed(const Duration(milliseconds: 150));
        if (generation != _generation) return;
        if (byKey(item.key) != item || _held.contains(item.key) || _runs.containsKey(item.key)) continue;
        if (item.sourceRevision == null) {
          await ensureSource(item);
          continue;
        }
        // Tracking derives legacy/HEX evidence from the frozen source only
        // when an actual source change needs it. Do not decode every photo at launch.
        final stamp = await PhotoSource.currentVersion(item.id);
        if (stamp == null || stamp == item.sourceModified) continue;
        if (!captured.containsKey(item.id)) { captured[item.id] = await PhotoSource.capture(item.id); }
        final snapshot = captured[item.id];
        if (snapshot == null) continue;
        final oldEdit = item.edit, revision = item.sourceRevision;
        final before = await PhotoSource.pixels(item.sourceId, 192);
        final after = await PhotoSource.pixels('snapshot:${snapshot.revision}', 192);
        if (generation != _generation || byKey(item.key) != item || item.edit != oldEdit ||
            item.sourceRevision != revision || _held.contains(item.key) || _runs.containsKey(item.key)) { continue; }
        if (before == null || after == null) continue;
        item.sourceModified = snapshot.modified;
        if (snapshot.revision == revision) {
          item.pendingSource = null; item.pendingSize = null; item.pendingEdit = null; item.sourceReview = null;
          _save(); continue;
        }
        final result = oldEdit == null ? const SourceTrackingResult(null, 'Review the updated photo.') :
            await trackSourceAsync(before, after, oldEdit);
        if (generation != _generation || byKey(item.key) != item || item.edit != oldEdit ||
            item.sourceRevision != revision || _held.contains(item.key) || _runs.containsKey(item.key)) {
          item.sourceModified = null; continue;
        }
        item.pendingSource = snapshot.revision;
        item.pendingSize = snapshot.size;
        item.pendingEdit = result.recipe;
        item.sourceReview = result.reason;
        changed.add(item);
        if (followSourceChanges && result.canApply && openPhotoViews == 0) { applySourceUpdate(item); }
        _save(); notifyListeners();
      }
      if (changed.isNotEmpty) {
        final entry = _startActivity(ActivityKind.sourceUpdate, changed,
          request: 'Changes from Photos · processed on this device');
        for (final item in changed) { entry.finish(item.key, item.pendingSource == null ? ActivityOutcome.updated : ActivityOutcome.review); }
        _save(); notifyListeners();
      }
    } finally { _checkingSources = false; }
  }

  bool applySourceUpdate(PhotoItem item) {
    if (item.pendingSource == null || item.pendingEdit == null || _held.contains(item.key) ||
        _runs.containsKey(item.key) || byKey(item.key) != item) { return false; }
    item.previousSource = item.sourceRevision;
    item.previousSize = item.sourceSize;
    item.sourceSize = item.pendingSize;
    item.previousEdit = item.edit?.copy();
    item.sourceRevision = item.pendingSource;
    item.edit = item.pendingEdit;
    item.auto = null;
    item.pendingSource = null; item.pendingSize = null; item.pendingEdit = null; item.sourceReview = null;
    item.burstPrint = null;
    _palette = null; _scheduleGrouping(); _save(); notifyListeners();
    return true;
  }

  void keepSource(PhotoItem item) {
    item.pendingSource = null; item.pendingSize = null; item.pendingEdit = null; item.sourceReview = null;
    _save(); notifyListeners();
  }

  bool undoSourceUpdate(PhotoItem item) {
    if (item.previousSource == null || _held.contains(item.key) || _runs.containsKey(item.key)) return false;
    item.sourceRevision = item.previousSource;
    item.sourceSize = item.previousSize;
    item.previousSize = null;
    item.edit = item.previousEdit;
    item.previousSource = null; item.previousEdit = null;
    item.pendingSource = null; item.pendingSize = null; item.pendingEdit = null; item.sourceReview = null;
    item.auto = null; item.burstPrint = null;
    _palette = null; _scheduleGrouping(); _save(); notifyListeners();
    return true;
  }

  final Map<String, Future<File?>> _renders = {};
  final _renderWaiting = Queue<Completer<void>>();
  int _renderRunning = 0;

  /// A rendered JPEG of the photo with its edit, long side [size].
  Future<File?> rendered(PhotoItem it, int size, {Recipe? recipe}) {
    final r = recipe ?? it.edit;
    if (r == null) return Future.value(null);
    final key = '${it.sourceCacheId.replaceAll('/', '_')}_${r.signature}_$size';
    return _renders[key] ??= _renderItemToFile(it, r, size, '${_dir.path}/renders/$key.jpg');
  }

  Future<File?> _renderItemToFile(PhotoItem it, Recipe r, int size, String path) async {
    final f = File(path);
    if (await f.exists()) return f;
    // Disk hits bypass the queue. Bound expensive cache misses so scrolling
    // cannot launch a decoder + rendering isolate for every tile at once.
    if (_renderRunning >= 2) {
      final slot = Completer<void>();
      _renderWaiting.add(slot);
      await slot.future;
    } else {
      _renderRunning++;
    }
    try {
      final px = await sourcePixels(it, size);
      if (px == null) return null;
      final bytes = await _renderJpeg(px, r);
      await f.writeAsBytes(bytes);
      return f;
    } finally {
      if (_renderWaiting.isNotEmpty) { _renderWaiting.removeFirst().complete(); }
      else { _renderRunning--; }
    }
  }

  static Future<Uint8List> _renderJpeg(Rgba px, Recipe r) => Isolate.run(() {
      final out = render(px, r).image;
      final im = img.Image.fromBytes(width: out.width, height: out.height, bytes: out.pixels.buffer, numChannels: 4)
          .convert(numChannels: 3);
      return Uint8List.fromList(img.encodeJpg(im, quality: 88));
    });

  // Display requests must not capture a full-size source. Unfrozen legacy
  // items use the OS thumbnail until the background baseline is available.
  Future<Uint8List?> original(PhotoItem it, int size) => PhotoSource.jpeg(it.sourceId, size);

  late PhotoPatchCache _patchCache;

  Future<ui.Image?> patch(PhotoItem it, KeptColor c, {bool light = false}) {
    if (swatches == SwatchStyle.flat) return SynchronousFuture(null);
    return _patchCache.get(it.sourceCacheId, c, sourceId: it.sourceId, soft: swatches == SwatchStyle.soft, light: light);
  }

  /// Prints retain the source texture even when gallery swatches are flat.
  /// The returned handle belongs to the cache; callers must not dispose it.
  Future<ui.Image?> printPatch(PhotoItem it, KeptColor c) =>
      _patchCache.get(it.sourceCacheId, c, sourceId: it.sourceId);

  ({ui.Image? image})? patchReady(PhotoItem it, KeptColor c) {
    if (swatches == SwatchStyle.flat) return (image: null);
    return _patchCache.ready(it.sourceCacheId, c, soft: swatches == SwatchStyle.soft);
  }

}

class _Skipped implements Exception {}

const _sameNote = 'Same as another photo';

/// Explicit requests made before consent cannot silently turn into local AI.
class _ConsentRequiredAgent implements DevelopAgent {
  @override String get name => 'Cloud AI off';
  AgentError get _error => AgentError('Enable Cloud AI in Settings to use this feature.');
  @override Future<Recipe> develop(Rgba photo, {void Function(String)? log, AgentRun? run,
      ({int width, int height})? originalSize}) => Future.error(_error);
  @override Future<Verdict> judge(Rgba photo, {AgentRun? run}) => Future.error(_error);
  @override Future<Recipe> revise(Rgba photo, Recipe current, Revision request,
      {void Function(String)? log, AgentRun? run, ({int width, int height})? originalSize}) => Future.error(_error);
}
