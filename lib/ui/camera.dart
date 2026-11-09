import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/recipe.dart';
import '../core/renderer.dart';
import '../data/live_camera.dart';
import '../data/photo_source.dart';
import '../data/store.dart';

import 'dart:isolate';

import 'detail.dart';
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

class _CameraScreenState extends State<CameraScreen> with TickerProviderStateMixin {
  LiveFeed? _feed;
  String? _error;
  final Recipe _r = Recipe();

  /// The slot a tap fills: a kept color, or the empty slot after them.
  int _active = 0;

  /// The color set last before the empty place was chosen: a new color
  /// starts with its Width and Edge.
  int? _from;
  bool _panel = false;

  /// The colors in view, each keeping its place while it stays in view, so
  /// a finger reaching for one finds it where it was.
  /// Six fixed places: a color keeps its place for as long as it is in
  /// view, one that leaves leaves its place empty, and a new one takes the
  /// first empty place. Nothing ever moves under a finger.
  final List<_Seen?> _slots = List.filled(6, null);
  Iterable<_Seen> get _candidates => _slots.whereType<_Seen>();

  /// Colors seen once, waiting for a second look before they join.
  final List<_Seen> _maybe = [];
  int _seenId = 0;

  /// A coarse look at the view, to tell when the phone is moving.
  Uint8List? _glance;
  DateTime _movedAt = DateTime(0);

  /// A finger is on the colors, or just left them: nothing leaves then.
  bool _touching = false;
  DateTime _touchedAt = DateTime(0);

  Timer? _scan;

  Offset? _loupe; // normalized
  KeptColor? _loupeColor;
  ui.Image? _loupeImage;
  static const _loupeSize = 112.0, _loupeZoom = 3.0;
  bool _sampling = false;
  final List<_Ping> _pings = [];
  int _pingId = 0;

  PhotoItem? _last;

  /// Shots taken since the camera opened, oldest first: what the thumbnail
  /// opens to look back over.
  final List<PhotoItem> _shots = [];
  late final _exposure = AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
  static final _shutterShade = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeInQuad)), weight: 32),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 16),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeOutCubic)), weight: 132),
  ]);

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

  /// Close up on the ultra wide, or kept off it: shown while it matters,
  /// and named for a moment when it is turned.
  bool _macro = false, _macroOn = true;
  Timer? _macroNoteTimer;
  String? _macroNote;
  bool _grid = false;
  int _mp = 0;
  bool _options = false;
  bool _flipping = false;

  /// How far the controls turn to stay upright as the phone turns.
  double _turns = 0;

  /// Quarter turns of the controls: 0 upright, -1 and 1 on its side, 2
  /// upside down.
  int get _quarter => (_turns * 4).round();
  bool get _sideways => _quarter.isOdd;

  // One finger on the view: from the focus box it moves the exposure;
  // elsewhere, up opens the options and down pulls the camera away.
  bool _biasDrag = false;
  bool _swiping = false;
  double _swipeX = 0, _swipeY = 0;
  double _pull = 0;
  late final AnimationController _pullBack = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  double _pullFrom = 0;

  /// The wheel open under the finger: 'zoom' or 'reach'.
  String? _dial;

  // The photo just taken: its frame flies to the corner in black and white
  // and develops there.
  ui.Image? _shotOrig, _shotDev;
  Rect? _viewRect, _thumbRect;
  late final AnimationController _fly = AnimationController(vsync: this, duration: const Duration(milliseconds: 560));
  late final AnimationController _develop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  ui.Image? _flyOrig, _flyDev;

  int get _addSlot => _r.colors.length < Recipe.maxColors ? _r.colors.length : -1;
  KeptColor? get _cur => _active < _r.colors.length ? _r.colors[_active] : null;

  @override
  void initState() {
    super.initState();
    // The screen stays upright, as the system camera's does; the controls
    // turn instead.
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    LiveCamera.listen(_onEvent);
    _pullBack.addListener(() {
      setState(() => _pull = _pullFrom * (1 - Motion.settle.transform(_pullBack.value)));
    });
    _start();
  }

  @override
  void dispose() {
    _scan?.cancel();
    _focusFade?.cancel();
    _macroNoteTimer?.cancel();
    _countdown?.cancel();
    _pullBack.dispose();
    _exposure.dispose();
    _fly.dispose();
    _develop.dispose();
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
    unawaited(_scanView());
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
    _scan?.cancel();
    final px = await LiveCamera.thumb();
    if (!mounted) return;
    // Looks come quickly while the phone moves, so the colors follow it,
    // and a little slower while it rests.
    var next = const Duration(milliseconds: 150);
    if (px != null) {
      final now = _coarse(px);
      var d = 0.0;
      final last = _glance;
      if (last != null) {
        for (var i = 0; i < now.length; i++) {
          d += (now[i] - last[i]).abs();
        }
        d /= now.length;
      }
      _glance = now;
      final t = DateTime.now();
      if (last == null || d > 3) _movedAt = t;
      final settled = t.difference(_movedAt) > const Duration(milliseconds: 300);
      if (!settled) next = const Duration(milliseconds: 50);
      _takeColors(px, settled && !_touching && t.difference(_touchedAt) > const Duration(milliseconds: 700));
    }
    if (mounted) _scan = Timer(next, _scanView);
  }

  /// New colors join at the end as soon as they show twice. Colors leave
  /// only once the view has come to rest and no finger is near, so nothing
  /// slides under a finger reaching for it.
  void _takeColors(Rgba px, bool mayLeave) {
    final lab = toLab(px);
    final peaks = huePeaks(lab, top: 18).where((p) => p.meanChroma > 0.04 && p.share > 0.006).toList();
    double score(HuePeak p) {
      final d = math.sqrt(math.pow(p.center[0] - 0.5, 2) + math.pow(p.center[1] - 0.5, 2));
      return p.share * (1 - 0.8 * (d / 0.71).clamp(0.0, 1.0)) * (0.5 + p.meanChroma * 4);
    }

    // Six of as many hues as the view holds: each one taken makes those
    // near it in hue count for much less, so a wide skin or a wall cannot
    // fill the row by itself while the denim and the leaves wait.
    double mid(HuePeak p) => (p.from + p.to) / 2;
    double gap(double x, double y) => ((x - y + 540) % 360 - 180).abs();
    final left = [...peaks];
    final chosen = <HuePeak>[];
    while (chosen.length < 6 && left.isNotEmpty) {
      HuePeak? best;
      var bestS = 0.0;
      for (final p in left) {
        var s = score(p);
        for (final c in chosen) {
          final g = gap(mid(p), mid(c));
          s *= 1 - 0.9 * math.exp(-math.pow(g / 28, 2));
        }
        if (best == null || s > bestS) {
          best = p;
          bestS = s;
        }
      }
      chosen.add(best!);
      left.remove(best);
    }
    peaks
      ..clear()
      ..addAll(chosen);
    KeptColor color(HuePeak p) {
      final h = (p.from + p.to) / 2 * math.pi / 180;
      return KeptColor(l: p.meanL, a: p.meanChroma * math.cos(h), b: p.meanChroma * math.sin(h));
    }

    double hue(KeptColor k) => math.atan2(k.b, k.a) * 180 / math.pi;
    double apart(double x, double y) => ((x - y + 540) % 360 - 180).abs();
    final fresh = peaks.take(6).map(color).toList();
    // Each one shown takes its nearest match and keeps its place.
    void follow(List<_Seen> list) {
      for (final seen in list) {
        KeptColor? best;
        var bestD = 20.0;
        for (final k in fresh) {
          final d = apart(hue(k), hue(seen.color));
          if (d < bestD) {
            bestD = d;
            best = k;
          }
        }
        if (best != null) {
          seen
            ..color = best
            ..missed = 0;
          fresh.remove(best);
        } else {
          seen.missed++;
        }
      }
    }

    // Redraw only when something shows differently, not on every look.
    String shown() => _candidates
        .map(
          (c) =>
              '${c.id}${c.leaving}${(c.color.l * 40).round()}${(c.color.a * 200).round()}${(c.color.b * 200).round()}',
        )
        .join(',');
    final before = shown();
    follow(_candidates.where((c) => !c.leaving).toList());
    follow(_maybe);
    // Twice seen, a color joins; seen once and gone, it never showed.
    final joining = _maybe.where((m) => m.missed == 0 && m.looks++ >= 1).toList();
    _maybe.removeWhere((m) => m.missed > 0 || joining.contains(m));
    _maybe.addAll(fresh.map((k) => _Seen(_seenId++, k)));
    for (final c in _candidates) {
      if (mayLeave && !c.leaving && c.missed > 1) c.leaving = true;
    }
    for (final c in joining) {
      final i = _slots.indexOf(null);
      if (i < 0) break;
      _slots[i] = c;
    }
    if (before != shown()) setState(() {});
  }

  void _letGo() {
    _touching = false;
    _touchedAt = DateTime.now();
  }

  /// Empties a leaving color's place once it has faded.
  void _gone(_Seen c) {
    final i = _slots.indexOf(c);
    if (!mounted || i < 0) return;
    setState(() => _slots[i] = null);
  }

  /// The view as 12 by 9 patches of brightness.
  static Uint8List _coarse(Rgba p) {
    const gw = 12, gh = 9;
    final out = Uint8List(gw * gh);
    final sums = List<int>.filled(gw * gh, 0), counts = List<int>.filled(gw * gh, 0);
    for (var y = 0; y < p.height; y += 2) {
      final gy = y * gh ~/ p.height;
      for (var x = 0; x < p.width; x += 2) {
        final i = (y * p.width + x) * 4;
        final g = gy * gw + x * gw ~/ p.width;
        sums[g] += (p.pixels[i] * 54 + p.pixels[i + 1] * 183 + p.pixels[i + 2] * 19) >> 8;
        counts[g]++;
      }
    }
    for (var i = 0; i < out.length; i++) {
      out[i] = counts[i] == 0 ? 0 : sums[i] ~/ counts[i];
    }
    return out;
  }

  void _look() => LiveCamera.look(_r);

  void _onEvent(String event, Object? args) {
    if (!mounted) return;
    switch (event) {
      case 'shutter':
        _shutter();
      case 'exposure':
        if (_feed?.live == true) _exposure.forward(from: 0);
      case 'macro':
        final m = (args as Map?) ?? const {};
        final shown = m['shown'] == true;
        final on = m['on'] != false;
        // The phone takes its own time to change lenses; the button follows
        // it the moment it does, with no wait of its own.
        setState(() {
          _macro = shown;
          _macroOn = on;
        });
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
          // The top to the left: the controls turn back to the right.
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
    // On the wheel every mark is felt, a lens firmer; off it, only the
    // lenses.
    int mark(double z) => z < 3 ? (z * 10 + 1e-6).floor() : 30 + ((z - 3) * 2 + 1e-6).floor();
    if (f.stops.any((s) => (s - _zoom) * (s - v) < 0 || (v == s && _zoom != s))) {
      _dial == 'zoom' ? Haptics.snap() : Haptics.tick();
    } else if (_dial == 'zoom' && mark(v) != mark(_zoom)) {
      Haptics.tick();
    }
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
    if (_bias != 0 && (v == 0 || v.sign != _bias.sign)) Haptics.snap();
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
    Haptics.tick();
    setState(() {
      final cur = _cur;
      if (cur != null) {
        cur
          ..l = c.l
          ..a = c.a
          ..b = c.b;
      } else if (_addSlot >= 0) {
        final from = _from;
        final like = from != null && from < _r.colors.length
            ? _r.colors[from]
            : (_r.colors.isEmpty ? null : _r.colors.last);
        if (like != null) {
          c
            ..width = like.width
            ..softness = like.softness;
        }
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
    Haptics.light();
    setState(() {
      _r.colors.removeAt(i);
      _from = null;
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
    Haptics.shutter();
    final look = _r.copy();
    final frame = LiveCamera.thumb(width: 240);
    try {
      final s = await LiveCamera.capture();
      unawaited(_flyShot(await frame, look));
      final it = Store.instance.addCaptured(
        id: s.id,
        taken: s.taken,
        width: s.width,
        height: s.height,
        lat: s.lat,
        lng: s.lng,
        recipe: look,
      );
      _shots.add(it);
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

  /// The frame just taken goes to the corner in black and white, and there
  /// its kept colors come up, as a print does in the developer.
  Future<void> _flyShot(Rgba? frame, Recipe look) async {
    if (frame == null || !mounted) return;
    final dev = await Isolate.run(() => render(frame, look).image);
    final orig = await _image(frame);
    final developed = await _image(dev);
    if (!mounted) return;
    setState(() {
      _flyOrig = orig;
      _flyDev = developed;
    });
    await _fly.forward(from: 0);
    if (!mounted) return;
    final oldOrig = _shotOrig, oldDev = _shotDev;
    setState(() {
      _shotOrig = orig;
      _shotDev = developed;
      _flyOrig = null;
      _flyDev = null;
    });
    if (oldOrig != orig) oldOrig?.dispose();
    if (oldDev != developed) oldDev?.dispose();
    Haptics.light();
    await _develop.forward(from: 0);
  }

  static Future<ui.Image> _image(Rgba p) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(p.pixels, p.width, p.height, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  /// The developing picture: black and white, its colors rising with [t].
  Widget _print(ui.Image orig, ui.Image dev, double t) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColorFiltered(
          colorFilter: const ColorFilter.matrix(<double>[
            0.2126, 0.7152, 0.0722, 0, 0, //
            0.2126, 0.7152, 0.0722, 0, 0,
            0.2126, 0.7152, 0.0722, 0, 0,
            0, 0, 0, 1, 0,
          ]),
          child: RawImage(image: orig, fit: BoxFit.cover),
        ),
        Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: RawImage(image: dev, fit: BoxFit.cover),
        ),
      ],
    );
  }

  Widget _flight() {
    final from = _viewRect, to = _thumbRect, orig = _flyOrig, dev = _flyDev;
    if (from == null || to == null || orig == null || dev == null) return const SizedBox();
    return AnimatedBuilder(
      animation: _fly,
      builder: (context, _) {
        final t = Motion.travel.transform(_fly.value);
        final r = Rect.lerp(from, to, t)!;
        return Positioned.fromRect(
          rect: r,
          child: IgnorePointer(
            child: Transform.rotate(
              angle: _turns * 2 * math.pi * t,
              child: ClipRRect(borderRadius: BorderRadius.circular(10 * t), child: _print(orig, dev, 0)),
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------ layout
  //
  // After the camera in the reference: a dark room, the view in the middle,
  // everything that shapes the look laid on the view itself.

  static const _bg = Color(0xFF000000);
  static const _ink = Color(0xFFF2F2F0);
  // Quieter text over the blurred view stays white and only grows fainter:
  // gray goes muddy over a blur.
  static const _dim = Color(0x99FFFFFF);

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemBarsDark,
      child: Scaffold(
        backgroundColor: _bg,
        body: Transform.translate(
          offset: Offset(0, _pull * 0.9),
          child: Transform.scale(
            scale: 1 - (_pull / 3000).clamp(0.0, 0.08),
            child: Padding(
              padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
              child: LayoutBuilder(
                builder: (context, box) {
                  const top = 60.0, hint = 44.0, bottom = 110.0;
                  final aspect = _feed?.aspect ?? 3 / 4;
                  final w = box.maxWidth - 12;
                  final h = math.min(w / aspect, box.maxHeight - top - hint - bottom);
                  final band = math.max(box.maxHeight - top - h - bottom, 68.0);
                  // Where the view sits, so the loupe can leave it.
                  final view = Offset((box.maxWidth - h * aspect) / 2, top);
                  _viewRect = view & Size(h * aspect, h);
                  // The last shot's corner: the middle of the left of the shutter.
                  _thumbRect = Rect.fromCenter(
                    center: Offset((box.maxWidth / 2 - 38) / 2, box.maxHeight - bottom / 2),
                    width: 48,
                    height: 48,
                  );
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
                      // The options drop from the button that calls them,
                      // over the corner of the view.
                      Positioned(top: top - 6, right: 8, child: _optionsMenu()),
                      // The colors in view drop from the + they would fill.
                      Positioned(
                        top: top + 6,
                        left: 0,
                        right: 0,
                        child: Center(child: _inView()),
                      ),
                      // The hand is at the shutter: Width and Edge sit there,
                      // in the room between the view and the shutter, their
                      // wheel opening up over the view as the zoom's does.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: bottom,
                        height: band,
                        child: _dock(),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: bottom,
                        height: band + 200,
                        child: _reach(band / 2),
                      ),
                      if (at != null)
                        _loupeWidget(view + Offset(at.dx * h * aspect, at.dy * h), width: box.maxWidth, ceiling: 0),
                      _flight(),
                    ],
                  );
                },
              ),
            ),
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
              child: SizedBox(width: 46, height: 36, child: Center(child: Glyph(G.back, size: 24, color: _ink))),
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
                  'on' => G.flash,
                  'off' => G.flashOff,
                  _ => G.flashAuto,
                }, _cycleFlash),
              const SizedBox(width: 8),
              _round(_options ? G.close : G.options, () {
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

  Widget _round(G icon, VoidCallback onTap) {
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
              child: Center(key: ValueKey(icon), child: Glyph(icon, size: 20, color: _ink)),
            ),
          ),
        ),
      ),
    );
  }

  /// The kept colors, a dot each in one capsule, the one being set ringed
  /// and wearing the cross that lets it go; the next empty place at the end.
  Widget _chips() {
    return _tray(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: SizedBox(
        height: 36,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 280),
          curve: Motion.settle,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < _r.colors.length; i++)
                _slot(
                  key: ValueKey('kept$i'),
                  on: i == _active,
                  onTap: () => setState(() => _active = i),
                  onRemove: () => _remove(i),
                  dot: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    curve: Motion.settle,
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: colorOf(_r.colors[i]),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0x2EFFFFFF), width: 0.6),
                    ),
                  ),
                ),
              if (_addSlot >= 0)
                _slot(
                  key: const ValueKey('add'),
                  on: _active == _addSlot,
                  onTap: () => setState(() {
                    if (_active < _r.colors.length) _from = _active;
                    _active = _addSlot;
                  }),
                  dot: const SizedBox.square(dimension: 20, child: CustomPaint(painter: _EmptyDot())),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// A place in the palette, its dot ringed while it is the one being set:
  /// the ring grows out from behind the dot.
  Widget _slot({
    required Key key,
    required bool on,
    required Widget dot,
    required VoidCallback onTap,
    VoidCallback? onRemove,
  }) {
    final badge = on && onRemove != null;
    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Haptics.tick();
        onTap();
      },
      child: SizedBox(
        width: 32,
        height: 36,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Motion.settle,
              width: on ? 28 : 20,
              height: on ? 28 : 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: on ? _ink : const Color(0x00F2F2F0), width: 1.5),
              ),
            ),
            dot,
            // The cross on the ringed dot itself: only this one goes.
            if (onRemove != null)
              Positioned(
                right: -3,
                top: -2,
                child: IgnorePointer(
                  ignoring: !badge,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onRemove,
                    child: SizedBox.square(
                      dimension: 22,
                      child: Center(
                        child: AnimatedScale(
                          scale: badge ? 1 : 0.4,
                          duration: Duration(milliseconds: badge ? 300 : 140),
                          curve: badge ? Motion.settle : Curves.easeInCubic,
                          child: AnimatedOpacity(
                            opacity: badge ? 1 : 0,
                            duration: Duration(milliseconds: badge ? 200 : 120),
                            curve: Motion.settle,
                            child: Container(
                              width: 15,
                              height: 15,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _ink,
                                border: Border.all(color: const Color(0xFF141414), width: 1.5),
                              ),
                              child: const Center(
                                child: Glyph(G.close, size: 9, color: Color(0xFF141414), weight: 1.5),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The ground colors sit on: dark and neutral enough that a swatch reads
  /// as itself over any scene, not tinted by what is blurred behind it.
  Widget _tray({required Widget child, double radius = 18, EdgeInsets padding = EdgeInsets.zero}) {
    final r = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: const Color(0xA6141414),
            borderRadius: r,
            border: Border.all(color: const Color(0x1FFFFFFF), width: 0.6),
          ),
          child: child,
        ),
      ),
    );
  }

  /// Only what went wrong; the first-use hint sits with Width/Edge.
  Widget _hint() {
    return Center(
      key: const ValueKey('hint'),
      child: AnimatedOpacity(
        curve: Motion.settle,
        opacity: _error != null ? 1 : 0,
        duration: const Duration(milliseconds: 300),
        child: Text(
          _error ?? '',
          textAlign: TextAlign.center,
          style: Txt.small.copyWith(color: _dim),
        ),
      ),
    );
  }

  /// The system camera's lesser settings, as its own icons: timer, grid,
  /// photo size, each showing its state in itself, with no words. They
  /// grow out of the button at the top right and fold back into it.
  Widget _optionsMenu() {
    final open = _options;
    return IgnorePointer(
      ignoring: !open,
      child: AnimatedOpacity(
        opacity: open ? 1 : 0,
        duration: Duration(milliseconds: open ? 200 : 140),
        curve: Motion.settle,
        child: AnimatedScale(
          scale: open ? 1 : 0.6,
          alignment: Alignment.topRight,
          duration: Duration(milliseconds: open ? 280 : 180),
          curve: open ? Motion.settle : Curves.easeInCubic,
          child: Glass(
            dark: true,
            radius: 24,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(mainAxisSize: MainAxisSize.min, children: _optionItems()),
          ),
        ),
      ),
    );
  }

  /// Macro, by the zoom, as the system camera's: a tulip that shows up close,
  /// solid while the phone is on the ultra wide, struck through and left
  /// in sight for as long as it is kept off; tapped, it turns, and says
  /// which for a moment.
  Widget _macroButton() {
    final show = _macro && _dial != 'zoom' && _dial != 'reach' && !_panel;
    final on = _macroOn;
    return IgnorePointer(
      ignoring: !show,
      child: AnimatedOpacity(
        opacity: show ? 1 : 0,
        duration: Duration(milliseconds: show ? 220 : 160),
        curve: show ? Motion.settle : Curves.easeInCubic,
        child: AnimatedScale(
          scale: show ? 1 : 0.6,
          duration: Duration(milliseconds: show ? 320 : 160),
          curve: show ? Motion.settle : Curves.easeInCubic,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleMacro,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Motion.settle,
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: on ? _ink : const Color(0xA6141414),
                    border: Border.all(color: const Color(0x26FFFFFF), width: 0.6),
                  ),
                  child: AnimatedRotation(
                    turns: _turns,
                    duration: const Duration(milliseconds: 320),
                    curve: Motion.settle,
                    child: Center(
                      child: Glyph(
                        on ? G.macro : G.macroOff,
                        size: 20,
                        color: on ? const Color(0xFF111111) : _ink,
                        weight: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              AnimatedOpacity(
                opacity: _macroNote != null ? 1 : 0,
                duration: Duration(milliseconds: _macroNote != null ? 200 : 260),
                curve: Motion.settle,
                child: RotatedBox(
                  // Upright for the person, however the phone is held.
                  quarterTurns: switch (_quarter) {
                    -1 => 3,
                    1 => 1,
                    2 => 2,
                    _ => 0,
                  },
                  child: _tray(
                    radius: 12,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    child: Text(_macroNote ?? (on ? 'Macro' : 'Macro Off'), style: Txt.small.copyWith(color: _ink)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleMacro() {
    Haptics.tick();
    final on = !_macroOn;
    setState(() {
      _macroOn = on;
      _macroNote = on ? 'Macro' : 'Macro Off';
    });
    _macroNoteTimer?.cancel();
    _macroNoteTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _macroNote = null);
    });
    LiveCamera.macro(on);
  }

  /// While the add slot is selected, explain how to pick from the preview.
  Widget _dock() {
    final show = _feed != null && _addSlot >= 0 && _active == _addSlot &&
        !_options && !_sideways && _loupe == null && _error == null;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: show ? 1 : 0,
        duration: Duration(milliseconds: show ? 280 : 140),
        curve: show ? Motion.settle : Curves.easeInCubic,
        child: Center(
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text('Touch and hold a color in the preview to keep it', textAlign: TextAlign.center,
              style: Txt.small.copyWith(color: _dim))),
        ),
      ),
    );
  }

  /// Width and Edge of the color being set, by the shutter, made as the
  /// zoom's buttons are.
  Widget _reach(double base) {
    final c = _cur;
    final show = _feed != null && c != null;
    return IgnorePointer(
      ignoring: !show,
      child: AnimatedOpacity(
        opacity: show ? 1 : 0,
        duration: Duration(milliseconds: show ? 280 : 140),
        curve: show ? Motion.settle : Curves.easeInCubic,
        child: _ReachWheel(
          values: [c?.width ?? 16, c?.softness ?? 20],
          defaults: const [16, 20],
          turns: _turns,
          base: base,
          hidden: _panel || _dial == 'zoom',
          onChange: (key, v) {
            final c = _cur;
            if (c == null) return;
            setState(() => key == 0 ? c.width = v : c.softness = v);
            _look();
          },
          onOpen: (open) {
            if (open && _dial == null) setState(() => _dial = 'reach');
            if (!open && _dial == 'reach') setState(() => _dial = null);
          },
        ),
      ),
    );
  }

  List<Widget> _optionItems() {
    final sizes = _feed?.resolutions ?? const <int>[];
    Widget opt(Widget icon, bool on, VoidCallback tap, {String? badge}) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Haptics.tick();
        tap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Motion.settle,
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? const Color(0x2EFFFFFF) : const Color(0x14FFFFFF),
          ),
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              AnimatedRotation(
                turns: _turns,
                duration: const Duration(milliseconds: 320),
                curve: Motion.settle,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  switchInCurve: Motion.settle,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (c, a) => FadeTransition(
                    opacity: a,
                    child: ScaleTransition(scale: Tween(begin: 0.7, end: 1.0).animate(a), child: c),
                  ),
                  child: icon,
                ),
              ),
              if (badge != null)
                Positioned(
                  right: -3,
                  top: -3,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: Motion.settle,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                    child: Container(
                      key: ValueKey(badge),
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(color: _ink, borderRadius: BorderRadius.circular(8)),
                      child: Text(
                        badge,
                        style: Txt.small.copyWith(
                          color: Colors.black,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
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
    final mp = _mp == 0 && sizes.isNotEmpty ? sizes.last : _mp;
    return [
      opt(
        Glyph(
          _timer == 0 ? G.timerOff : G.timer,
          key: ValueKey(_timer == 0),
          size: 21,
          color: _timer > 0 ? _ink : _dim,
        ),
        _timer > 0,
        badge: _timer > 0 ? '$_timer' : null,
        () => setState(
          () => _timer = switch (_timer) {
            0 => 3,
            3 => 10,
            _ => 0,
          },
        ),
      ),
      opt(
        Glyph(
          _grid ? G.grid : G.gridOff,
          key: ValueKey(_grid),
          size: 21,
          color: _grid ? _ink : _dim,
        ),
        _grid,
        () => setState(() => _grid = !_grid),
      ),
      if (sizes.length > 1)
        opt(
          Column(
            key: ValueKey(mp),
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$mp',
                style: Txt.small.copyWith(color: _ink, fontSize: 12, fontWeight: FontWeight.w600, height: 1),
              ),
              Text(
                'MP',
                style: Txt.small.copyWith(color: _dim, fontSize: 7.5, fontWeight: FontWeight.w600, height: 1.1),
              ),
            ],
          ),
          mp == sizes.last,
          () {
            final i = sizes.indexOf(mp);
            setState(() => _mp = sizes[(i + 1) % sizes.length]);
            LiveCamera.resolution(_mp);
          },
        ),
    ];
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
                  // Exposure only from the box and its sun, so a drag
                  // elsewhere is never mistaken for it.
                  final at = _focusAt;
                  _biasDrag =
                      !_pinching &&
                      at != null &&
                      feed.maxBias > 0 &&
                      Rect.fromLTRB(at.dx - 50, at.dy - 64, at.dx + 92, at.dy + 64).contains(d.localFocalPoint);
                  _swiping = false;
                  _swipeX = 0;
                  _swipeY = 0;
                },
          onScaleUpdate: feed == null
              ? null
              : (d) {
                  if (_loupe != null) return;
                  if (d.pointerCount >= 2) _pinching = true;
                  if (_pinching) {
                    if (d.pointerCount >= 2) _setZoom((_pinchFrom ?? _zoom) * d.scale);
                    return;
                  }
                  if (_biasDrag) {
                    _setBias(_bias - d.focalPointDelta.dy / 110);
                    return;
                  }
                  _swipeX += d.focalPointDelta.dx;
                  _swipeY += d.focalPointDelta.dy;
                  if (!_swiping && _swipeY.abs() > 14 && _swipeY.abs() > _swipeX.abs() * 1.4) _swiping = true;
                  if (_swiping && _swipeY > 0) {
                    _pullBack.stop();
                    setState(() => _pull = _swipeY);
                  }
                },
          onScaleEnd: (d) {
            if (_swiping) {
              final v = d.velocity.pixelsPerSecond.dy;
              if (_swipeY > 0) {
                if (_swipeY > 140 || v > 900) {
                  Haptics.light();
                  Navigator.pop(context);
                } else {
                  _pullFrom = _pull;
                  _pullBack.forward(from: 0);
                }
              } else if (_swipeY < -44 || v < -600) {
                if (!_options) Haptics.tick();
                setState(() {
                  _options = true;
                  _panel = false;
                });
              }
            }
            if (_pinching) setState(() => _pinching = false);
            _biasDrag = false;
            _swiping = false;
          },
          onLongPressStart: feed == null
              ? null
              : (d) {
                  Haptics.light();
                  LiveCamera.freeze(true);
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
            LiveCamera.freeze(false);
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
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _exposure,
                      builder: (context, _) {
                        final peak = MediaQuery.disableAnimationsOf(context) ? 0.35 : 0.86;
                        final shade = _exposure.isAnimating ? _shutterShade.transform(_exposure.value) * peak : 0.0;
                        return ColoredBox(color: Colors.black.withValues(alpha: shade));
                      },
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
                for (final p in _pings) _PingRing(key: ValueKey(p.id), ping: p),
                Positioned(left: 14, bottom: 12, child: _macroButton()),
                if (feed != null && feed.stops.length > 1)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 240,
                    child: _ZoomWheel(
                      zoom: _zoom,
                      min: feed.minZoom,
                      max: feed.maxZoom,
                      stops: feed.stops,
                      turns: _turns,
                      hidden: _panel || _dial == 'reach',
                      onZoom: _setZoom,
                      onOpen: (open) {
                        if (open && _dial == null) setState(() => _dial = 'zoom');
                        if (!open && _dial == 'zoom') setState(() => _dial = null);
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
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

  /// While the empty slot at the top is the one being filled, the colors in
  /// view hang under it, to tap instead of holding the view.
  Widget _inView() {
    final open = _feed != null && _addSlot >= 0 && _active == _addSlot && !_options;
    return IgnorePointer(
      ignoring: !open,
      child: AnimatedOpacity(
        opacity: open ? 1 : 0,
        duration: Duration(milliseconds: open ? 220 : 140),
        curve: open ? Motion.settle : Curves.easeInCubic,
        child: AnimatedScale(
          scale: open ? 1 : 0.9,
          alignment: Alignment.topCenter,
          duration: Duration(milliseconds: open ? 300 : 160),
          curve: open ? Motion.settle : Curves.easeInCubic,
          child: _tray(
            radius: 22,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: SizedBox(
              height: 44,
              child: _candidates.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Align(
                        widthFactor: 1,
                        child: Text('No strong colors', style: Txt.small.copyWith(color: _dim)),
                      ),
                    )
                  : _swatchRow(38, 26),
            ),
          ),
        ),
      ),
    );
  }

  /// The colors in view in a row, each [slot] wide and answering over all
  /// of it, not only the swatch.
  Widget _swatchRow(double slot, double dot) {
    if (_candidates.isEmpty) {
      return SizedBox(
        height: 44,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('No strong colors.', style: Txt.small.copyWith(color: _dim)),
        ),
      );
    }
    return Listener(
      // While a finger is on the row, nothing leaves it.
      onPointerDown: (_) => _touching = true,
      onPointerUp: (_) => _letGo(),
      onPointerCancel: (_) => _letGo(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in _slots)
            SizedBox(
              width: slot,
              height: 44,
              child: c == null
                  ? null
                  : GestureDetector(
                      key: ValueKey(c.id),
                      behavior: HitTestBehavior.opaque,
                      onTap: c.leaving ? null : () => _pick(c.color.copy()),
                      // Grows in, and fades out in its own place.
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: c.leaving ? 0 : 1),
                        duration: Duration(milliseconds: c.leaving ? 220 : 300),
                        curve: Motion.settle,
                        onEnd: c.leaving ? () => _gone(c) : null,
                        builder: (context, t, child) => Center(
                          child: Opacity(
                            opacity: t.clamp(0.0, 1.0),
                            child: Transform.scale(scale: 0.6 + 0.4 * t, child: child),
                          ),
                        ),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 400),
                          curve: Motion.settle,
                          width: dot,
                          height: dot,
                          decoration: BoxDecoration(
                            color: colorOf(c.color),
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0x33FFFFFF), width: 0.6),
                          ),
                        ),
                      ),
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
                      onTap: () async {
                        Haptics.light();
                        // This session's shots, newest first.
                        final store = Store.instance;
                        _shots.retainWhere(store.items.contains);
                        final list = _shots.reversed.toList();
                        if (list.isEmpty) return;
                        await Navigator.push(context, DetailRoute(items: list, index: 0, review: true));
                        // Deleted there: the thumbnail falls back to the shot before.
                        _shots.retainWhere(store.items.contains);
                        if (mounted && !store.items.contains(_last)) {
                          final o = _shotOrig, d = _shotDev;
                          setState(() {
                            _last = _shots.isEmpty ? null : _shots.last;
                            _shotOrig = null;
                            _shotDev = null;
                          });
                          o?.dispose();
                          d?.dispose();
                        }
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
                            child: _shotOrig != null && _shotDev != null
                                ? AnimatedBuilder(
                                    animation: _develop,
                                    builder: (context, _) =>
                                        _print(_shotOrig!, _shotDev!, Motion.settle.transform(_develop.value)),
                                  )
                                : DevelopedImage(last, size: 160),
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
                          child: const Center(child: Glyph(G.flip, size: 24, color: _ink)),
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

/// The lenses as the system camera shows them, .5 1 2 3, and the same
/// buttons opening into a wheel when held, slid or pinched: a half disc
/// whose numbers come out of the buttons, turning under a fixed mark with
/// the finger.
class _ZoomWheel extends StatefulWidget {
  const _ZoomWheel({
    required this.zoom,
    required this.min,
    required this.max,
    required this.stops,
    required this.turns,
    required this.hidden,
    required this.onZoom,
    required this.onOpen,
  });
  final double zoom, min, max, turns;
  final List<double> stops;
  final bool hidden;
  final void Function(double zoom, {bool ramp}) onZoom;
  final void Function(bool open) onOpen;

  @override
  State<_ZoomWheel> createState() => _ZoomWheelState();
}

class _ZoomWheelState extends State<_ZoomWheel> with SingleTickerProviderStateMixin {
  late final AnimationController _open = AnimationController(vsync: this);
  Timer? _close;
  double _acc = 0;

  @override
  void didUpdateWidget(_ZoomWheel old) {
    super.didUpdateWidget(old);
  }

  @override
  void dispose() {
    _close?.cancel();
    _open.dispose();
    super.dispose();
  }

  void _show() {
    _close?.cancel();
    if (_open.value < 1 && _open.status != AnimationStatus.forward) {
      Haptics.light();
      widget.onOpen(true);
      // As quick as the system's: there before the finger has moved far.
      _open.animateTo(1, duration: const Duration(milliseconds: 200), curve: Motion.settle);
    }
  }

  void _hideSoon() {
    _close?.cancel();
    _close = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _open.animateBack(0, duration: const Duration(milliseconds: 220), curve: Motion.settle);
      widget.onOpen(false);
    });
  }

  void _drag(double dx, Size s) {
    final g = _WheelGeometry(s, widget.stops.length);
    _acc = (_acc - dx / g.r / g.k).clamp(_WheelGeometry.p(widget.min), _WheelGeometry.p(widget.max));
    widget.onZoom(_WheelGeometry.unp(_acc));
  }

  void _tap(Offset p, Size s) {
    final g = _WheelGeometry(s, widget.stops.length);
    final open = _open.value > 0.5;
    final labels = open ? g.labels(widget.stops, widget.max) : widget.stops;
    double? best;
    var bestD = open ? 34.0 : 26.0;
    for (var i = 0; i < labels.length; i++) {
      final at = open ? g.label(widget.zoom, labels[i]) : g.button(i.toDouble());
      final d = (at - p).distance;
      if (d < bestD) {
        bestD = d;
        best = labels[i];
      }
    }
    if (best != null) widget.onZoom(best, ramp: true);
    if (open) _hideSoon();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: widget.hidden,
      child: AnimatedOpacity(
        opacity: widget.hidden ? 0 : 1,
        duration: const Duration(milliseconds: 220),
        curve: Motion.settle,
        child: LayoutBuilder(
          builder: (context, box) {
            final size = box.biggest;
            final g = _WheelGeometry(size, widget.stops.length);
            // Closed, only the buttons take a touch, so the view around
            // them still focuses; open, the whole wheel does.
            final buttons = g.capsule.inflate(4);
            return AnimatedBuilder(
              animation: _open,
              builder: (context, _) {
                final open = _open.value > 0.02;
                final t = _open.value;
                return Stack(
                  children: [
                    // Frosted under the numbers, so they read over any
                    // scene: the buttons' capsule, then the wheel.
                    if (t < 1)
                      Positioned.fill(
                        key: const ValueKey('capsule'),
                        child: IgnorePointer(
                          child: ClipPath(
                            clipper: _PathClip(
                              Path()..addRRect(RRect.fromRectAndRadius(g.capsule, const Radius.circular(22))),
                            ),
                            child: BackdropFilter(
                              filter: ui.ImageFilter.blur(sigmaX: 9 * (1 - t), sigmaY: 9 * (1 - t)),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    if (t > 0)
                      Positioned.fill(
                        key: const ValueKey('disc'),
                        child: IgnorePointer(
                          child: ClipPath(
                            clipper: _PathClip(g.disc(t)),
                            child: BackdropFilter(
                              filter: ui.ImageFilter.blur(sigmaX: 12 * t, sigmaY: 12 * t),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    Positioned.fill(
                      key: const ValueKey('paint'),
                      child: IgnorePointer(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(end: widget.turns),
                          duration: const Duration(milliseconds: 320),
                          curve: Motion.settle,
                          builder: (context, turns, _) => TweenAnimationBuilder<double>(
                            tween: Tween(end: _current().toDouble()),
                            duration: const Duration(milliseconds: 220),
                            curve: Motion.settle,
                            builder: (context, cur, _) => CustomPaint(
                              painter: _ZoomWheelPainter(
                                t: _open.value,
                                zoom: widget.zoom,
                                min: widget.min,
                                max: widget.max,
                                stops: widget.stops,
                                turns: turns,
                                current: cur,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fromRect(
                      // Keyed, so the touch that opens the wheel keeps
                      // turning it as the layers above come and go.
                      key: const ValueKey('touch'),
                      rect: open ? Offset.zero & size : buttons,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (d) => _tap(d.localPosition + (open ? Offset.zero : buttons.topLeft), size),
                        onLongPressStart: (_) {
                          _acc = _WheelGeometry.p(widget.zoom);
                          _show();
                        },
                        onLongPressMoveUpdate: (d) {
                          _close?.cancel();
                          final v = _acc - d.offsetFromOrigin.dx / g.r / g.k;
                          widget.onZoom(
                            _WheelGeometry.unp(v.clamp(_WheelGeometry.p(widget.min), _WheelGeometry.p(widget.max))),
                          );
                        },
                        onLongPressEnd: (_) => _hideSoon(),
                        onHorizontalDragStart: (_) {
                          _acc = _WheelGeometry.p(widget.zoom);
                          _show();
                        },
                        onHorizontalDragUpdate: (d) {
                          _close?.cancel();
                          _drag(d.delta.dx, size);
                        },
                        onHorizontalDragEnd: (_) => _hideSoon(),
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// The button that holds the factor now.
  int _current() {
    var cur = 0;
    for (var i = 0; i < widget.stops.length; i++) {
      if (widget.zoom >= widget.stops[i] - 0.05) cur = i;
    }
    return cur;
  }
}

/// Where everything on the zoom wheel sits.
class _WheelGeometry {
  _WheelGeometry(this.size, this.n, {this.step = 40, this.base = 30})
    : r = size.width * 0.85,
      // A shallow arc, its top a little above the buttons, as the system's.
      center = Offset(size.width / 2, size.height - base - 58 + size.width * 0.85);
  final Size size;
  final int n;

  /// From one button to the next, and from the buttons to the bottom.
  final double step, base;

  /// The disc's radius, and its middle, below the bottom edge.
  final double r;
  final Offset center;

  /// Radians of the wheel per unit of [p]: about 180 points of rim each.
  double get k => 180 / r;

  /// The wheel's scale: even in the log up to 3x, then drawn closer, as
  /// the system camera's, so 15x still fits.
  static double p(double v) {
    final l = math.log(v), t = math.log(3);
    return l <= t ? l : t + (l - t) * 0.45;
  }

  static double unp(double q) {
    final t = math.log(3);
    return math.exp(q <= t ? q : t + (q - t) / 0.45);
  }

  double angle(double zoom, double v) => (p(v) - p(zoom)) * k;

  Offset onRim(double a, double inset) => center + Offset(math.sin(a), -math.cos(a)) * (r - inset);

  Offset label(double zoom, double v) => onRim(angle(zoom, v), 34);

  /// The top of the wheel, under the mark.
  Offset get top => center - Offset(0, r);

  Offset button(double i) => Offset(size.width / 2 + (i - (n - 1) / 2) * step, size.height - base);

  Rect get capsule => Rect.fromCenter(center: button((n - 1) / 2), width: n * step + 6, height: 44);

  /// How big the wheel has grown as it opens, about the buttons.
  static double grow(double t) => 0.7 + 0.3 * t;

  /// The disc's outline, [t] of the way open.
  Path disc(double t) {
    final pivot = button((n - 1) / 2);
    final c = pivot + (center - pivot) * grow(t);
    return Path()..addOval(Rect.fromCircle(center: c, radius: r * grow(t)));
  }

  /// The numbers on the wheel: the lenses and the furthest.
  List<double> labels(List<double> stops, double max) => [
    ...stops,
    if (!stops.any((s) => (s - max).abs() < 0.5)) max.roundToDouble(),
  ];
}

class _ZoomWheelPainter extends CustomPainter {
  _ZoomWheelPainter({
    required this.t,
    required this.zoom,
    required this.min,
    required this.max,
    required this.stops,
    required this.turns,
    required this.current,
  });
  final double t, zoom, min, max, turns, current;
  final List<double> stops;

  static const ink = Color(0xFFF2F2F0);

  static String name(double v) {
    final r = (v * 10).round() / 10;
    final s = r == r.roundToDouble() ? r.toStringAsFixed(0) : r.toStringAsFixed(1);
    return s.startsWith('0.') ? s.substring(1) : s;
  }

  void _text(Canvas canvas, String text, Offset at, double size, Color color, {FontWeight weight = FontWeight.w500}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: weight,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(turns * 2 * math.pi);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = _WheelGeometry(size, stops.length);
    final n = stops.length;
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    // Closed: the capsule and the lit button.
    if (t < 1) {
      final a = 1 - t;
      canvas.drawRRect(
        RRect.fromRectAndRadius(g.capsule, const Radius.circular(22)),
        Paint()..color = Color.fromRGBO(20, 20, 20, 0.32 * a),
      );
      canvas.drawCircle(g.button(current), 18, Paint()..color = Color.fromRGBO(255, 255, 255, 0.16 * a));
    }

    // Open: the disc swells out of the buttons, the whole wheel with it.
    if (t > 0) {
      final grow = 0.7 + 0.3 * t;
      final pivot = g.button((n - 1) / 2);
      canvas.save();
      canvas.translate(pivot.dx, pivot.dy);
      canvas.scale(grow);
      canvas.translate(-pivot.dx, -pivot.dy);
      canvas.drawCircle(g.center, g.r, Paint()..color = Color.fromRGBO(14, 14, 14, 0.45 * t));

      // Ticks along the rim in three weights: the lenses long and bright,
      // the halves (whole numbers past 3) middling, the rest short and
      // faint, so the eye finds its place at once.
      final tick = Paint()..strokeCap = StrokeCap.round;
      for (var v = (min * 10).ceil() / 10; v <= max + 1e-6; v += v < 3 - 1e-6 ? 0.1 : 0.5) {
        final q = (v * 100).round() / 100;
        final a = g.angle(zoom, q);
        final along = a.abs() * g.r;
        if (along > 260) continue;
        final lens = stops.any((s) => (s - q).abs() < 0.01) || (q - max).abs() < 0.01;
        final mid = q < 3 ? ((q * 2) - (q * 2).roundToDouble()).abs() < 0.01 : (q - q.roundToDouble()).abs() < 0.01;
        final fade = (1 - math.pow(along / 260, 3)).clamp(0.0, 1.0);
        final (len, alpha, width) = lens ? (15.0, 1.0, 2.0) : (mid ? (10.0, 0.7, 1.4) : (5.0, 0.32, 1.0));
        tick
          ..color = ink.withValues(alpha: alpha * fade * t)
          ..strokeWidth = width;
        canvas.drawLine(g.onRim(a, 3), g.onRim(a, 3 + len), tick);
      }
      // The fixed mark.
      final mark = Path()
        ..moveTo(g.top.dx - 4, g.top.dy - 9)
        ..lineTo(g.top.dx + 4, g.top.dy - 9)
        ..lineTo(g.top.dx, g.top.dy - 3)
        ..close();
      canvas.drawPath(mark, Paint()..color = ink.withValues(alpha: t));
      canvas.restore();
    }

    // The numbers: from the buttons out to their places on the wheel, the
    // present factor at the top under the mark.
    final labels = g.labels(stops, max);
    final grow = 0.7 + 0.3 * t;
    final pivot = g.button((n - 1) / 2);
    Offset scaled(Offset o) => pivot + (o - pivot) * grow;
    for (var i = 0; i < labels.length; i++) {
      final v = labels[i];
      final a = g.angle(zoom, v);
      final onWheel = scaled(g.label(zoom, v));
      // Near the top, the present factor takes the place.
      final along = a.abs() * g.r;
      final near = (1 - (along - 30) / 30).clamp(0.0, 1.0);
      final fade = (1 - math.pow(along / 240, 3)).clamp(0.0, 1.0) * (1 - near);
      if (i < n) {
        final cur = (i - current).abs() < 0.5;
        final at = Offset.lerp(g.button(i.toDouble()), onWheel, t)!;
        if (t < 0.5) {
          final alpha = (cur ? 1.0 : 0.62) * (1 - t * 2) + 0.85 * fade * t * 2;
          _text(
            canvas,
            cur ? '${name(zoom)}×' : name(v),
            at,
            cur ? 12.5 : 11.5,
            ink.withValues(alpha: alpha.clamp(0.0, 1.0)),
            weight: cur ? FontWeight.w600 : FontWeight.w500,
          );
        } else {
          _text(canvas, name(v), at, 12, ink.withValues(alpha: 0.85 * fade));
        }
      } else if (t > 0) {
        _text(canvas, name(v), onWheel, 12, ink.withValues(alpha: 0.85 * fade * t));
      }
    }
    if (t > 0) {
      _text(canvas, '${name(zoom)}×', scaled(g.onRim(0, 34)), 14, ink.withValues(alpha: t), weight: FontWeight.w600);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ZoomWheelPainter o) =>
      o.t != t || o.zoom != zoom || o.turns != turns || o.current != current || o.max != max;
}

/// Width and Edge, made as the zoom's buttons are: a frosted capsule by the
/// shutter holding each name with its number. Held or slid, the one under
/// the finger opens into the same half disc, a unit to a tick, turning with
/// the finger under a fixed mark; the other steps back. Tapped, it shows
/// its wheel a moment, so the hand learns it turns. On the open wheel, a
/// number or the dot at the default is a tap away.
class _ReachWheel extends StatefulWidget {
  const _ReachWheel({
    required this.values,
    required this.defaults,
    required this.turns,
    required this.base,
    required this.hidden,
    required this.onChange,
    required this.onOpen,
  });

  /// Width, then Edge.
  final List<double> values, defaults;
  final double turns, base;
  final bool hidden;
  final void Function(int key, double value) onChange;
  final void Function(bool open) onOpen;

  @override
  State<_ReachWheel> createState() => _ReachWheelState();
}

class _ReachWheelState extends State<_ReachWheel> with TickerProviderStateMixin {
  late final AnimationController _open = AnimationController(vsync: this);

  /// Where the wheel stands: with the finger, unrounded, while it turns,
  /// then sprung onto the whole number it lands on.
  late final AnimationController _pos = AnimationController.unbounded(vsync: this);
  Timer? _close;
  int _key = 0;
  double _acc = 0, _lastDx = 0;
  bool _held = false;

  @override
  void didUpdateWidget(_ReachWheel old) {
    super.didUpdateWidget(old);
    final v = widget.values[_key];
    if (!_held && v != old.values[_key]) _settle(v);
  }

  @override
  void dispose() {
    _close?.cancel();
    _open.dispose();
    _pos.dispose();
    super.dispose();
  }

  _WheelGeometry _g(Size s) => _ReachWheelPainter.geometry(s, widget.base);

  int _nearest(Offset p, Size s) {
    final g = _g(s);
    return (p - g.button(0)).distance <= (p - g.button(1)).distance ? 0 : 1;
  }

  void _settle(double to) => _pos.animateWith(SpringSimulation(Springs.snappy, _pos.value, to, 0));

  void _show(int key) {
    _close?.cancel();
    if (_open.value < 0.02 && _key != key) {
      setState(() => _key = key);
      _pos.value = widget.values[key];
    }
    if (_open.value < 1 && _open.status != AnimationStatus.forward) {
      Haptics.light();
      widget.onOpen(true);
      _pos.value = widget.values[_key];
      _open.animateTo(1, duration: const Duration(milliseconds: 200), curve: Motion.settle);
    }
  }

  void _hideSoon([int ms = 300]) {
    _close?.cancel();
    _close = Timer(Duration(milliseconds: ms), () {
      if (!mounted) return;
      _open.animateBack(0, duration: const Duration(milliseconds: 220), curve: Motion.settle);
      widget.onOpen(false);
    });
  }

  void _grab(Offset p, Size s) {
    _show(_open.value > 0.5 ? _key : _nearest(p, s));
    _held = true;
    _lastDx = 0;
    _acc = widget.values[_key];
    _pos.stop();
    _pos.value = _acc;
  }

  void _turn(double dx) {
    _close?.cancel();
    _acc = (_acc - dx / _ReachWheelPainter.unit).clamp(-2.0, 62.0);
    _pos.value = _acc.clamp(0.0, 60.0);
    final next = _acc.clamp(0.0, 60.0).roundToDouble();
    if (next == widget.values[_key]) return;
    next == widget.defaults[_key] ? Haptics.snap() : Haptics.tick();
    widget.onChange(_key, next);
  }

  void _let() {
    _held = false;
    _settle(widget.values[_key]);
    _hideSoon();
  }

  void _tap(Offset p, Size s) {
    if (_open.value <= 0.5) {
      _show(_nearest(p, s));
      _hideSoon(900);
      return;
    }
    final g = _g(s);
    final value = widget.values[_key];
    final def = widget.defaults[_key];
    double? best;
    var bestD = 30.0;
    for (final v in [for (var v = 0.0; v <= 60; v += 10) v, def]) {
      final at = _ReachWheelPainter.labelAt(g, value, v, v == def && v % 10 != 0);
      final d = (at - p).distance;
      if (d < bestD) {
        bestD = d;
        best = v;
      }
    }
    if (best != null && best != value) {
      best == def ? Haptics.firm() : Haptics.tick();
      widget.onChange(_key, best);
    }
    _hideSoon();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: widget.hidden,
      child: AnimatedOpacity(
        opacity: widget.hidden ? 0 : 1,
        duration: const Duration(milliseconds: 220),
        curve: Motion.settle,
        child: LayoutBuilder(
          builder: (context, box) {
            final size = box.biggest;
            final g = _g(size);
            final buttons = g.capsule.inflate(4);
            return AnimatedBuilder(
              animation: Listenable.merge([_open, _pos]),
              builder: (context, _) {
                final t = _open.value;
                final open = t > 0.02;
                return Stack(
                  children: [
                    if (t < 1)
                      Positioned.fill(
                        key: const ValueKey('capsule'),
                        child: IgnorePointer(
                          child: ClipPath(
                            clipper: _PathClip(
                              Path()..addRRect(RRect.fromRectAndRadius(g.capsule, const Radius.circular(22))),
                            ),
                            child: BackdropFilter(
                              filter: ui.ImageFilter.blur(sigmaX: 9 * (1 - t), sigmaY: 9 * (1 - t)),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    if (t > 0)
                      Positioned.fill(
                        key: const ValueKey('disc'),
                        child: IgnorePointer(
                          child: ClipPath(
                            clipper: _PathClip(g.disc(t)),
                            child: BackdropFilter(
                              filter: ui.ImageFilter.blur(sigmaX: 12 * t, sigmaY: 12 * t),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    Positioned.fill(
                      key: const ValueKey('paint'),
                      child: IgnorePointer(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(end: widget.turns),
                          duration: const Duration(milliseconds: 320),
                          curve: Motion.settle,
                          builder: (context, turns, _) => CustomPaint(
                            painter: _ReachWheelPainter(
                              t: t,
                              values: widget.values,
                              defaults: widget.defaults,
                              active: _key,
                              pos: _pos.value,
                              turns: turns,
                              base: widget.base,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fromRect(
                      key: const ValueKey('touch'),
                      rect: open ? Offset.zero & size : buttons,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (d) => _tap(d.localPosition + (open ? Offset.zero : buttons.topLeft), size),
                        onLongPressStart: (d) => _grab(d.localPosition + (open ? Offset.zero : buttons.topLeft), size),
                        onLongPressMoveUpdate: (d) {
                          _turn(d.offsetFromOrigin.dx - _lastDx);
                          _lastDx = d.offsetFromOrigin.dx;
                        },
                        onLongPressEnd: (_) => _let(),
                        onHorizontalDragStart: (d) =>
                            _grab(d.localPosition + (open ? Offset.zero : buttons.topLeft), size),
                        onHorizontalDragUpdate: (d) => _turn(d.delta.dx),
                        onHorizontalDragEnd: (_) => _let(),
                        onHorizontalDragCancel: _let,
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ReachWheelPainter extends CustomPainter {
  _ReachWheelPainter({
    required this.t,
    required this.values,
    required this.defaults,
    required this.active,
    required this.pos,
    required this.turns,
    required this.base,
  });
  final double t, pos, turns, base;
  final List<double> values, defaults;
  final int active;

  static const ink = _ZoomWheelPainter.ink;
  static const names = ['Width', 'Edge'];

  /// Points of rim a unit, and as far under the finger.
  static const unit = 6.0;

  static _WheelGeometry geometry(Size s, double base) => _WheelGeometry(s, 2, step: 78, base: base);

  /// Where [v] sits on the wheel standing at [at]: the tens as numbers, the
  /// default as a dot just inside the ticks.
  static Offset labelAt(_WheelGeometry g, double at, double v, bool dot) =>
      g.onRim((v - at) * unit / g.r, dot ? 25 : 34);

  void _text(Canvas canvas, String text, Offset at, double size, Color color, {FontWeight weight = FontWeight.w500}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: weight,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(turns * 2 * math.pi);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  /// A name and its number side by side, centered on [at] together, upright
  /// for the person.
  void _pair(Canvas canvas, String name, String number, Offset at, double size, double nameAlpha, double alpha, bool bold) {
    final (a, b) = _lay(name, number, size, nameAlpha, alpha, bold);
    const gap = 5.0;
    final w = a.width + gap + b.width;
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(turns * 2 * math.pi);
    a.paint(canvas, Offset(-w / 2, -a.height / 2));
    b.paint(canvas, Offset(-w / 2 + a.width + gap, -b.height / 2));
    canvas.restore();
  }

  /// How far the pair reaches up and down on the screen as it is turned,
  /// so it can sit inside the ticks, never across them.
  double _extent(String name, String number, double size) {
    final (a, b) = _lay(name, number, size, 1, 1, true);
    final w = a.width + 5 + b.width, h = a.height;
    final th = turns * 2 * math.pi;
    return (w * math.sin(th)).abs() + (h * math.cos(th)).abs();
  }

  (TextPainter, TextPainter) _lay(String name, String number, double size, double nameAlpha, double alpha, bool bold) {
    TextPainter lay(String text, Color color, FontWeight weight) => TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: weight,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return (
      lay(name, ink.withValues(alpha: nameAlpha), FontWeight.w500),
      lay(number, ink.withValues(alpha: alpha), bold ? FontWeight.w600 : FontWeight.w500),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = geometry(size, base);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final grow = _WheelGeometry.grow(t);
    final pivot = g.button(0.5);
    Offset scaled(Offset o) => pivot + (o - pivot) * grow;

    if (t < 1) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(g.capsule, const Radius.circular(22)),
        Paint()..color = Color.fromRGBO(20, 20, 20, 0.32 * (1 - t)),
      );
    }

    if (t > 0) {
      canvas.save();
      canvas.translate(pivot.dx, pivot.dy);
      canvas.scale(grow);
      canvas.translate(-pivot.dx, -pivot.dy);
      canvas.drawCircle(g.center, g.r, Paint()..color = Color.fromRGBO(14, 14, 14, 0.45 * t));

      // A tick a unit, as the zoom's in three weights: the tens long and
      // bright, the fives middling, the rest short and faint.
      final tick = Paint()..strokeCap = StrokeCap.round;
      final def = defaults[active];
      for (var v = 0; v <= 60; v++) {
        final a = (v - pos) * unit / g.r;
        final along = a.abs() * g.r;
        if (along > 260) continue;
        final fade = (1 - math.pow(along / 260, 3)).clamp(0.0, 1.0);
        final (len, alpha, width) = v % 10 == 0
            ? (15.0, 1.0, 2.0)
            : v % 5 == 0
                ? (10.0, 0.7, 1.4)
                : (5.0, 0.32, 1.0);
        tick
          ..color = ink.withValues(alpha: alpha * fade * t)
          ..strokeWidth = width;
        canvas.drawLine(g.onRim(a, 3), g.onRim(a, 3 + len), tick);
        if (v == def) {
          canvas.drawCircle(g.onRim(a, 25), 2, Paint()..color = ink.withValues(alpha: 0.9 * fade * t));
        }
      }
      final mark = Path()
        ..moveTo(g.top.dx - 4, g.top.dy - 9)
        ..lineTo(g.top.dx + 4, g.top.dy - 9)
        ..lineTo(g.top.dx, g.top.dy - 3)
        ..close();
      canvas.drawPath(mark, Paint()..color = ink.withValues(alpha: t));
      canvas.restore();

      // The tens on the wheel, giving way near the top to the number set.
      for (var v = 0.0; v <= 60; v += 10) {
        // The number set is wider than the zoom's, its name beside it.
        final along = (v - pos).abs() * unit;
        final near = (1 - (along - 54) / 22).clamp(0.0, 1.0);
        final fade = (1 - math.pow(along / 240, 3)).clamp(0.0, 1.0) * (1 - near);
        if (fade <= 0) continue;
        _text(canvas, v.toStringAsFixed(0), scaled(labelAt(g, pos, v, false)), 12, ink.withValues(alpha: 0.85 * fade * t));
      }
    }

    // The buttons: a glyph and its number each. The one held goes up to
    // the top of the wheel under the mark, the other steps back.
    // Under the mark, its near end clear of the longest ticks.
    final held = values[active].round().toString();
    final atTop = scaled(g.onRim(0, math.max(34, 24 + _extent(names[active], held, 14) / 2)));
    for (var i = 0; i < 2; i++) {
      final on = i == active;
      final from = g.button(i.toDouble());
      final at = on ? Offset.lerp(from, atTop, t)! : from;
      final alpha = on ? 1.0 : (1 - t * 1.6).clamp(0.0, 1.0);
      if (alpha <= 0) continue;
      _pair(
        canvas,
        names[i],
        values[i].round().toString(),
        at,
        on ? 12.5 + 1.5 * t : 12.5,
        alpha * (0.62 + 0.2 * t),
        alpha,
        on && t > 0.5,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ReachWheelPainter o) =>
      o.t != t ||
      o.pos != pos ||
      o.turns != turns ||
      o.active != active ||
      o.base != base ||
      o.values[0] != values[0] ||
      o.values[1] != values[1];
}

class _PathClip extends CustomClipper<Path> {
  _PathClip(this.path);
  final Path path;

  @override
  Path getClip(Size size) => Path.combine(PathOperation.intersect, path, Path()..addRect(Offset.zero & size));

  @override
  bool shouldReclip(_PathClip old) => true;
}

/// A color in view and how many looks it has been missing.
class _Seen {
  _Seen(this.id, this.color);
  final int id;
  KeptColor color;
  int missed = 0;
  int looks = 0;

  /// Shrinking out of the row; no longer answers a tap.
  bool leaving = false;
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

/// The empty place a new color goes into: a faint disc with a plus.
class _EmptyDot extends CustomPainter {
  const _EmptyDot();

  @override
  void paint(Canvas canvas, Size s) {
    final c = s.center(Offset.zero);
    canvas.drawCircle(c, s.width / 2, Paint()..color = const Color(0x24FFFFFF));
    final p = Paint()
      ..color = const Color(0xE6F2F2F0)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(c - const Offset(4.2, 0), c + const Offset(4.2, 0), p);
    canvas.drawLine(c - const Offset(0, 4.2), c + const Offset(0, 4.2), p);
  }

  @override
  bool shouldRepaint(_EmptyDot o) => false;
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
