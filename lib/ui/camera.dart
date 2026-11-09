import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/recipe.dart';
import '../core/renderer.dart';
import '../data/live_camera.dart';
import '../data/photo_source.dart';
import '../data/store.dart';
import 'edit.dart';
import 'theme.dart';
import 'widgets/common.dart';

class CameraRoute extends PageRouteBuilder<void> {
  CameraRoute()
    : super(
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, _, _) => const CameraScreen(),
        transitionsBuilder: (_, a, _, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
            CurvedAnimation(parent: a, curve: Motion.settle, reverseCurve: Curves.easeInCubic),
          ),
          child: child,
        ),
      );
}

/// Taking a photo with the look already on it. The viewfinder is developed
/// live, so what is kept in color is chosen while framing, not after. The
/// shutter saves the original to the library; After Hue keeps the look.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  LiveFeed? _feed;
  String? _error;
  final Recipe _r = Recipe();

  /// The slot a tap fills: a kept color, or the empty slot after them.
  int _active = 0;
  bool _panel = false;

  /// Strong colors in view now.
  List<KeptColor> _candidates = [];

  /// The person has chosen a color; nothing is chosen for them after that.
  bool _chosen = false;
  Timer? _scan;

  Offset? _loupe; // normalized
  KeptColor? _loupeColor;
  ui.Image? _loupeImage;
  static const _loupeSize = 112.0, _loupeZoom = 3.0;
  bool _sampling = false;
  final List<_Ping> _pings = [];
  int _pingId = 0;

  PhotoItem? _last;
  bool _shooting = false;
  bool _flash = false;

  int get _addSlot => _r.colors.length < Recipe.maxColors ? _r.colors.length : -1;
  KeptColor? get _cur => _active < _r.colors.length ? _r.colors[_active] : null;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _scan?.cancel();
    _loupeImage?.dispose();
    LiveCamera.stop();
    super.dispose();
  }

  Future<void> _start() async {
    LiveFeed feed;
    try {
      await LiveCamera.look(_r);
      feed = await LiveCamera.start();
    } on PlatformException catch (e) {
      if (e.code != 'unavailable') return _fail(e.code);
      // No camera here (the Simulator): a photo from the library stands in.
      final still = await _stillPath();
      if (still == null) return _fail(e.code);
      try {
        feed = await LiveCamera.start(still: still);
      } on PlatformException catch (e) {
        return _fail(e.code);
      }
    }
    if (!mounted) {
      unawaited(LiveCamera.stop());
      return;
    }
    setState(() => _feed = feed);
    // Let exposure settle before reading the colors.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    await _scanView();
    _scan = Timer.periodic(const Duration(milliseconds: 2500), (_) => _scanView());
  }

  void _fail(String code) {
    if (!mounted) return;
    setState(
      () => _error = code == 'denied'
          ? 'Camera access is off.\nTurn it on in Settings to take photos here.'
          : 'The camera is not available on this device.',
    );
  }

  static Future<String?> _stillPath() async {
    final items = Store.instance.items;
    if (items.isEmpty) return null;
    final it = items.firstWhere((e) => e.hues.isNotEmpty, orElse: () => items.first);
    final bytes = await PhotoSource.jpeg(it.id, 1600);
    if (bytes == null) return null;
    final f = File('${(await getTemporaryDirectory()).path}/camera-still.jpg');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  /// Finds the strong colors in view, the most subject-like first: strong,
  /// and near the middle. Nothing is kept for the person; the view stays in
  /// full color until they choose.
  Future<void> _scanView() async {
    final px = await LiveCamera.thumb();
    if (px == null || !mounted) return;
    final lab = toLab(px);
    final peaks = huePeaks(lab, top: 8).where((p) => p.meanChroma > 0.04).toList();
    double score(HuePeak p) {
      final d = math.sqrt(math.pow(p.center[0] - 0.5, 2) + math.pow(p.center[1] - 0.5, 2));
      return p.share * (1 - 0.8 * (d / 0.71).clamp(0.0, 1.0)) * (0.5 + p.meanChroma * 4);
    }

    peaks.sort((a, b) => score(b).compareTo(score(a)));
    KeptColor color(HuePeak p) {
      final h = (p.from + p.to) / 2 * math.pi / 180;
      return KeptColor(l: p.meanL, a: p.meanChroma * math.cos(h), b: p.meanChroma * math.sin(h));
    }

    setState(() => _candidates = peaks.take(6).map(color).toList());
  }

  void _look() => LiveCamera.look(_r);

  /// Keeps [c]: in place of the chosen color, or as a new one.
  void _pick(KeptColor c, {Offset? at}) {
    _chosen = true;
    Haptics.tick();
    setState(() {
      final cur = _cur;
      if (cur != null) {
        cur
          ..l = c.l
          ..a = c.a
          ..b = c.b;
      } else if (_addSlot >= 0) {
        _r.colors.add(c);
        _active = _r.colors.length - 1;
      }
      if (at != null) _ping(at, colorOf(c));
    });
    _look();
  }

  void _ping(Offset at, Color color) {
    final id = _pingId++;
    _pings.add(_Ping(id, at, color));
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _pings.removeWhere((e) => e.id == id));
    });
  }

  void _remove(int i) {
    _chosen = true;
    Haptics.light();
    setState(() {
      _r.colors.removeAt(i);
      _active = _r.colors.length < Recipe.maxColors ? _r.colors.length : _r.colors.length - 1;
    });
    _look();
  }

  /// Reads the original under the finger for the loupe, one read at a time.
  Future<void> _sampleLoupe(Size view) async {
    final at = _loupe, feed = _feed;
    if (at == null || feed == null || _sampling) return;
    _sampling = true;
    // The loupe shows a third of its width of the view, enlarged.
    final side = (_loupeSize / _loupeZoom * feed.width / view.width).round();
    final l = await LiveCamera.loupe(at.dx, at.dy, side: side);
    ui.Image? image;
    if (l != null) {
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(l.pixels, l.side, l.side, ui.PixelFormat.rgba8888, done.complete);
      image = await done.future;
    }
    _sampling = false;
    if (!mounted || _loupe == null) {
      image?.dispose();
      return;
    }
    final old = _loupeImage;
    setState(() {
      _loupeColor = l?.color;
      _loupeImage = image;
    });
    old?.dispose();
    // The finger moved while reading: catch up.
    if (_loupe != at) unawaited(_sampleLoupe(view));
  }

  Future<void> _shoot() async {
    if (_shooting || _feed == null) return;
    Haptics.firm();
    final look = _r.copy();
    setState(() {
      _shooting = true;
      _flash = true;
    });
    Future.delayed(const Duration(milliseconds: 90), () {
      if (mounted) setState(() => _flash = false);
    });
    try {
      final s = await LiveCamera.capture();
      final it = Store.instance.addCaptured(
        id: s.id,
        taken: s.taken,
        width: s.width,
        height: s.height,
        lat: s.lat,
        lng: s.lng,
        recipe: look,
      );
      if (mounted) setState(() => _last = it);
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Neutral.primary,
          content: Text(
            switch (e.code) {
              'library' => 'Saving to Photos is not allowed.',
              'unavailable' => 'There is no camera on this device.',
              _ => 'The photo could not be taken.',
            },
            style: Txt.small.copyWith(color: Neutral.surface),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _shooting = false);
    }
  }

  // ------------------------------------------------------------ layout
  //
  // After the camera in the reference: a dark room, the view in the middle,
  // everything that shapes the look laid on the view itself.

  static const _bg = Color(0xFF232323);
  static const _ink = Color(0xFFF2F2F0);
  static const _dim = Color(0xFF8E8E8C);

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemBarsDark,
      child: Scaffold(
        backgroundColor: _bg,
        body: Padding(
          padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
          child: LayoutBuilder(
            builder: (context, box) {
              const top = 60.0, hint = 44.0, bottom = 110.0;
              final aspect = _feed?.aspect ?? 3 / 4;
              final w = box.maxWidth - 12;
              final h = math.min(w / aspect, box.maxHeight - top - hint - bottom);
              return Column(
                children: [
                  SizedBox(height: top, width: double.infinity, child: _topBar()),
                  SizedBox(height: h, width: h * aspect, child: _viewfinder()),
                  SizedBox(height: hint, child: _hint()),
                  const Spacer(),
                  SizedBox(height: bottom, child: _bottom()),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned(
          left: 14,
          child: GestureDetector(
            onTap: () {
              Haptics.light();
              Navigator.pop(context);
            },
            child: const Glass(
              dark: true,
              radius: 16,
              child: SizedBox(
                width: 46,
                height: 36,
                child: Icon(Icons.chevron_left_rounded, size: 26, color: _ink),
              ),
            ),
          ),
        ),
        _chips(),
      ],
    );
  }

  /// The kept colors: a dot each, the chosen one with its hex; a dashed dot
  /// to add another.
  Widget _chips() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _r.colors.length; i++) _chip(i),
        if (_addSlot >= 0)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              Haptics.tick();
              setState(() => _active = _addSlot);
            },
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CustomPaint(painter: _DashedDot(strong: _active == _addSlot)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _chip(int i) {
    final c = _r.colors[i];
    final sel = i == _active;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Haptics.tick();
        setState(() => _active = i);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Motion.settle,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: EdgeInsets.fromLTRB(6, 5, sel ? 4 : 6, 5),
        decoration: BoxDecoration(
          color: sel ? const Color(0x1FFFFFFF) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: colorOf(c),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x33FFFFFF), width: 0.6),
              ),
            ),
            if (sel) ...[
              const SizedBox(width: 7),
              Text(
                oklabToHex(c.l, c.a, c.b).toUpperCase(),
                style: Txt.mono.copyWith(color: _ink, fontSize: 12),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _remove(i),
                child: const Padding(
                  padding: EdgeInsets.only(left: 4, right: 2),
                  child: Icon(Icons.close_rounded, size: 14, color: _dim),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _hint() {
    final show = _feed != null && !_chosen;
    return Center(
      child: AnimatedOpacity(
        opacity: show || _error != null ? 1 : 0,
        duration: const Duration(milliseconds: 300),
        child: Text(
          _error ?? 'Hold the view on a color to keep it',
          textAlign: TextAlign.center,
          style: Txt.small.copyWith(color: _dim),
        ),
      ),
    );
  }

  Widget _viewfinder() {
    final feed = _feed;
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        Offset norm(Offset p) => Offset((p.dx / size.width).clamp(0.0, 1.0), (p.dy / size.height).clamp(0.0, 1.0));
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: feed == null
              ? null
              : (d) async {
                  if (_panel) {
                    setState(() => _panel = false);
                    return;
                  }
                  final n = norm(d.localPosition);
                  final c = await LiveCamera.sample(n.dx, n.dy);
                  if (c != null && mounted) _pick(c, at: d.localPosition);
                },
          onLongPressStart: feed == null
              ? null
              : (d) {
                  Haptics.light();
                  setState(() {
                    _panel = false;
                    _loupe = norm(d.localPosition);
                  });
                  _sampleLoupe(size);
                },
          onLongPressMoveUpdate: (d) {
            if (_loupe == null) return;
            final n = norm(d.localPosition);
            if (_loupe != null && (n - _loupe!).distance > 0.02) Haptics.tick();
            setState(() => _loupe = n);
            _sampleLoupe(size);
          },
          onLongPressEnd: (d) {
            final c = _loupeColor;
            final old = _loupeImage;
            setState(() {
              _loupe = null;
              _loupeColor = null;
              _loupeImage = null;
            });
            old?.dispose();
            if (c != null) _pick(c, at: d.localPosition);
          },
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(border: Border.all(color: const Color(0x24FFFFFF), width: 0.6)),
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: const Color(0xFF161616),
                    child: feed == null ? null : Texture(textureId: feed.texture, filterQuality: FilterQuality.medium),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _flash ? 0.85 : 0,
                      duration: Duration(milliseconds: _flash ? 40 : 260),
                      child: const ColoredBox(color: Colors.white),
                    ),
                  ),
                ),
                for (final p in _pings) _PingRing(key: ValueKey(p.id), ping: p),
                if (_loupe != null) _loupeWidget(Offset(_loupe!.dx * size.width, _loupe!.dy * size.height), size),
                Positioned(left: 0, right: 0, bottom: 0, child: _reachPanel()),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 14,
                  child: Center(child: _reachPill()),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// How far the chosen color reaches, at a glance; opens the panel.
  Widget _reachPill() {
    final c = _cur;
    final hidden = _feed == null || _panel;
    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedOpacity(
        opacity: hidden ? 0 : 1,
        duration: const Duration(milliseconds: 220),
        child: GestureDetector(
          onTap: () {
            Haptics.tick();
            setState(() => _panel = true);
          },
          child: Glass(
            dark: true,
            radius: 16,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(
              c == null ? 'Colors in view' : 'Width ${c.width.round()}  ·  Edge ${c.softness.round()}',
              style: Txt.small.copyWith(color: _ink, fontSize: 12.5),
            ),
          ),
        ),
      ),
    );
  }

  /// Laid over the lower view: how far the color reaches, and the colors in
  /// view to keep instead.
  Widget _reachPanel() {
    final c = _cur;
    final open = _panel;
    return IgnorePointer(
      ignoring: !open,
      child: AnimatedSlide(
        offset: open ? Offset.zero : const Offset(0, 0.15),
        duration: const Duration(milliseconds: 320),
        curve: Motion.settle,
        child: AnimatedOpacity(
          opacity: open ? 1 : 0,
          duration: const Duration(milliseconds: 220),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Glass(
              dark: true,
              radius: 20,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (c != null) ...[
                    _darkSlider('Width', c.width, 16, (v) => c.width = v),
                    _darkSlider('Edge', c.softness, 20, (v) => c.softness = v),
                    const SizedBox(height: 6),
                  ],
                  Text('In view', style: Txt.mono.copyWith(color: _dim)),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 26,
                    child: Row(
                      children: [
                        for (final k in _candidates)
                          Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: GestureDetector(
                              onTap: () => _pick(k.copy()),
                              child: Container(
                                width: 26,
                                height: 26,
                                decoration: BoxDecoration(
                                  color: colorOf(k),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: const Color(0x33FFFFFF), width: 0.6),
                                ),
                              ),
                            ),
                          ),
                        if (_candidates.isEmpty) Text('No strong colors.', style: Txt.small.copyWith(color: _dim)),
                      ],
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

  Widget _darkSlider(String label, double value, double def, void Function(double) set) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          SizedBox(width: 52, child: Text(label, style: Txt.small.copyWith(color: _ink))),
          Expanded(
            child: _DarkSlider(
              value: value / 60,
              def: def / 60,
              onChanged: (t) {
                setState(() => set(t * 60));
                _look();
              },
            ),
          ),
          SizedBox(
            width: 30,
            child: Text('${value.round()}', textAlign: TextAlign.right, style: Txt.mono.copyWith(color: _dim)),
          ),
        ],
      ),
    );
  }

  /// Held above the finger, as in Edit: the scene under it enlarged and in
  /// its own colors, ringed with the color that will be kept.
  Widget _loupeWidget(Offset p, Size box) {
    const d = _loupeSize;
    final c = _loupeColor, image = _loupeImage;
    final top = p.dy - d - 36 < 0 ? p.dy + 36 : p.dy - d - 36;
    return Positioned(
      left: (p.dx - d / 2).clamp(0, box.width - d),
      top: top,
      child: IgnorePointer(
        child: Container(
          width: d,
          height: d,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF161616),
            border: Border.all(color: c == null ? _ink : colorOf(c), width: 5),
            boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 14, offset: Offset(0, 4))],
          ),
          child: ClipOval(child: CustomPaint(painter: _LoupePainter(image))),
        ),
      ),
    );
  }

  Widget _bottom() {
    final last = _last;
    return Row(
      children: [
        Expanded(
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 320),
              switchInCurve: Motion.settle,
              transitionBuilder: (child, a) => ScaleTransition(
                scale: Tween(begin: 0.6, end: 1.0).animate(a),
                child: FadeTransition(opacity: a, child: child),
              ),
              child: last == null
                  ? const SizedBox(width: 48, height: 48)
                  : GestureDetector(
                      key: ValueKey(last.key),
                      onTap: () {
                        Haptics.light();
                        Navigator.push(context, EditRoute(last));
                      },
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0x55FFFFFF), width: 1),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(9),
                          child: DevelopedImage(last, size: 160),
                        ),
                      ),
                    ),
            ),
          ),
        ),
        _Shutter(busy: _shooting, onTap: _feed == null ? null : _shoot),
        const Expanded(child: SizedBox()),
      ],
    );
  }
}

class _Shutter extends StatefulWidget {
  const _Shutter({required this.busy, required this.onTap});
  final bool busy;
  final VoidCallback? onTap;

  @override
  State<_Shutter> createState() => _ShutterState();
}

class _ShutterState extends State<_Shutter> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    return GestureDetector(
      onTapDown: on ? (_) => setState(() => _down = true) : null,
      onTapCancel: () => setState(() => _down = false),
      onTapUp: on
          ? (_) {
              setState(() => _down = false);
              widget.onTap!();
            }
          : null,
      child: Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: on ? const Color(0xFFF2F2F0) : const Color(0xFF5A5A5A), width: 3),
        ),
        alignment: Alignment.center,
        child: AnimatedScale(
          scale: _down ? 0.86 : 1,
          duration: const Duration(milliseconds: 120),
          curve: Motion.settle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: !on
                  ? const Color(0xFF3A3A3A)
                  : widget.busy
                  ? const Color(0xFF9A9A98)
                  : const Color(0xFFF2F2F0),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoupePainter extends CustomPainter {
  _LoupePainter(this.image);
  final ui.Image? image;

  @override
  void paint(Canvas canvas, Size size) {
    final im = image;
    if (im != null) {
      canvas.drawImageRect(
        im,
        Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble()),
        Offset.zero & size,
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    final c = size.center(Offset.zero);
    final p = Paint()
      ..color = const Color(0xCCFFFFFF)
      ..strokeWidth = 1;
    canvas.drawLine(c - const Offset(6, 0), c + const Offset(6, 0), p);
    canvas.drawLine(c - const Offset(0, 6), c + const Offset(0, 6), p);
  }

  @override
  bool shouldRepaint(_LoupePainter o) => o.image != image;
}

/// A slider for the dark panel: a hairline track and a soft pill thumb.
class _DarkSlider extends StatelessWidget {
  const _DarkSlider({required this.value, required this.def, required this.onChanged});
  final double value, def;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        void set(double dx) {
          final t = (dx / w).clamp(0.0, 1.0);
          if ((value - def).sign != (t - def).sign) Haptics.tick();
          onChanged(t);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => set(d.localPosition.dx),
          onTapUp: (d) => set(d.localPosition.dx),
          child: CustomPaint(size: Size(w, 36), painter: _DarkSliderPainter(value.clamp(0, 1), def)),
        );
      },
    );
  }
}

class _DarkSliderPainter extends CustomPainter {
  _DarkSliderPainter(this.t, this.def);
  final double t, def;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    const r = 9.0;
    final x = r + (size.width - 2 * r) * t;
    final track = Paint()
      ..color = const Color(0x33FFFFFF)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(r, y), Offset(size.width - r, y), track);
    canvas.drawLine(Offset(r, y), Offset(x, y), track..color = const Color(0xCCF2F2F0));
    canvas.drawCircle(Offset(r + (size.width - 2 * r) * def, y), 1.6, Paint()..color = const Color(0x88FFFFFF));
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, y), width: 26, height: 20), const Radius.circular(10)),
      Paint()..color = const Color(0xFFE6E6E4),
    );
  }

  @override
  bool shouldRepaint(_DarkSliderPainter o) => o.t != t;
}

/// The empty dot a new color goes into.
class _DashedDot extends CustomPainter {
  _DashedDot({required this.strong});
  final bool strong;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = strong ? const Color(0xFFF2F2F0) : const Color(0xFF7A7A78)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final c = s.center(Offset.zero);
    final r = s.width / 2 - 0.6;
    const n = 12;
    for (var i = 0; i < n; i++) {
      final a = i * 2 * math.pi / n;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), a, math.pi / n, false, p);
    }
    canvas.drawLine(c - const Offset(4, 0), c + const Offset(4, 0), p);
    canvas.drawLine(c - const Offset(0, 4), c + const Offset(0, 4), p);
  }

  @override
  bool shouldRepaint(_DashedDot o) => o.strong != strong;
}

class _Ping {
  _Ping(this.id, this.at, this.color);
  final int id;
  final Offset at;
  final Color color;
}

/// A ring where the view was tapped, in the color that was picked.
class _PingRing extends StatelessWidget {
  const _PingRing({super.key, required this.ping});
  final _Ping ping;

  @override
  Widget build(BuildContext context) {
    const d = 84.0;
    return Positioned(
      left: ping.at.dx - d / 2,
      top: ping.at.dy - d / 2,
      width: d,
      height: d,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 650),
          curve: Motion.settle,
          builder: (context, t, _) => Opacity(
            opacity: (1 - t).clamp(0, 1),
            child: Transform.scale(
              scale: 0.35 + 0.65 * t,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: ping.color, width: 4),
                  boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 6)],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
