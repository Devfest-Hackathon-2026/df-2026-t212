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
          position: Tween(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: a, curve: Motion.settle, reverseCurve: Curves.easeInCubic)),
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
  bool _blink = false;

  // The lens, as the person has set it.
  double _zoom = 1;
  double? _pinchFrom;
  bool _pinching = false;
  Offset? _focusAt; // in the view
  bool _locked = false;
  double _bias = 0;
  bool _focusQuiet = false;
  Timer? _focusFade;
  String _flashMode = 'auto';
  int _timer = 0;
  int _count = 0;
  Timer? _countdown;
  bool _grid = false;
  int _mp = 0;
  bool _options = false;
  bool _flipping = false;

  /// How far the controls turn to stay upright as the phone turns.
  double _turns = 0;

  int get _addSlot => _r.colors.length < Recipe.maxColors ? _r.colors.length : -1;
  KeptColor? get _cur => _active < _r.colors.length ? _r.colors[_active] : null;

  @override
  void initState() {
    super.initState();
    // The screen stays upright, as the system camera's does; the controls
    // turn instead.
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    LiveCamera.listen(_onEvent);
    _start();
  }

  @override
  void dispose() {
    _scan?.cancel();
    _focusFade?.cancel();
    _countdown?.cancel();
    _loupeImage?.dispose();
    LiveCamera.listen(null);
    LiveCamera.stop();
    SystemChrome.setPreferredOrientations([]);
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
    _mp = feed.resolutions.contains(24)
        ? 24
        : feed.resolutions.contains(12)
        ? 12
        : 0;
    if (feed.live) {
      unawaited(LiveCamera.resolution(_mp));
      unawaited(LiveCamera.flash(_flashMode));
    }
    setState(() {
      _feed = feed;
      _zoom = feed.zoom;
    });
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

  void _onEvent(String event, Object? args) {
    if (!mounted) return;
    switch (event) {
      case 'shutter':
        _shutter();
      case 'focusReset':
        if (!_locked && _focusAt != null) {
          setState(() {
            _focusAt = null;
            _bias = 0;
          });
        }
      case 'orientation':
        // Upright is 90; on its side, 0 or 180. The controls turn back.
        final t = switch ((args as num).round()) {
          0 => 0.25,
          180 => -0.25,
          270 => 0.5,
          _ => 0.0,
        };
        if (t != _turns) setState(() => _turns = t);
    }
  }

  // ------------------------------------------------------------ the lens

  void _setZoom(double z, {bool ramp = false}) {
    final f = _feed;
    if (f == null || !f.live) return;
    final v = z.clamp(f.minZoom, f.maxZoom);
    // A tick on passing a lens.
    if (f.stops.any((s) => (s - _zoom) * (s - v) < 0 || (v == s && _zoom != s))) Haptics.tick();
    setState(() => _zoom = v);
    LiveCamera.zoom(v, ramp: ramp);
  }

  /// Focus and exposure where the view was tapped; on the box again, held
  /// there, as the system camera's AE/AF lock.
  void _tapFocus(Offset p, Size size) {
    if (!(_feed?.live ?? false)) return;
    final at = _focusAt;
    if (at != null && (p - at).distance < 44) {
      Haptics.firm();
      final on = !_locked;
      setState(() => _locked = on);
      LiveCamera.lock(on);
      _wakeFocus();
      return;
    }
    Haptics.light();
    setState(() {
      _focusAt = p;
      _locked = false;
      _bias = 0;
    });
    LiveCamera.focus(p.dx / size.width, p.dy / size.height);
    _wakeFocus();
  }

  void _setBias(double ev) {
    final m = _feed?.maxBias ?? 0;
    final v = ev.clamp(-m, m);
    if (_bias != 0 && (v == 0 || v.sign != _bias.sign)) Haptics.tick();
    setState(() => _bias = v);
    LiveCamera.bias(v);
    _wakeFocus();
  }

  /// The box stays bright while it is used, then quietens.
  void _wakeFocus() {
    _focusFade?.cancel();
    if (_focusQuiet) setState(() => _focusQuiet = false);
    _focusFade = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _focusQuiet = true);
    });
  }

  void _cycleFlash() {
    Haptics.tick();
    final next = switch (_flashMode) {
      'auto' => 'on',
      'on' => 'off',
      _ => 'auto',
    };
    setState(() => _flashMode = next);
    LiveCamera.flash(next);
  }

  Future<void> _flip() async {
    final f = _feed;
    if (_flipping || f == null || !f.live) return;
    Haptics.light();
    setState(() {
      _flipping = true;
      _focusAt = null;
      _locked = false;
      _bias = 0;
    });
    try {
      final next = await LiveCamera.flip();
      if (!mounted) return;
      if (next.resolutions.isNotEmpty && !next.resolutions.contains(_mp)) {
        _mp = next.resolutions.last;
        unawaited(LiveCamera.resolution(_mp));
      }
      setState(() {
        _feed = next;
        _zoom = next.zoom;
      });
    } on PlatformException {
      // Stays on the lens it had.
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 160));
      if (mounted) setState(() => _flipping = false);
    }
  }

  /// The shutter, the volume buttons: now, or after the timer.
  void _shutter() {
    if (_feed == null) return;
    if (_count > 0) {
      _countdown?.cancel();
      Haptics.light();
      setState(() => _count = 0);
      return;
    }
    if (_timer == 0) {
      _shoot();
      return;
    }
    Haptics.tick();
    setState(() => _count = _timer);
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      if (_count <= 1) {
        t.cancel();
        setState(() => _count = 0);
        _shoot();
      } else {
        Haptics.tick();
        setState(() => _count--);
      }
    });
  }

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
    if (_feed == null) return;
    Haptics.firm();
    final look = _r.copy();
    setState(() => _blink = true);
    Future.delayed(const Duration(milliseconds: 90), () {
      if (mounted) setState(() => _blink = false);
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
          content: Text(switch (e.code) {
            'library' => 'Saving to Photos is not allowed.',
            'busy' => 'Still saving the last photos.',
            'unavailable' => 'There is no camera on this device.',
            _ => 'The photo could not be taken.',
          }, style: Txt.small.copyWith(color: Neutral.surface)),
        ),
      );
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
              // Where the view sits, so the loupe can leave it.
              final view = Offset((box.maxWidth - h * aspect) / 2, top);
              final at = _loupe;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Column(
                    children: [
                      SizedBox(height: top, width: double.infinity, child: _topBar()),
                      SizedBox(height: h, width: h * aspect, child: _viewfinder()),
                      SizedBox(height: hint, child: _hint()),
                      const Spacer(),
                      SizedBox(height: bottom, child: _bottom()),
                    ],
                  ),
                  if (at != null)
                    _loupeWidget(view + Offset(at.dx * h * aspect, at.dy * h), width: box.maxWidth, ceiling: 0),
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
              child: SizedBox(width: 46, height: 36, child: Icon(Icons.chevron_left_rounded, size: 26, color: _ink)),
            ),
          ),
        ),
        Positioned(
          left: 70,
          right: 100,
          child: Center(
            child: FittedBox(fit: BoxFit.scaleDown, child: _chips()),
          ),
        ),
        Positioned(
          right: 14,
          child: Row(
            children: [
              if (_feed?.flash ?? false)
                _round(switch (_flashMode) {
                  'on' => Icons.flash_on_rounded,
                  'off' => Icons.flash_off_rounded,
                  _ => Icons.flash_auto_rounded,
                }, _cycleFlash),
              const SizedBox(width: 8),
              _round(_options ? Icons.close_rounded : Icons.tune_rounded, () {
                Haptics.tick();
                setState(() {
                  _options = !_options;
                  _panel = false;
                });
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _round(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Glass(
        dark: true,
        radius: 18,
        child: SizedBox(
          width: 36,
          height: 36,
          child: AnimatedRotation(
            turns: _turns,
            duration: const Duration(milliseconds: 320),
            curve: Motion.settle,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              switchInCurve: Motion.settle,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: ScaleTransition(scale: Tween(begin: 0.6, end: 1.0).animate(a), child: child),
              ),
              child: Icon(icon, key: ValueKey(icon), size: 18, color: _ink),
            ),
          ),
        ),
      ),
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
              curve: Motion.settle,
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
              Text(oklabToHex(c.l, c.a, c.b).toUpperCase(), style: Txt.mono.copyWith(color: _ink, fontSize: 12)),
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

  /// The hint, or the options in its place, one easing into the other.
  Widget _hint() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Motion.settle,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a),
          child: child,
        ),
      ),
      child: _options ? KeyedSubtree(key: const ValueKey('options'), child: _optionsRow()) : _hintText(),
    );
  }

  Widget _hintText() {
    final show = _feed != null && !_chosen;
    return Center(
      key: const ValueKey('hint'),
      child: AnimatedOpacity(
        curve: Motion.settle,
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

  /// The system camera's lesser settings: timer, grid, photo size.
  Widget _optionsRow() {
    final sizes = _feed?.resolutions ?? const <int>[];
    Widget opt(String label, bool on, VoidCallback tap) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Haptics.tick();
        tap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Text(label, style: Txt.small.copyWith(color: on ? _ink : _dim, fontSize: 12.5)),
      ),
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        opt(_timer == 0 ? 'Timer off' : 'Timer ${_timer}s', _timer > 0, () {
          setState(
            () => _timer = switch (_timer) {
              0 => 3,
              3 => 10,
              _ => 0,
            },
          );
        }),
        opt('Grid', _grid, () => setState(() => _grid = !_grid)),
        if (sizes.length > 1)
          opt('${_mp == 0 ? sizes.last : _mp} MP', true, () {
            final i = sizes.indexOf(_mp == 0 ? sizes.last : _mp);
            setState(() => _mp = sizes[(i + 1) % sizes.length]);
            LiveCamera.resolution(_mp);
          }),
      ],
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
              : (d) {
                  if (_panel || _options) {
                    setState(() {
                      _panel = false;
                      _options = false;
                    });
                    return;
                  }
                  _tapFocus(d.localPosition, size);
                },
          // Two fingers zoom; one, after a tap, moves the exposure.
          onScaleStart: feed == null
              ? null
              : (d) {
                  _pinchFrom = _zoom;
                  _pinching = d.pointerCount >= 2;
                },
          onScaleUpdate: feed == null
              ? null
              : (d) {
                  if (_loupe != null) return;
                  if (d.pointerCount >= 2) _pinching = true;
                  if (_pinching) {
                    if (d.pointerCount >= 2) _setZoom((_pinchFrom ?? _zoom) * d.scale);
                  } else if (_focusAt != null && feed.maxBias > 0) {
                    _setBias(_bias - d.focalPointDelta.dy / 110);
                  }
                },
          onScaleEnd: (_) => _pinching = false,
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
                    child: feed == null
                        ? null
                        : AnimatedOpacity(
                            curve: Motion.settle,
                            opacity: _flipping ? 0 : 1,
                            duration: const Duration(milliseconds: 160),
                            child: Texture(textureId: feed.texture, filterQuality: FilterQuality.medium),
                          ),
                  ),
                ),
                if (_grid)
                  const Positioned.fill(
                    child: IgnorePointer(child: CustomPaint(painter: _GridPainter())),
                  ),
                if (_focusAt != null) _focusBox(_focusAt!),
                Positioned(top: 10, left: 0, right: 0, child: Center(child: _lockPill())),
                if (_count > 0)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: AnimatedRotation(
                          curve: Motion.settle,
                          turns: _turns,
                          duration: const Duration(milliseconds: 320),
                          child: TweenAnimationBuilder<double>(
                            key: ValueKey(_count),
                            tween: Tween(begin: 0, end: 1),
                            duration: const Duration(milliseconds: 420),
                            curve: Motion.settle,
                            builder: (context, t, child) => Opacity(
                              opacity: t,
                              child: Transform.scale(scale: 1.25 - 0.25 * t, child: child),
                            ),
                            child: Text(
                              '$_count',
                              style: const TextStyle(
                                color: _ink,
                                fontSize: 96,
                                fontWeight: FontWeight.w200,
                                shadows: [Shadow(color: Color(0x66000000), blurRadius: 12)],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      curve: Motion.settle,
                      opacity: _blink ? 0.85 : 0,
                      duration: Duration(milliseconds: _blink ? 40 : 260),
                      child: const ColoredBox(color: Colors.white),
                    ),
                  ),
                ),
                for (final p in _pings) _PingRing(key: ValueKey(p.id), ping: p),
                Positioned(left: 0, right: 0, bottom: 0, child: _reachPanel()),
                Positioned(left: 0, right: 0, bottom: 12, child: Center(child: _zoomRow())),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: (_feed?.stops.length ?? 0) > 1 ? 60 : 14,
                  child: Center(child: _reachPill()),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The lenses, as the system camera shows them: .5, 1, 2, 3, the one in
  /// use with its exact factor.
  Widget _zoomRow() {
    final f = _feed;
    if (f == null || f.stops.length < 2) return const SizedBox();
    var cur = 0;
    for (var i = 0; i < f.stops.length; i++) {
      if (_zoom >= f.stops[i] - 0.05) cur = i;
    }
    String n(double v) {
      final r = (v * 10).round() / 10;
      final t = r == r.roundToDouble() ? r.toStringAsFixed(0) : r.toStringAsFixed(1);
      return t.startsWith('0.') ? t.substring(1) : t;
    }

    final hidden = _panel;
    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedOpacity(
        curve: Motion.settle,
        opacity: hidden ? 0 : 1,
        duration: const Duration(milliseconds: 220),
        child: Glass(
          dark: true,
          radius: 22,
          padding: const EdgeInsets.all(3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < f.stops.length; i++)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _setZoom(f.stops[i], ramp: true),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    curve: Motion.settle,
                    width: i == cur ? 40 : 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == cur ? const Color(0x2EFFFFFF) : Colors.transparent,
                    ),
                    child: AnimatedRotation(
                      turns: _turns,
                      duration: const Duration(milliseconds: 320),
                      curve: Motion.settle,
                      child: Text(
                        i == cur ? '${n(_zoom)}×' : n(f.stops[i]),
                        style: Txt.small.copyWith(
                          color: i == cur ? _ink : _dim,
                          fontSize: i == cur ? 12 : 11,
                          fontWeight: i == cur ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Where the camera focuses and meters, and beside it how much brighter
  /// or darker than the meter it is set.
  Widget _focusBox(Offset p) {
    const d = 74.0;
    final m = _feed?.maxBias ?? 0;
    return Positioned(
      left: p.dx - d / 2,
      top: p.dy - d / 2,
      width: d + 34,
      height: d,
      child: IgnorePointer(
        child: AnimatedOpacity(
          curve: Motion.settle,
          opacity: _focusQuiet ? 0.45 : 1,
          duration: const Duration(milliseconds: 300),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              TweenAnimationBuilder<double>(
                key: ValueKey(p),
                tween: Tween(begin: 1.35, end: 1),
                duration: const Duration(milliseconds: 280),
                curve: Motion.settle,
                builder: (context, s, child) => Transform.scale(scale: s, child: child),
                child: Container(
                  width: d,
                  height: d,
                  decoration: BoxDecoration(
                    border: Border.all(color: _ink, width: _locked ? 1.8 : 1.2),
                    boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4)],
                  ),
                ),
              ),
              if (m > 0)
                Positioned(
                  left: d + 8,
                  top: 0,
                  bottom: 0,
                  width: 22,
                  child: CustomPaint(painter: _BiasPainter(_bias / m)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _lockPill() {
    return IgnorePointer(
      child: AnimatedOpacity(
        curve: Motion.settle,
        opacity: _locked ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        child: AnimatedRotation(
          curve: Motion.settle,
          turns: _turns,
          duration: const Duration(milliseconds: 320),
          child: Glass(
            dark: true,
            radius: 12,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Text('AE/AF Lock', style: Txt.mono.copyWith(color: _ink, fontSize: 11)),
          ),
        ),
      ),
    );
  }

  /// How far the chosen color reaches, at a glance; opens the panel.
  Widget _reachPill() {
    final c = _cur;
    final hidden = _feed == null || _panel;
    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedOpacity(
        curve: Motion.settle,
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
          curve: Motion.settle,
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
          SizedBox(
            width: 52,
            child: Text(label, style: Txt.small.copyWith(color: _ink)),
          ),
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
            child: Text(
              '${value.round()}',
              textAlign: TextAlign.right,
              style: Txt.mono.copyWith(color: _dim),
            ),
          ),
        ],
      ),
    );
  }

  /// Held above the finger, as in Edit: the scene under it enlarged and in
  /// its own colors, ringed with the color that will be kept.
  ///
  /// It never goes below the finger, which would cover it. It rises out over
  /// the bar above the view, and where even that runs out, it slides aside
  /// along the top, toward the side with more room.
  Widget _loupeWidget(Offset p, {required double width, required double ceiling}) {
    const d = _loupeSize, gap = 36.0;
    final c = _loupeColor, image = _loupeImage;
    final above = p.dy - d - gap;
    final aside = ((ceiling - above) / d).clamp(0.0, 1.0);
    final toward = p.dx < width / 2 ? 1.0 : -1.0;
    final left = p.dx - d / 2 + toward * aside * (d / 2 + gap);
    return Positioned(
      left: left.clamp(4, width - d - 4),
      top: math.max(ceiling, above),
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
                      child: AnimatedRotation(
                        turns: _turns,
                        duration: const Duration(milliseconds: 320),
                        curve: Motion.settle,
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
        ),
        _Shutter(busy: _count > 0, onTap: _feed == null ? null : _shutter),
        Expanded(
          child: Center(
            child: (_feed?.live ?? false)
                ? GestureDetector(
                    onTap: _flip,
                    child: Glass(
                      dark: true,
                      radius: 24,
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: AnimatedRotation(
                          turns: _turns,
                          duration: const Duration(milliseconds: 320),
                          curve: Motion.settle,
                          child: const Icon(Icons.flip_camera_ios_outlined, size: 22, color: _ink),
                        ),
                      ),
                    ),
                  )
                : const SizedBox(),
          ),
        ),
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
            curve: Motion.settle,
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

/// Thirds, as the system camera's grid.
class _GridPainter extends CustomPainter {
  const _GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0x40FFFFFF)
      ..strokeWidth = 0.6;
    for (var i = 1; i < 3; i++) {
      final x = size.width * i / 3, y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(_GridPainter o) => false;
}

/// The exposure beside the focus box: a sun on a line, up for brighter.
class _BiasPainter extends CustomPainter {
  _BiasPainter(this.t);
  final double t; // -1…1

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    final y = size.height / 2 - t * (size.height / 2 - 8);
    final p = Paint()
      ..color = _CameraScreenState._ink
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    const gap = 10.0;
    if (t != 0) {
      if (y - gap > 0) canvas.drawLine(Offset(x, 0), Offset(x, y - gap), p);
      if (y + gap < size.height) canvas.drawLine(Offset(x, y + gap), Offset(x, size.height), p);
    }
    canvas.drawCircle(Offset(x, y), 3.4, p..style = PaintingStyle.fill);
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final u = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(Offset(x, y) + u * 5.4, Offset(x, y) + u * 7.6, p);
    }
  }

  @override
  bool shouldRepaint(_BiasPainter o) => o.t != t;
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
