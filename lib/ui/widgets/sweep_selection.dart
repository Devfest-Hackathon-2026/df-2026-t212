import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Range selection shared by the gallery and import picker. Tile keys mark
/// unscaled bounds; a gesture always works from its original selection snapshot.
class SweepSelection {
  SweepSelection({
    required this.scroll,
    required this.order,
    required this.selection,
    required this.onChanged,
    this.onStart,
    this.onStep,
    this.canSelect,
    this.insets,
  });

  final ScrollController scroll;
  final List<String> Function() order;
  final Set<String> Function() selection;
  final ValueChanged<Set<String>> onChanged;
  final VoidCallback? onStart;
  /// Feedback for a changed range, limited to once per 60 ms.
  final VoidCallback? onStep;
  final bool Function(String)? canSelect;
  final EdgeInsets Function()? insets;
  final viewportKey = GlobalKey();
  final Map<String, GlobalKey> _keys = {};
  Set<String> _before = {};
  String? _anchor;
  bool _adds = true;
  Offset? _finger;
  Timer? _timer;
  Timer? _feedbackTimer;
  int _generation = 0;

  GlobalKey keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);
  void retainKeys(Set<String> ids) => _keys.removeWhere((id, _) => !ids.contains(id));

  Rect? _bounds(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Rect? get _viewport {
    final bounds = _bounds(viewportKey);
    return bounds == null ? null : (insets?.call() ?? EdgeInsets.zero).deflateRect(bounds);
  }

  String? _photoAt(Offset position, {bool nearest = false}) {
    String? result;
    double distance = double.infinity;
    final viewport = _viewport;
    if (viewport == null) return null;
    for (final entry in _keys.entries) {
      final rect = _bounds(entry.value);
      if (rect == null || !rect.overlaps(viewport)) continue;
      if (rect.contains(position)) return entry.key;
      if (nearest) {
        final dx = position.dx - position.dx.clamp(rect.left, rect.right);
        final dy = position.dy - position.dy.clamp(rect.top, rect.bottom);
        final d = dx * dx + dy * dy;
        if (d < distance) { distance = d; result = entry.key; }
      }
    }
    return result;
  }

  void begin(Offset position) {
    final id = _photoAt(position);
    if (id == null || !(canSelect?.call(id) ?? true)) return;
    end();
    _before = Set.of(selection());
    _anchor = id;
    _adds = !_before.contains(id);
    onStart?.call();
    if (onStart != null) _cooldownFeedback();
    move(position);
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) => _scroll());
  }

  void move(Offset position) {
    if (_anchor == null) return;
    _finger = position;
    final viewport = _viewport;
    if (viewport == null || viewport.height <= 16) return;
    final y = position.dy.clamp(viewport.top + 8, viewport.bottom - 8);
    final id = _photoAt(Offset(position.dx, y), nearest: true);
    // Re-read order so an import sweep can continue into a newly loaded page.
    final ids = order();
    final start = ids.indexOf(_anchor!);
    final finish = ids.indexOf(id ?? '');
    if (start < 0 || finish < 0) return;
    final range = ids.sublist(start < finish ? start : finish, (start > finish ? start : finish) + 1)
        .where((id) => canSelect?.call(id) ?? true);
    final next = Set<String>.of(_before);
    if (_adds) { next.addAll(range); } else { next.removeAll(range); }
    if (!setEquals(next, selection())) {
      onChanged(next);
      if (_feedbackTimer == null && onStep != null) {
        onStep!();
        _cooldownFeedback();
      }
    }
  }

  void _cooldownFeedback() {
    _feedbackTimer = Timer(const Duration(milliseconds: 60), () => _feedbackTimer = null);
  }

  void _scroll() {
    final finger = _finger, viewport = _viewport;
    if (finger == null || viewport == null || !scroll.hasClients) return;
    final top = viewport.top + 52, bottom = viewport.bottom - 52;
    final speed = finger.dy < top ? -((top - finger.dy) / 64).clamp(0.0, 1.0)
        : finger.dy > bottom ? ((finger.dy - bottom) / 64).clamp(0.0, 1.0) : 0.0;
    if (speed == 0) return;
    final next = (scroll.offset + speed * 9).clamp(scroll.position.minScrollExtent, scroll.position.maxScrollExtent);
    if (next == scroll.offset) return;
    scroll.jumpTo(next);
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_generation == generation && _finger != null) move(_finger!);
    });
  }

  void end() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _feedbackTimer?.cancel();
    _feedbackTimer = null;
    _finger = null;
    _anchor = null;
  }

  void dispose() => end();
}
