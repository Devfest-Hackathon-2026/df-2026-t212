import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../core/recipe.dart';
import '../data/places.dart';
import '../data/store.dart';
import 'detail.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Colors by place and time. A light, achromatic canvas so only the user's
/// colors carry color.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with SingleTickerProviderStateMixin {
  final s = Store.instance;
  final _map = MapController();
  double _zoom = 12;
  bool _fitted = false;

  // Time window, normalized over [_t0, _t1].
  double _w0 = 0, _w1 = 1;
  bool _playing = false;
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;
  _Cluster? _card;

  List<PhotoItem> get _located => s.visible.where((e) => e.hasLocation && e.state == Develop.done).toList();

  DateTime get _t0 {
    final l = _located;
    if (l.isEmpty) return DateTime.now().subtract(const Duration(days: 365));
    return l.map((e) => e.taken).reduce((a, b) => a.isBefore(b) ? a : b);
  }

  DateTime get _t1 {
    final l = _located;
    if (l.isEmpty) return DateTime.now();
    final m = l.map((e) => e.taken).reduce((a, b) => a.isAfter(b) ? a : b);
    return m.add(const Duration(hours: 1));
  }

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
    _ticker.dispose();
    super.dispose();
  }

  void _play() {
    Haptics.light();
    if (_playing) {
      _stop();
      return;
    }
    final len = (_w1 - _w0).clamp(0.08, 0.35);
    setState(() {
      _playing = true;
      _card = null;
      _w0 = 0;
      _w1 = len;
    });
    Shell.barHidden.value = true;
    _last = Duration.zero;
    _ticker.start();
  }

  void _stop() {
    _ticker.stop();
    Shell.barHidden.value = false;
    setState(() => _playing = false);
  }

  void _tick(Duration now) {
    final dt = (now - _last).inMicroseconds / 1e6;
    _last = now;
    if (dt <= 0 || dt > 0.2) return;
    const seconds = 14.0; // whole range
    final step = dt / seconds;
    setState(() {
      final len = _w1 - _w0;
      _w0 += step;
      _w1 = _w0 + len;
      if (_w1 >= 1) {
        _w1 = 1;
        _w0 = 1 - len;
        _stop();
      }
    });
  }

  void _fit(List<PhotoItem> located) {
    if (_fitted || located.isEmpty) return;
    _fitted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pts = located.map((e) => LatLng(e.lat!, e.lng!)).toList();
      if (pts.length == 1) {
        _map.move(pts.first, 14);
      } else {
        _map.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.fromLTRB(48, 120, 48, 220)));
      }
    });
  }

  /// Screen-grid clustering. Colors are never blended.
  List<_Cluster> _clusters(List<PhotoItem> items) {
    final cell = 44 * 360 / (256 * math.pow(2, _zoom));
    final map = <String, _Cluster>{};
    for (final it in items) {
      final k = '${(it.lng! / cell).floor()}:${(it.lat! / cell).floor()}';
      map.putIfAbsent(k, () => _Cluster()).items.add(it);
    }
    return map.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final located = _located;
        _fit(located);
        final inside = located.where(_inWindow).toList();
        final outside = located.where((e) => !_inWindow(e)).toList();
        final clusters = _clusters(inside);
        return Stack(children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: const LatLng(35.681, 139.767),
              initialZoom: 12,
              minZoom: 3,
              maxZoom: 16,
              backgroundColor: Neutral.bg,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
              onTap: (_, _) => setState(() => _card = null),
              onPositionChanged: (cam, _) {
                if ((cam.zoom - _zoom).abs() > 0.25) setState(() => _zoom = cam.zoom);
              },
            ),
            children: [
              TileLayer(
                // Esri's light grey canvas: no labels to fight the photos, no key needed.
                urlTemplate:
                    'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_Base/MapServer/tile/{z}/{y}/{x}',
                maxNativeZoom: 16,
                userAgentPackageName: 'io.github.pdhaku0.afterhue',
                tileBuilder: (context, tile, _) => ColorFiltered(colorFilter: _paper, child: tile),
              ),
              // Place names, set by hand in spaced capitals.
              MarkerLayer(markers: [
                for (final p in places)
                  if (_zoom >= p.minZoom && _zoom < p.maxZoom)
                    Marker(
                      key: ValueKey('place-${p.name}-${p.size}'),
                      point: LatLng(p.lat, p.lng),
                      width: 220,
                      height: 24,
                      child: IgnorePointer(child: Center(child: _PlaceLabel(p))),
                    ),
              ]),
              MarkerLayer(markers: [
                for (final it in outside)
                  Marker(
                    point: LatLng(it.lat!, it.lng!),
                    width: 6,
                    height: 6,
                    child: Container(decoration: const BoxDecoration(color: Color(0x33161616), shape: BoxShape.circle)),
                  ),
                for (final c in clusters)
                  Marker(
                    key: ValueKey(c.key),
                    point: c.center,
                    width: c.items.length == 1 ? 22 : 36,
                    height: c.items.length == 1 ? 22 : 36,
                    child: GestureDetector(
                      onTap: () {
                        Haptics.tick();
                        if (c.items.length > 1 && _zoom < 15) {
                          _map.move(c.center, math.min(18, _zoom + 2));
                        } else {
                          setState(() => _card = c);
                        }
                      },
                      child: _Rise(child: c.items.length == 1 ? SplitSwatch(c.items.first.hues, size: 20) : _Ring(c)),
                    ),
                  ),
              ]),
              if (_playing) MarkerLayer(markers: _floating(inside)),
              if (_card != null && !_playing)
                MarkerLayer(markers: [
                  Marker(
                    point: _card!.center,
                    width: 200,
                    height: 220,
                    alignment: Alignment.topCenter,
                    child: Align(alignment: Alignment.bottomCenter, child: Padding(padding: const EdgeInsets.only(bottom: 22), child: _card!.items.length == 1 ? _Card(_card!.items.first, all: located) : _Card(_card!.items.first, all: located, count: _card!.items.length))),
                  ),
                ]),
            ],
          ),
          // Title, quiet.
          Positioned(
            top: pad.top + 10,
            left: 20,
            child: AnimatedOpacity(
              opacity: _playing ? 0 : 1,
              duration: const Duration(milliseconds: 300),
              child: Text('Map', style: Txt.display),
            ),
          ),
          Positioned(
            top: pad.top + 26,
            right: 20,
            child: Text('Map data © Esri', style: Txt.mono.copyWith(fontSize: 9, color: Neutral.tertiary)),
          ),
          if (located.isEmpty)
            Center(
              child: Glass(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Text(
                  s.visible.isEmpty ? 'No developed photos yet.' : 'These photos have no location.',
                  style: Txt.small.copyWith(color: Neutral.primary),
                ),
              ),
            ),
          Positioned(
            left: 16,
            right: 16,
            bottom: pad.bottom + (_playing ? 16 : 82),
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 300),
              offset: Offset.zero,
              child: _Timeline(
                t0: _t0,
                t1: _t1,
                w0: _w0,
                w1: _w1,
                playing: _playing,
                items: located,
                norm: _norm,
                onWindow: (a, b) => setState(() {
                  _w0 = a;
                  _w1 = b;
                }),
                onPlay: _play,
              ),
            ),
          ),
        ]);
      },
    );
  }

  /// Favorite photos float as glass pins while their time is in the window.
  /// No queue: a photo shows only while it is in time.
  List<Marker> _floating(List<PhotoItem> inside) {
    var picks = inside.where((e) => e.favorite).toList();
    if (picks.length < 4) {
      final extra = inside.where((e) => !e.favorite).toList()..sort((a, b) => b.taken.compareTo(a.taken));
      picks = [...picks, ...extra];
    }
    final cell = 120 * 360 / (256 * math.pow(2, _zoom));
    final used = <String>{};
    final out = <Marker>[];
    for (final it in picks) {
      final k = '${(it.lng! / cell).floor()}:${(it.lat! / cell).floor()}';
      if (!used.add(k)) continue;
      out.add(Marker(
        key: ValueKey('pin-${it.key}'),
        point: LatLng(it.lat!, it.lng!),
        width: 132,
        height: 156,
        alignment: Alignment.topCenter,
        child: _Pin(it),
      ));
      if (out.length >= 4) break;
    }
    return out;
  }

  static const _paper = ColorFilter.matrix(<double>[
    0.2126 * 0.92, 0.7152 * 0.92, 0.0722 * 0.92, 0, 14,
    0.2126 * 0.92, 0.7152 * 0.92, 0.0722 * 0.92, 0, 14,
    0.2126 * 0.92, 0.7152 * 0.92, 0.0722 * 0.92, 0, 14,
    0, 0, 0, 1, 0,
  ]);
}

class _Cluster {
  final List<PhotoItem> items = [];
  String get key => items.map((e) => e.key).join('|').hashCode.toString();
  LatLng get center {
    final lat = items.map((e) => e.lat!).reduce((a, b) => a + b) / items.length;
    final lng = items.map((e) => e.lng!).reduce((a, b) => a + b) / items.length;
    return LatLng(lat, lng);
  }

  /// Distinct colors, never mixed.
  List<KeptColor> get colors {
    final out = <KeptColor>[];
    for (final it in items) {
      for (final c in it.hues) {
        if (out.every((o) => (o.hue - c.hue).abs() > 12 || (o.l - c.l).abs() > 0.15)) out.add(c);
      }
    }
    out.sort((a, b) => a.hue.compareTo(b.hue));
    return out.take(8).toList();
  }
}

/// Rises from a sunken position on a spring when it appears.
class _Rise extends StatelessWidget {
  const _Rise({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutBack,
      builder: (_, t, c) => Transform.translate(
        offset: Offset(0, (1 - t) * 6),
        child: Transform.scale(scale: 0.4 + 0.6 * t, child: Opacity(opacity: t.clamp(0, 1), child: c)),
      ),
      child: child,
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring(this.c);
  final _Cluster c;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _RingPainter(c.colors.map(colorOf).toList()),
      child: Center(child: Text('${c.items.length}', style: Txt.mono.copyWith(color: Neutral.primary, fontSize: 10, fontWeight: FontWeight.w600))),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.colors);
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 1;
    canvas.drawCircle(c + const Offset(0, 1.5), r, Paint()..color = const Color(0x22000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawCircle(c, r, Paint()..color = Neutral.surface);
    final rect = Rect.fromCircle(center: c, radius: r - 4);
    final sweep = 2 * math.pi / math.max(1, colors.length);
    final gap = colors.length > 1 ? 0.18 : 0.0;
    for (var i = 0; i < colors.length; i++) {
      canvas.drawArc(
        rect,
        -math.pi / 2 + i * sweep + gap / 2,
        sweep - gap,
        false,
        Paint()
          ..color = colors[i]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.5
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter o) => true;
}

class _Card extends StatelessWidget {
  const _Card(this.item, {required this.all, this.count = 1});
  final PhotoItem item;
  final List<PhotoItem> all;
  final int count;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(DetailRoute(items: all, index: all.indexOf(item))),
      child: Glass(
        radius: 18,
        padding: const EdgeInsets.all(6),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(width: 168, height: 126, child: DevelopedImage(item, size: 420)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (placeNear(item.lat, item.lng) case final name?)
                Text(count > 1 ? '$name  +${count - 1}' : name, style: Txt.label.copyWith(fontSize: 13.5)),
              const SizedBox(height: 2),
              Text(metaLine(item).split('  ·  ').first, style: Txt.mono.copyWith(fontSize: 10.5)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Glass bubble with a photo, pinned to where it was taken.
class _Pin extends StatelessWidget {
  const _Pin(this.item);
  final PhotoItem item;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutBack,
      builder: (_, t, c) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.scale(scale: 0.6 + 0.4 * t, alignment: Alignment.bottomCenter, child: c),
      ),
      child: Column(children: [
        Glass(
          radius: 16,
          padding: const EdgeInsets.all(4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 116,
                height: 84,
                child: ColorReturnOnce(duration: const Duration(milliseconds: 900), child: DevelopedImage(item, size: 320)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 5, 4, 2),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (placeNear(item.lat, item.lng) case final name?)
                  Text(name, style: Txt.label.copyWith(fontSize: 11.5)),
                Text(metaLine(item).split('  ·  ').first, style: Txt.mono.copyWith(fontSize: 8.5)),
              ]),
            ),
          ]),
        ),
        CustomPaint(size: const Size(14, 10), painter: _TailPainter()),
        Container(width: 6, height: 6, decoration: BoxDecoration(color: item.hues.isEmpty ? Neutral.primary : colorOf(item.hues.first), shape: BoxShape.circle, border: Border.all(color: Neutral.surface, width: 1.2))),
      ]),
    );
  }
}

class _TailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final p = Path()
      ..moveTo(0, 0)
      ..lineTo(s.width, 0)
      ..lineTo(s.width / 2, s.height)
      ..close();
    canvas.drawPath(p, Paint()..color = Neutral.glass);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Time axis with a window. Drag the middle to move, the ends to resize.
class _Timeline extends StatefulWidget {
  const _Timeline({
    required this.t0,
    required this.t1,
    required this.w0,
    required this.w1,
    required this.playing,
    required this.items,
    required this.norm,
    required this.onWindow,
    required this.onPlay,
  });
  final DateTime t0, t1;
  final double w0, w1;
  final bool playing;
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

  String _fmt(DateTime t) => '${monthsShort[t.month - 1]} ${t.day}';
  DateTime _at(double n) => DateTime.fromMillisecondsSinceEpoch(
      (widget.t0.millisecondsSinceEpoch + n * (widget.t1.millisecondsSinceEpoch - widget.t0.millisecondsSinceEpoch)).round());

  @override
  Widget build(BuildContext context) {
    return Glass(
      radius: 22,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Text('${_fmt(_at(widget.w0))} – ${_fmt(_at(widget.w1))}  ${_at(widget.w1).year}', style: Txt.mono.copyWith(color: Neutral.primary)),
          const Spacer(),
          TextAction(widget.playing ? 'Pause' : 'Play', onTap: widget.items.isEmpty ? null : widget.onPlay),
        ]),
        const SizedBox(height: 6),
        LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth - 8;
          void update(double dx, double ddx) {
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
              final x = d.localPosition.dx / w;
              final hs = 0.04;
              _grab = (x - widget.w0).abs() < hs ? 'start' : ((x - widget.w1).abs() < hs ? 'end' : 'move');
            },
            onHorizontalDragUpdate: (d) => update(d.localPosition.dx, d.delta.dx),
            onHorizontalDragEnd: (_) => _grab = null,
            child: CustomPaint(
              size: Size(box.maxWidth, 44),
              painter: _TimelinePainter(widget, _at),
            ),
          );
        }),
      ]),
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
    const top = 6.0, h = 24.0;
    // Month ticks.
    final tick = Paint()..color = Neutral.hairline..strokeWidth = 1;
    var m = DateTime(w.t0.year, w.t0.month + 1);
    var labelEnd = -1e9;
    while (m.isBefore(w.t1)) {
      final x = 4 + w.norm(m) * width;
      canvas.drawLine(Offset(x, top), Offset(x, top + h), tick);
      if (m.month == 1 || width / ((w.t1.difference(w.t0).inDays / 30).clamp(1, 400)) > 26) {
        final tp = TextPainter(
          text: TextSpan(text: m.month == 1 ? '${m.year}' : monthsShort[m.month - 1], style: Txt.mono.copyWith(fontSize: 8.5, color: Neutral.tertiary)),
          textDirection: TextDirection.ltr,
        )..layout();
        // Never let labels run into each other.
        if (x + 2 > labelEnd + 6) {
          tp.paint(canvas, Offset(x + 2, top + h + 2));
          labelEnd = x + 2 + tp.width;
        }
      }
      m = DateTime(m.year, m.month + 1);
    }
    // Every photo as a thin colored line.
    for (final it in w.items) {
      final x = 4 + w.norm(it.taken) * width;
      final inside = w.norm(it.taken) >= w.w0 && w.norm(it.taken) <= w.w1;
      final col = it.hues.isEmpty ? Neutral.secondary : colorOf(it.hues.first);
      canvas.drawLine(
        Offset(x, top + 5),
        Offset(x, top + h - 5),
        Paint()
          ..color = inside ? col : col.withValues(alpha: 0.25)
          ..strokeWidth = 1.6,
      );
    }
    // Window: achromatic frame.
    final r = RRect.fromLTRBR(4 + w.w0 * width, top, 4 + w.w1 * width, top + h, const Radius.circular(7));
    canvas.drawRRect(r, Paint()..color = const Color(0x14161616));
    canvas.drawRRect(r, Paint()..color = Neutral.primary..style = PaintingStyle.stroke..strokeWidth = 1.6);
    final handle = Paint()..color = Neutral.primary..strokeWidth = 2.4..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(r.left, top + 7), Offset(r.left, top + h - 7), handle);
    canvas.drawLine(Offset(r.right, top + 7), Offset(r.right, top + h - 7), handle);
  }

  @override
  bool shouldRepaint(_TimelinePainter o) => true;
}

// Keeps unused import warnings away when building for web.
// ignore: unused_element
final _unused = Timer;

class _PlaceLabel extends StatelessWidget {
  const _PlaceLabel(this.p);
  final Place p;

  @override
  Widget build(BuildContext context) {
    final style = switch (p.size) {
      2 => Txt.label.copyWith(fontSize: 17, letterSpacing: 7, fontWeight: FontWeight.w400, color: Neutral.secondary),
      1 => Txt.small.copyWith(fontSize: 10.5, letterSpacing: 3, color: Neutral.secondary),
      _ => Txt.small.copyWith(fontSize: 9.5, letterSpacing: 2.4, color: const Color(0xFF8A8A8A)),
    };
    return Text(
      p.name.toUpperCase(),
      maxLines: 1,
      style: style.copyWith(
        shadows: const [Shadow(color: Color(0xE6F5F5F4), blurRadius: 6)],
      ),
    );
  }
}
