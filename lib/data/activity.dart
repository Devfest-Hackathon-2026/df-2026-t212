enum ActivityKind { importBatch, autoImport, editRequest, developBatch }
enum ActivityOutcome { added, developed, skipped, failed, removed, cancelled }

/// One user-visible operation, not one notification per photograph.
class ActivityEntry {
  ActivityEntry({required this.id, required this.kind, required this.keys, required this.started,
    this.request, Map<String, ActivityOutcome>? outcomes, this.finished, this.read = false})
      : outcomes = outcomes ?? {};
  final String id;
  final ActivityKind kind;
  final List<String> keys;
  final DateTime started;
  final String? request;
  final Map<String, ActivityOutcome> outcomes;
  DateTime? finished;
  bool read;
  bool get complete => keys.every(outcomes.containsKey);
  int count(ActivityOutcome outcome) => outcomes.values.where((v) => v == outcome).length;
  String get title => switch(kind) {
    ActivityKind.importBatch => 'Import', ActivityKind.autoImport => 'Auto import', ActivityKind.editRequest => 'Agent edit', ActivityKind.developBatch => 'Auto develop',
  };
  void finish(String key, ActivityOutcome outcome) {
    if (!keys.contains(key) || outcomes.containsKey(key)) return;
    outcomes[key] = outcome;
    if (complete) { finished = DateTime.now(); read = false; }
  }
  Map<String, dynamic> toJson() => {
    'id': id, 'kind': kind.name, 'keys': keys, 'started': started.millisecondsSinceEpoch,
    'request': request, 'outcomes': outcomes.map((k, v) => MapEntry(k, v.name)),
    'finished': finished?.millisecondsSinceEpoch, 'read': read,
  };
  factory ActivityEntry.fromJson(Map<String, dynamic> j) => ActivityEntry(
    id: j['id'] as String, kind: ActivityKind.values.byName(j['kind'] as String),
    keys: (j['keys'] as List).cast<String>(), started: DateTime.fromMillisecondsSinceEpoch(j['started'] as int),
    request: j['request'] as String?,
    outcomes: Map<String, dynamic>.from(j['outcomes'] as Map).map((k, v) => MapEntry(k, ActivityOutcome.values.byName(v))),
    finished: j['finished'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['finished'] as int), read: j['read'] == true,
  );
}
