import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:maplibre/maplibre.dart'
    show
        Geographic,
        LngLatBounds,
        MapController,
        MapCamera,
        MapEvent,
        MapEventClick,
        MapEventMapCreated,
        MapEventStyleLoaded,
        MapEventStartMoveCamera,
        CameraChangeReason,
        MapEventMoveCamera,
        MapGestures,
        MapLibreMap,
        MapOptions,
        Marker,
        WidgetLayer;

import '../core/recipe.dart';
import '../data/places.dart';
import '../data/store.dart';
import 'detail.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Colors by place and time. A light, achromatic canvas so only the user's
/// colors carry color: OpenFreeMap vector tiles drawn by MapLibre in our own
/// pale style (assets/map/style.json), with streets kept and names quiet.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final s = Store.instance;
  MapController? _map;
  double _zoom = 12;
  bool _fitted = false;
  bool _styled = false;
  bool _wandered = false; // the person has moved the map themself
  int _framedCount = 0;

  // Time window, normalized over [_t0, _t1].
  double _w0 = 0, _w1 = 1;
  bool _playing = false;
  bool _presenting = false;

  /// Photos currently held up on a card in playback.
  Set<String> _pinned = {};

  /// Markers that have already made their entrance.
  final Set<String> _risen = {};
  // Which photos were inside and outside the window on the last build, so a
  // photo crossing the window's edge can turn from one look into the other.
  Set<String> _wasInside = {}, _wasOutside = {};
  Set<String> _covered = {}; // photos whose places sit under a card
  double _speed = 1;
  int _playbackLayout = 0;
  (double, double)? _beforePlayback;
  DateTime _t0 = DateTime.now();
  DateTime _t1 = DateTime.now().add(const Duration(hours: 1));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _playing) _stop();
  }

  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;
  _Cluster? _card;

  List<PhotoItem> get _located =>
      s.visible.where((e) => e.hasLocation && e.state == Develop.done).toList();

  double _norm(DateTime t) {
    final a = _t0.millisecondsSinceEpoch, b = _t1.millisecondsSinceEpoch;
    return b == a ? 0.5 : (t.millisecondsSinceEpoch - a) / (b - a);
  }

  bool _inWindow(PhotoItem it) {
    final n = _norm(it.taken);
    return n >= _w0 - 1e-6 && n <= _w1 + 1e-6;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    super.dispose();
  }

  void _play() {
    Haptics.light();
    if (_playing) {
      _stop();
      return;
    }
    if (!_presenting) _beforePlayback = (_w0, _w1);
    final len = (_w1 - _w0) > 0.95 ? 0.24 : (_w1 - _w0);
    setState(() {
      _playing = true;
      _presenting = true;
      _card = null;
      if (_w1 >= 1 - 1e-6) {
        _w0 = 0;
        _playbackLayout++;
      }
      _w1 = (_w0 + len).clamp(0.0, 1.0);
    });
    Shell.barHidden.value = true;
    _last = Duration.zero;
    _ticker.start();
  }

  void _stop() {
    _ticker.stop();
    setState(() => _playing = false);
  }

  void _closePlayback() {
    _ticker.stop();
    setState(() {
      _playing = false;
      _presenting = false;
      _pinned = {};
      _covered = {};
      if (_beforePlayback case final range?) {
        _w0 = range.$1;
        _w1 = range.$2;
      }
      _beforePlayback = null;
    });
    Shell.barHidden.value = false;
  }

  void _tick(Duration now) {
    final dt = (now - _last).inMicroseconds / 1e6;
    _last = now;
    if (dt <= 0 || dt > 0.2) return;
    final len = _w1 - _w0;
    // A complete journey takes 24 seconds at 1×, independent of window width.
    setState(() {
      _w0 = (_w0 + dt * _speed * (1 - len) / 24).clamp(0.0, 1 - len);
      _w1 = _w0 + len;
      if (_w1 >= 1 - 1e-6) {
        _ticker.stop();
        _playing = false;
      }
    });
  }

  /// The part of the screen the controls leave free for the map.
  EdgeInsets _clear() {
    final pad = MediaQuery.paddingOf(context);
    return EdgeInsets.fromLTRB(
      44,
      pad.top + 84,
      44,
      pad.bottom + (_presenting ? 140 : 196),
    );
  }

  /// Frame [items] inside the free area. A single place gets a street-level view.
  void _frame(
    List<PhotoItem> items, {
    Duration duration = const Duration(milliseconds: 650),
  }) {
    final map = _map;
    if (map == null || items.isEmpty) return;
    final pts = items.map((e) => Geographic(lon: e.lng!, lat: e.lat!)).toList();
    final b = LngLatBounds.fromPoints(pts);
    final clear = _clear();
    if ((b.longitudeEast - b.longitudeWest).abs() < 1e-4 &&
        (b.latitudeNorth - b.latitudeSouth).abs() < 1e-4) {
      // Center in the free area, not the whole screen: at the target zoom,
      // shift the camera by half the difference between the margins.
      const zoom = 15.5;
      final p = pts.first;
      final perPoint = 360 / (512 * math.pow(2, zoom));
      final dx = (clear.left - clear.right) / 2,
          dy = (clear.top - clear.bottom) / 2;
      final center = Geographic(
        lon: p.lon - dx * perPoint,
        lat: p.lat + dy * perPoint * math.cos(p.lat * math.pi / 180),
      );
      map.animateCamera(center: center, zoom: zoom, nativeDuration: duration);
      return;
    }
    map.fitBounds(bounds: b, nativeDuration: duration, padding: clear);
  }

  void _fit(List<PhotoItem> located) {
    // Before the style is in, or while the tab is hidden (the native view has
    // no size then), the map ignores camera moves.
    if (located.isEmpty ||
        _map == null ||
        !_styled ||
        !TickerMode.valuesOf(context).enabled) {
      return;
    }
    // Photos arrive in batches; keep framing all of them until the person
    // takes the map into their own hands.
    if (_fitted && (_wandered || located.length == _framedCount)) return;
    final first = !_fitted;
    _fitted = true;
    _framedCount = located.length;
    // The native view takes a moment to get its size after the tab appears.
    Future.delayed(Duration(milliseconds: first ? 180 : 0), () {
      if (mounted) {
        _frame(
          located,
          duration: first ? Duration.zero : const Duration(milliseconds: 500),
        );
      }
    });
  }

  /// Open a card, moving the map just enough that the card and its point are in view.
  void _open(_Cluster c) {
    setState(() => _card = c);
    final map = _map;
    if (map == null) return;
    final size = MediaQuery.sizeOf(context);
    final clear = _clear();
    final p = map.toScreenLocation(c.center);
    // The card stands about 240 points above its point and is 180 wide.
    final room = Rect.fromLTRB(
      clear.left + 60,
      clear.top + 240,
      size.width - clear.right - 60,
      size.height - clear.bottom,
    );
    if (room.contains(p)) return;
    final want = Offset(
      p.dx.clamp(room.left, room.right),
      p.dy.clamp(room.top, room.bottom),
    );
    final center = map.toLngLat(size.center(Offset.zero) + (p - want));
    map.animateCamera(
      center: center,
      nativeDuration: const Duration(milliseconds: 420),
    );
  }

  DateTime _followedAt = DateTime(0);

  /// While playing, keep the photos of the moment on screen.
  void _follow(List<PhotoItem> inside) {
    final map = _map;
    if (map == null || inside.isEmpty) return;
    final now = DateTime.now();
    if (now.difference(_followedAt) < const Duration(milliseconds: 1400)) {
      return;
    }
    final size = MediaQuery.sizeOf(context);
    final clear = _clear();
    final room = Rect.fromLTRB(
      clear.left,
      clear.top,
      size.width - clear.right,
      size.height - clear.bottom,
    );
    final pts = map.toScreenLocations([
      for (final it in inside) Geographic(lon: it.lng!, lat: it.lat!),
    ]);
    if (pts.every(room.contains)) return;
    _followedAt = now;
    _frame(inside, duration: const Duration(milliseconds: 1100));
  }

  void _onEvent(MapEvent e) {
    switch (e) {
      case MapEventMapCreated(:final mapController):
        setState(() => _map = mapController);
      case MapEventStartMoveCamera(reason: CameraChangeReason.apiGesture):
        _wandered = true;
      case MapEventStyleLoaded():
        setState(() => _styled = true);
      case MapEventMoveCamera(:final camera):
        if ((camera.zoom - _zoom).abs() > 0.15) {
          setState(() => _zoom = camera.zoom);
        }
      case MapEventClick():
        if (_card != null) setState(() => _card = null);
      default:
    }
  }

  /// Screen-grid clustering. Colors are never blended.
  /// Dots stay apart for as long as they can be counted. Overlap is fine,
  /// even welcome: it says "these were close". Photos merge only where they
  /// sit on the same spot, or where so many pile up that the eye can no
  /// longer tell how many there are.
  List<_Cluster> _clusters(List<PhotoItem> items) {
    if (items.isEmpty) return [];
    // Screen points in Web Mercator at the current zoom (512 px tiles).
    final world = 512 * math.pow(2, _zoom).toDouble();
    final pts = [
      for (final it in items)
        Offset(
          (it.lng! + 180) / 360 * world,
          (1 -
                  math.log(
                        math.tan(it.lat! * math.pi / 180) +
                            1 / math.cos(it.lat! * math.pi / 180),
                      ) /
                      math.pi) /
              2 *
              world,
        ),
    ];
    const pile = 22.0; // about one dot across
    const pileCount = 5; // past this, a heap of dots is unreadable
    const same = 6.0; // centers this close are one spot
    final n = items.length;
    final near = List.generate(
      n,
      (i) => [
        for (var j = 0; j < n; j++)
          if ((pts[i] - pts[j]).distance <= pile) j,
      ],
    );
    final taken = List.filled(n, false);
    final out = <_Cluster>[];
    // Densest heaps first.
    final order = List.generate(n, (i) => i)
      ..sort((a, b) => near[b].length.compareTo(near[a].length));
    for (final i in order) {
      if (taken[i]) continue;
      final free = [
        for (final j in near[i])
          if (!taken[j]) j,
      ];
      if (free.length < pileCount) continue;
      final c = _Cluster();
      for (final j in free) {
        taken[j] = true;
        c.items.add(items[j]);
      }
      out.add(c);
    }
    // What is left stays single, unless it shares a spot.
    for (final i in order) {
      if (taken[i]) continue;
      taken[i] = true;
      final c = _Cluster()..items.add(items[i]);
      for (var j = 0; j < n; j++) {
        if (!taken[j] && (pts[i] - pts[j]).distance <= same) {
          taken[j] = true;
          c.items.add(items[j]);
        }
      }
      out.add(c);
    }
    // Older below, newer on top.
    int newest(_Cluster c) =>
        c.items.map((e) => e.taken.millisecondsSinceEpoch).reduce(math.max);
    out.sort((a, b) => newest(a).compareTo(newest(b)));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final located = _located;
        if (located.isNotEmpty) {
          _t0 = located
              .map((e) => e.taken)
              .reduce((a, b) => a.isBefore(b) ? a : b);
          _t1 = located
              .map((e) => e.taken)
              .reduce((a, b) => a.isAfter(b) ? a : b)
              .add(const Duration(hours: 1));
        }
        _fit(located);
        final inside = located.where(_inWindow).toList();
        final outside = located.where((e) => !_inWindow(e)).toList();
        final clusters = _clusters(
          _presenting
              ? inside.where((e) => !_pinned.contains(e.key)).toList()
              : inside,
        );
        if (_playing) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _follow(inside));
        }
        // A marker that leaves rises anew when it comes back.
        _risen.retainAll({
          for (final c in clusters) c.key,
          for (final k in _pinned) 'dot$k',
        });
        final wasInside = _wasInside, wasOutside = _wasOutside;
        _wasInside = {for (final e in inside) e.key};
        _wasOutside = {for (final e in outside) e.key};
        return Stack(
          children: [
            MapLibreMap(
              options: MapOptions(
                initStyle: 'assets/map/style.json',
                initCenter: Geographic(lon: 139.767, lat: 35.681),
                initZoom: 12,
                minZoom: 3,
                maxZoom: 18,
                gestures: const MapGestures(
                  rotate: false,
                  pan: true,
                  zoom: true,
                  pitch: false,
                ),
              ),
              onEvent: _onEvent,
              children: [
                // Photos outside the time window: faint dots, not tappable.
                WidgetLayer(
                  markers: [
                    for (final it in outside)
                      Marker(
                        point: Geographic(lon: it.lng!, lat: it.lat!),
                        size: const Size(6, 6),
                        child: AnimatedOpacity(
                          key: ValueKey(it.key),
                          opacity: _presenting && _covered.contains(it.key)
                              ? 0
                              : 1,
                          duration: const Duration(milliseconds: 220),
                          child: _Fall(
                            it.hues,
                            animate: wasInside.contains(it.key),
                          ),
                        ),
                      ),
                  ],
                ),
                WidgetLayer(
                  allowInteraction: true,
                  markers: [
                    for (final c in clusters)
                      Marker(
                        point: c.center,
                        size: Size.square(
                          c.items.length == 1 ? 22 : c.diameter + 14,
                        ),
                        child: GestureDetector(
                          key: ValueKey(c.key),
                          onTap: () {
                            Haptics.tick();
                            if (c.items.length > 1 && _zoom < 17 && c.spread) {
                              // Open the group up so every photo in it gets its own place.
                              setState(() => _card = null);
                              _frame(
                                c.items,
                                duration: const Duration(milliseconds: 520),
                              );
                            } else {
                              _open(c);
                            }
                          },
                          child: AnimatedOpacity(
                            // Under a card's glass, out of the way.
                            opacity:
                                _presenting &&
                                    c.items.every(
                                      (e) => _covered.contains(e.key),
                                    )
                                ? 0
                                : 1,
                            duration: const Duration(milliseconds: 220),
                            child: _Rise(
                              animate: _risen.add(c.key),
                              fromDot:
                                  c.items.length == 1 &&
                                  wasOutside.contains(c.items.first.key),
                              child: c.items.length == 1
                                  ? SplitSwatch(c.items.first.hues, size: 20)
                                  : _Stack(c),
                            ),
                          ),
                        ),
                      ),

                    // In playback the photos speak for themselves; their
                    // places are plain points for the cards to stand on.
                    if (_presenting)
                      for (final it in inside.where(
                        (e) => _pinned.contains(e.key),
                      ))
                        Marker(
                          point: Geographic(lon: it.lng!, lat: it.lat!),
                          size: const Size.square(_dotR * 2 + 2),
                          child: _Rise(
                            key: ValueKey('dot${it.key}'),
                            animate: _risen.add('dot${it.key}'),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Neutral.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Neutral.surface,
                                  width: 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                    if (_card != null && !_presenting)
                      Marker(
                        point: _card!.center,
                        size: const Size(200, 220),
                        alignment: Alignment.bottomCenter,
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 22),
                            child: _Card(
                              _card!.items.first,
                              all: located,
                              count: _card!.items.length,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                if (_presenting)
                  _PlaybackPhotos(
                    key: ValueKey(_playbackLayout),
                    items: inside,
                    faint: outside,
                    norm: _norm,
                    w0: _w0,
                    w1: _w1,
                    onPinned: (keys, covered) {
                      if (!mounted ||
                          (setEquals(keys, _pinned) &&
                              setEquals(covered, _covered))) {
                        return;
                      }
                      setState(() {
                        _pinned = keys;
                        _covered = covered;
                      });
                    },
                  ),
              ],
            ),
            // Title, quiet.
            Positioned(
              top: pad.top + 10,
              left: 20,
              child: AnimatedOpacity(
                opacity: _presenting ? 0 : 1,
                duration: const Duration(milliseconds: 300),
                child: Text('Map', style: Txt.display),
              ),
            ),
            if (_presenting)
              Positioned(
                top: pad.top + 8,
                left: 16,
                child: Glass(
                  radius: 24,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: TextAction('Done', onTap: _closePlayback),
                ),
              ),
            // Show everything again after wandering off.
            Positioned(
              top: pad.top + 14,
              right: 16,
              child: AnimatedOpacity(
                opacity: _presenting || located.isEmpty ? 0 : 1,
                duration: const Duration(milliseconds: 300),
                child: IgnorePointer(
                  ignoring: _presenting || located.isEmpty,
                  child: Glass(
                    radius: 22,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        Haptics.light();
                        setState(() => _card = null);
                        _frame(located);
                      },
                      child: SizedBox.square(
                        dimension: 44,
                        child: Center(
                          child: CustomPaint(
                            size: const Size.square(18),
                            painter: _FramePainter(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (located.isEmpty)
              Center(
                child: Glass(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  child: Text(
                    s.visible.isEmpty
                        ? 'No developed photos yet.'
                        : 'These photos have no location.',
                    style: Txt.small.copyWith(color: Neutral.primary),
                  ),
                ),
              ),
            AnimatedPositioned(
              duration: Duration(milliseconds: reduceMotion ? 0 : 360),
              curve: Curves.easeOutCubic,
              left: 16,
              right: 16,
              bottom: pad.bottom + (_presenting ? 16 : 82),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Credit for the map data, kept out of the way of names and photos.
                  Padding(
                    padding: const EdgeInsets.only(right: 10, bottom: 6),
                    child: Text(
                      '© OpenMapTiles  © OpenStreetMap',
                      style: Txt.mono.copyWith(
                        fontSize: 8.5,
                        color: Neutral.tertiary,
                      ),
                    ),
                  ),
                  _Timeline(
                    t0: _t0,
                    t1: _t1,
                    w0: _w0,
                    w1: _w1,
                    playing: _playing,
                    presenting: _presenting,
                    speed: _speed,
                    onSpeed: () => setState(
                      () =>
                          _speed = _speed == 0.5 ? 1 : (_speed == 1 ? 2 : 0.5),
                    ),
                    onScrubStart: () {
                      if (_playing) _stop();
                      if (_presenting) setState(() => _playbackLayout++);
                    },
                    items: located,
                    norm: _norm,
                    onWindow: (a, b) => setState(() {
                      _w0 = a;
                      _w1 = b;
                    }),
                    onPlay: _play,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Project into screen space so cards cannot overlap each other or the controls.
class _PlaybackPhotos extends StatefulWidget {
  const _PlaybackPhotos({
    super.key,
    required this.onPinned,
    required this.items,
    required this.faint,
    required this.norm,
    required this.w0,
    required this.w1,
  });
  final List<PhotoItem> items;
  final List<PhotoItem> faint; // outside the window, drawn as faint dots
  final double Function(DateTime) norm;
  final double w0, w1;

  /// The photos on cards, and the photos whose places sit under a card's
  /// body, after each layout.
  final void Function(Set<String> pinned, Set<String> covered) onPinned;

  @override
  State<_PlaybackPhotos> createState() => _PlaybackPhotosState();
}

class _PlaybackPhotosState extends State<_PlaybackPhotos> {
  Set<String> _visibleKeys = {};

  @override
  Widget build(BuildContext context) {
    MapCamera.of(context); // Reproject when the map is panned or zoomed.
    final controller = MapController.of(context);
    final pad = MediaQuery.paddingOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        final picks = [...widget.items]
          ..sort((a, b) {
            // Keep cards already on screen until they leave the time window.
            final aVisible = _visibleKeys.contains(a.key),
                bVisible = _visibleKeys.contains(b.key);
            if (aVisible != bVisible) return aVisible ? -1 : 1;
            if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
            final time = a.taken.compareTo(b.taken);
            return time != 0 ? time : a.key.compareTo(b.key);
          });
        final offsets = controller.toScreenLocations(
          picks.map((it) => Geographic(lon: it.lng!, lat: it.lat!)).toList(),
        );
        final safe = Rect.fromLTRB(
          12,
          pad.top + 58,
          box.maxWidth - 12,
          box.maxHeight - pad.bottom - 150,
        );
        final used = <Rect>[];
        final bodies = <Rect>[];
        final children = <Widget>[];
        final visibleKeys = <String>{};
        final w0 = widget.w0, w1 = widget.w1;
        for (var i = 0; i < picks.length; i++) {
          final point = offsets[i];
          if (!safe.contains(point)) continue;
          // A card stands a little to one side of its place, leaning in
          // toward the middle of the screen, so its tail comes down at a
          // slant as a hand-drawn balloon's would, not plumb.
          final lean = point.dx < box.maxWidth / 2 ? 30.0 : -30.0;
          final left = (point.dx - 66 + lean)
              .clamp(safe.left, math.max(safe.left, safe.right - 132))
              .toDouble();
          final below = point.dy - _pinH < safe.top;
          final rect = Rect.fromLTWH(
            left,
            below ? point.dy : point.dy - _pinH,
            132,
            _pinH,
          );
          if (rect.bottom > safe.bottom) continue;
          if (used.any((r) => r.inflate(10).overlaps(rect))) continue;
          final it = picks[i];
          final n = widget.norm(it.taken);
          final fade = math.min(0.025, (w1 - w0) * 0.12);
          final entering = w0 <= 1e-6 ? 1.0 : ((n - w0) / fade).clamp(0.0, 1.0);
          final leaving = w1 >= 1 - 1e-6
              ? 1.0
              : ((w1 - n) / fade).clamp(0.0, 1.0);
          used.add(rect);
          bodies.add(
            Rect.fromLTWH(
              rect.left,
              below ? rect.top + _tailH + _dotR : rect.top,
              rect.width,
              _bodyH,
            ),
          );
          visibleKeys.add(it.key);
          children.add(
            Positioned(
              key: ValueKey(it.key),
              left: rect.left,
              top: rect.top,
              width: rect.width,
              height: rect.height,
              child: IgnorePointer(
                child: _Pin(
                  it,
                  visibility: Curves.easeInOut.transform(
                    math.min(entering, leaving),
                  ),
                  below: below,
                  tipX: point.dx - left,
                ),
              ),
            ),
          );
          if (children.length == 4) break;
        }
        _visibleKeys = visibleKeys;
        // The map's native blur frosts only the tiles, not the markers drawn
        // over them, so markers under a card would show through it sharp.
        // Name them, so they can step aside while the card is up.
        final others = controller.toScreenLocations(
          widget.faint
              .map((it) => Geographic(lon: it.lng!, lat: it.lat!))
              .toList(),
        );
        bool under(Offset p) => bodies.any((r) => r.inflate(8).contains(p));
        final covered = <String>{
          for (var i = 0; i < picks.length; i++)
            if (!visibleKeys.contains(picks[i].key) && under(offsets[i]))
              picks[i].key,
          for (var i = 0; i < widget.faint.length; i++)
            if (under(others[i])) widget.faint[i].key,
        };
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => widget.onPinned(visibleKeys, covered),
        );
        // One backdrop capture shared by every card's frost.
        return BackdropGroup(
          child: Stack(clipBehavior: Clip.none, children: children),
        );
      },
    );
  }
}

class _Cluster {
  final List<PhotoItem> items = [];

  /// A heap grows with what it holds, by area rather than by width, so a
  /// big one stays a size the eye can still weigh. It is drawn after the
  /// grouping is done and never feeds back into it, so a large dot does
  /// not reach out and swallow its neighbours.
  double get diameter =>
      (24 + 7 * (math.log(items.length / 2) / math.ln2)).clamp(24.0, 54.0);
  String get key => items.map((e) => e.key).join('|').hashCode.toString();

  /// Whether the photos were taken in more than one spot (about 15 m apart).
  bool get spread {
    final lats = items.map((e) => e.lat!), lngs = items.map((e) => e.lng!);
    return lats.reduce(math.max) - lats.reduce(math.min) > 1.4e-4 ||
        lngs.reduce(math.max) - lngs.reduce(math.min) > 1.4e-4;
  }

  Geographic get center {
    final lat = items.map((e) => e.lat!).reduce((a, b) => a + b) / items.length;
    final lng = items.map((e) => e.lng!).reduce((a, b) => a + b) / items.length;
    return Geographic(lon: lng, lat: lat);
  }

  /// Distinct colors, never mixed.
  List<KeptColor> get colors {
    final out = <KeptColor>[];
    for (final it in items) {
      for (final c in it.hues) {
        if (out.every(
          (o) => (o.hue - c.hue).abs() > 12 || (o.l - c.l).abs() > 0.15,
        )) {
          out.add(c);
        }
      }
    }
    out.sort((a, b) => a.hue.compareTo(b.hue));
    return out.take(8).toList();
  }
}

/// A marker settles into place without an overshoot.
const _faintDot = BoxDecoration(
  color: Color(0x33161616),
  shape: BoxShape.circle,
);

class _Rise extends StatelessWidget {
  const _Rise({
    super.key,
    required this.child,
    this.animate = true,
    this.fromDot = false,
  });
  final Widget child;

  /// The photo was a faint dot outside the time window a moment ago: the
  /// same dot grows into its colors, rather than one thing replacing another.
  final bool fromDot;

  /// False for a marker that has risen before. The map's marker layer keeps
  /// markers by position, so one shifting in the list is built anew; it
  /// should not rise a second time.
  final bool animate;

  @override
  Widget build(BuildContext context) {
    if (animate && fromDot) {
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Duration(
          milliseconds: MediaQuery.disableAnimationsOf(context) ? 120 : 520,
        ),
        curve: Curves.easeInOutCubic,
        builder: (_, t, c) => t >= 1
            ? c!
            : Transform.scale(
                scale: 6 / 20 + (1 - 6 / 20) * t,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Opacity(opacity: t, child: c),
                    Opacity(
                      opacity: 1 - t,
                      child: const SizedBox.square(
                        dimension: 20,
                        child: DecoratedBox(decoration: _faintDot),
                      ),
                    ),
                  ],
                ),
              ),
        child: child,
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: animate ? 0 : 1, end: 1),
      duration: Duration(
        milliseconds: MediaQuery.disableAnimationsOf(context) ? 120 : 360,
      ),
      curve: Curves.easeOutCubic,
      builder: (_, t, c) => Opacity(
        opacity: t,
        child: Transform.scale(
          scale: MediaQuery.disableAnimationsOf(context) ? 1 : 0.82 + 0.18 * t,
          child: c,
        ),
      ),
      child: child,
    );
  }
}

/// A photo leaving the time window: its colors draw back into a faint dot.
class _Fall extends StatelessWidget {
  const _Fall(this.hues, {required this.animate});
  final List<KeptColor> hues;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: animate ? 0 : 1, end: 1),
      duration: Duration(
        milliseconds: MediaQuery.disableAnimationsOf(context) ? 120 : 520,
      ),
      curve: Curves.easeInOutCubic,
      builder: (_, t, _) => t >= 1
          ? const DecoratedBox(decoration: _faintDot)
          : OverflowBox(
              minWidth: 20,
              maxWidth: 20,
              minHeight: 20,
              maxHeight: 20,
              child: Transform.scale(
                scale: 1 - (1 - 6 / 20) * t,
                child: Stack(
                  children: [
                    Opacity(opacity: 1 - t, child: SplitSwatch(hues, size: 20)),
                    Opacity(
                      opacity: t,
                      child: const SizedBox.expand(
                        child: DecoratedBox(decoration: _faintDot),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// Several photos in one spot: the same swatch as a single photo, with a
/// second card peeking out behind it and the count on its corner.
class _Stack extends StatelessWidget {
  const _Stack(this.c);
  final _Cluster c;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        // A second dot peeking from behind says "more than one".
        Transform.translate(
          offset: Offset(-c.diameter * 0.19, -c.diameter * 0.12),
          child: Container(
            width: c.diameter - 2,
            height: c.diameter - 2,
            decoration: const BoxDecoration(
              color: Neutral.surface,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Color(0x24000000),
                  blurRadius: 5,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
        SplitSwatch(c.colors.take(6).toList(), size: c.diameter, border: 2.2),
        Positioned(
          right: -5,
          top: -5,
          child: Container(
            constraints: const BoxConstraints(minWidth: 17),
            height: 17,
            padding: const EdgeInsets.symmetric(horizontal: 4.5),
            decoration: BoxDecoration(
              color: Neutral.primary,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: Neutral.surface, width: 1.4),
            ),
            alignment: Alignment.center,
            child: Text(
              '${c.items.length}',
              style: Txt.mono.copyWith(
                color: Neutral.surface,
                fontSize: 9,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Four corners of a frame: "show everything".
class _FramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = Neutral.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    const k = 5.5;
    final w = s.width, h = s.height;
    for (final (x, y, dx, dy) in [
      (0.0, 0.0, 1.0, 1.0),
      (w, 0.0, -1.0, 1.0),
      (0.0, h, 1.0, -1.0),
      (w, h, -1.0, -1.0),
    ]) {
      canvas.drawPath(
        Path()
          ..moveTo(x, y + dy * k)
          ..lineTo(x, y)
          ..lineTo(x + dx * k, y),
        p,
      );
    }
    canvas.drawCircle(
      Offset(w / 2, h / 2),
      1.6,
      Paint()..color = Neutral.primary,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _Card extends StatelessWidget {
  const _Card(this.item, {required this.all, this.count = 1});
  final PhotoItem item;
  final List<PhotoItem> all;
  final int count;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () =>
          Navigator.of(context)
              .push(DetailRoute(items: all, index: all.indexOf(item))),
      child: Glass(
        radius: 18,
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 168,
                height: 126,
                child: DevelopedImage(item, size: 420),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (placeNear(item.lat, item.lng) case final name?)
                    Text(
                      count > 1 ? '$name  +${count - 1}' : name,
                      style: Txt.label.copyWith(fontSize: 13.5),
                    ),
                  const SizedBox(height: 2),
                  Text(
                    metaLine(item).split('  ·  ').first,
                    style: Txt.mono.copyWith(fontSize: 10.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Glass bubble with a photo, pinned to where it was taken.
const _bodyH = 156.0;
const _tailH = 30.0;
const _dotR = 4.0;
const _pinH = _bodyH + _tailH + _dotR;

/// A photo held above its place. Body and tail are one shape, so the
/// frosting, the fill and the shadow are continuous from corner to tip.
class _Pin extends StatelessWidget {
  const _Pin(
    this.item, {
    required this.below,
    required this.tipX,
    required this.visibility,
  });
  final PhotoItem item;
  final bool below;
  final double tipX, visibility;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final bodyTop = below ? _tailH + _dotR : 0.0;
    final tipY = below ? _dotR : _bodyH + _tailH;
    Path shape(Size s) => _bubble(s.width, bodyTop, tipX, tipY);
    // The part of the tail outside the body.
    Path tailOnly(Size s) => Path.combine(
      PathOperation.difference,
      _tail(s.width, bodyTop, tipX, tipY),
      Path()..addRRect(
        RRect.fromLTRBR(
          0,
          bodyTop,
          s.width,
          bodyTop + _bodyH,
          const Radius.circular(16),
        ),
      ),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: reduceMotion ? 160 : 560),
      curve: Curves.easeOutQuint,
      builder: (_, entrance, content) {
        final presence = math.min(entrance, visibility);
        // Glass cannot fade: a backdrop blur under Opacity sees nothing, and
        // a blur eased toward zero breaks into stray edges. So the glass
        // keeps its full frost and only grows out of its point and draws
        // back into it; the photo fades on it in the meantime. Arriving,
        // the glass opens first; leaving, the photo goes first.
        final glass = Curves.easeInOutCubic.transform(
          (presence / 0.5).clamp(0.0, 1.0),
        );
        final ink = ((presence - 0.45) / 0.55).clamp(0.0, 1.0);
        if (glass < 0.01) return const SizedBox.shrink();
        return Transform.scale(
          scale: glass,
          alignment: Alignment(
            (tipX / 132 * 2 - 1).clamp(-1.0, 1.0),
            below ? -1 : 1,
          ),
          child: Stack(
            children: [
              // Frost under the body only. Over the map's native view a path
              // clip does not bound a backdrop blur (it frosts the whole
              // bounding box), and strips of blur read as steps; the slim
              // tail is denser glass instead, painted below.
              Positioned(
                left: 0,
                right: 0,
                top: bodyTop,
                height: _bodyH,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter.grouped(
                    filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: _BubblePaint(
                    shape,
                    tailOnly,
                    below ? bodyTop : bodyTop + _bodyH,
                    tipY,
                    1,
                  ),
                  child: Opacity(
                    opacity: ink,
                    child: ImageFiltered(
                      enabled: !reduceMotion && entrance < 1,
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: (1 - entrance) * 2,
                        sigmaY: (1 - entrance) * 2,
                      ),
                      child: content,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      child: Padding(
        padding: EdgeInsets.only(top: bodyTop),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            height: _bodyH,
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: SizedBox(
                      width: 122,
                      height: 98,
                      child: DevelopedImage(item, size: 320),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 2, 0),
                    child: SizedBox(
                      width: 116,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  placeNear(item.lat, item.lng) ?? ' ',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Txt.label.copyWith(fontSize: 11.5),
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  metaLine(item).split('  ·  ').first,
                                  maxLines: 1,
                                  overflow: TextOverflow.fade,
                                  softWrap: false,
                                  style: Txt.mono.copyWith(fontSize: 8.5),
                                ),
                              ],
                            ),
                          ),
                          // The kept colors, as on the gallery tile.
                          for (final c in item.hues.take(3))
                            Padding(
                              padding: const EdgeInsets.only(left: 3, top: 2),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(3.5),
                                  boxShadow: const [tileShadow],
                                ),
                                child: Swatch(c, size: 10, from: item),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded body plus a tail that narrows with concave sides to the tip.
Path _bubble(double w, double bodyTop, double tipX, double tipY) {
  final body = RRect.fromLTRBR(
    0,
    bodyTop,
    w,
    bodyTop + _bodyH,
    const Radius.circular(16),
  );
  return Path.combine(
    PathOperation.union,
    Path()..addRRect(body),
    _tail(w, bodyTop, tipX, tipY),
  );
}

Path _tail(double w, double bodyTop, double tipX, double tipY) {
  const r = 16.0, half = 11.0;
  final up = tipY < bodyTop; // tail points up when the card sits below
  final baseY = up ? bodyTop + 2 : bodyTop + _bodyH - 2;
  // The tail leaves the body between the card's middle and the point, so
  // it leans by about half of the card's offset.
  final bx = (tipX + (w / 2 - tipX) * 0.5)
      .clamp(r + half, w - r - half)
      .toDouble();
  double lerp(double a, double b, double t) => a + (b - a) * t;
  return Path()
    ..moveTo(bx - half, baseY)
    ..quadraticBezierTo(
      lerp(bx - half, tipX, 0.8),
      lerp(baseY, tipY, 0.3),
      tipX,
      tipY,
    )
    ..quadraticBezierTo(
      lerp(bx + half, tipX, 0.8),
      lerp(baseY, tipY, 0.3),
      bx + half,
      baseY,
    )
    ..close();
}

/// A soft shadow outside the shape only, so it never greys the glass, and
/// the fill of body and tail together.
class _BubblePaint extends CustomPainter {
  _BubblePaint(this.shape, this.tail, this.edge, this.tipY, this.presence);
  final Path Function(Size) shape, tail;
  final double edge, tipY; // where the tail leaves the body, and its point
  final double presence;

  @override
  void paint(Canvas canvas, Size size) {
    if (presence <= 0) return;
    final path = shape(size);
    canvas.save();
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect((Offset.zero & size).inflate(40)),
        path,
      ),
    );
    canvas.drawPath(
      path.shift(const Offset(0, 4)),
      Paint()
        ..color = Color.fromRGBO(0, 0, 0, 0.2 * presence)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    canvas.restore();
    canvas.drawPath(
      path,
      Paint()..color = Color.fromRGBO(250, 250, 249, 0.72 * presence),
    );
    // The tail has no frost behind it, and a native blur cannot be
    // feathered, so where it leaves the body it is near opaque in the
    // frost's own tone: the map's detail must not start at the body's
    // edge. Toward the point it thins to glass again.
    const frost = Color(0xFFF6F6F5);
    canvas.drawPath(
      tail(size),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, edge),
          Offset(0, edge + (tipY - edge).sign * 26),
          [
            frost.withValues(alpha: 0.9 * presence),
            frost.withValues(alpha: 0.5 * presence),
          ],
        ),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = Color.fromRGBO(255, 255, 255, 0.7 * presence),
    );
  }

  @override
  bool shouldRepaint(_BubblePaint old) => old.presence != presence;
}

/// Time axis with a window. Drag the middle to move, the ends to resize.
class _Timeline extends StatefulWidget {
  const _Timeline({
    required this.t0,
    required this.t1,
    required this.w0,
    required this.w1,
    required this.playing,
    required this.presenting,
    required this.speed,
    required this.onSpeed,
    required this.onScrubStart,
    required this.items,
    required this.norm,
    required this.onWindow,
    required this.onPlay,
  });
  final DateTime t0, t1;
  final double w0, w1;
  final bool playing, presenting;
  final double speed;
  final VoidCallback onSpeed, onScrubStart;
  final List<PhotoItem> items;
  final double Function(DateTime) norm;
  final void Function(double, double) onWindow;
  final VoidCallback onPlay;

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  String? _grab; // 'start' | 'end' | 'move'
  int? _lastMonth;

  String _fmt(DateTime t) =>
      '${monthsShort[t.month - 1]} ${t.day}${_at(widget.w0).year != _at(widget.w1).year ? ' ${t.year}' : ''}';
  DateTime _at(double n) => DateTime.fromMillisecondsSinceEpoch(
    (widget.t0.millisecondsSinceEpoch +
            n *
                (widget.t1.millisecondsSinceEpoch -
                    widget.t0.millisecondsSinceEpoch))
        .round(),
  );

  @override
  Widget build(BuildContext context) {
    return Glass(
      radius: 22,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_fmt(_at(widget.w0))} – ${_fmt(_at(widget.w1))}${_at(widget.w0).year == _at(widget.w1).year ? '  ${_at(widget.w1).year}' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Txt.mono.copyWith(
                    color: Neutral.primary,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ),
              if (widget.presenting)
                TextAction(
                  '${widget.speed == 0.5 ? '0.5' : widget.speed.toInt()}×',
                  onTap: widget.onSpeed,
                ),
              TextAction(
                widget.playing
                    ? 'Pause'
                    : (widget.presenting && widget.w1 >= 1 - 1e-6
                          ? 'Replay'
                          : 'Play'),
                onTap: widget.items.isEmpty ? null : widget.onPlay,
              ),
            ],
          ),
          const SizedBox(height: 2),
          LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth - 8;
              void update(double ddx) {
                var a = widget.w0, b = widget.w1;
                final d = ddx / w;
                switch (_grab) {
                  case 'start':
                    a = (a + d).clamp(0.0, b - 0.03);
                  case 'end':
                    b = (b + d).clamp(a + 0.03, 1.0);
                  default:
                    final len = b - a;
                    a = (a + d).clamp(0.0, 1 - len);
                    b = a + len;
                }
                final m = _at((a + b) / 2).month;
                if (_lastMonth != null && m != _lastMonth) Haptics.tick();
                _lastMonth = m;
                widget.onWindow(a, b);
              }

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (d) {
                  widget.onScrubStart();
                  final x = (d.localPosition.dx - 4) / w;
                  final ds = (x - widget.w0).abs(), de = (x - widget.w1).abs();
                  final hs = 22 / w;
                  _grab = math.min(ds, de) < hs
                      ? (ds < de ? 'start' : 'end')
                      : 'move';
                },
                onHorizontalDragUpdate: (d) => update(d.delta.dx),
                onHorizontalDragEnd: (_) => _grab = null,
                child: CustomPaint(
                  size: Size(box.maxWidth, 44),
                  painter: _TimelinePainter(widget, _at),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.w, this.at);
  final _Timeline w;
  final DateTime Function(double) at;

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width - 8;
    const trackY = 15.0;
    final start = 4 + w.w0 * width;
    final end = 4 + w.w1 * width;
    canvas.drawLine(
      Offset(4, trackY),
      Offset(4 + width, trackY),
      Paint()
        ..color = Neutral.hairline
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      Offset(start, trackY),
      Offset(end, trackY),
      Paint()
        ..color = const Color(0xFFC3BCCF)
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );

    var m = DateTime(w.t0.year, w.t0.month + 1);
    var labelEnd = -1e9;
    while (m.isBefore(w.t1)) {
      final x = 4 + w.norm(m) * width;
      if (m.month == 1 ||
          width / ((w.t1.difference(w.t0).inDays / 30).clamp(1, 400)) > 26) {
        final tp = TextPainter(
          text: TextSpan(
            text: m.month == 1 ? '${m.year}' : monthsShort[m.month - 1],
            style: Txt.mono.copyWith(fontSize: 9.5, color: Neutral.secondary),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        // Never let labels run into each other or off the end.
        if (x + 2 > labelEnd + 6 && x + 2 + tp.width <= size.width) {
          tp.paint(canvas, Offset(x + 2, 28));
          labelEnd = x + 2 + tp.width;
        }
      }
      m = DateTime(m.year, m.month + 1);
    }
    // Photo dates are colored points along the track.
    for (final it in w.items) {
      final n = w.norm(it.taken);
      final inside = n >= w.w0 && n <= w.w1;
      final col = it.hues.isEmpty ? Neutral.secondary : colorOf(it.hues.first);
      canvas.drawCircle(
        Offset(4 + n * width, trackY),
        2.3,
        Paint()..color = inside ? col : col.withValues(alpha: 0.30),
      );
    }
    final fill = Paint()..color = Neutral.surface;
    final outline = Paint()
      ..color = const Color(0xFFAAA2B8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final x in [start, end]) {
      canvas.drawCircle(Offset(x, trackY), 5.5, fill);
      canvas.drawCircle(Offset(x, trackY), 5.5, outline);
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter o) => true;
}
