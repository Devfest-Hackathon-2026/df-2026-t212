import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
import 'widgets/controls.dart';

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
  bool _reach = false;

  /// Strong colors in view now.
  List<KeptColor> _candidates = [];

  /// The person has chosen a color; nothing is chosen for them after that.
  bool _chosen = false;
  Timer? _scan;

  Offset? _loupe; // normalized
  KeptColor? _loupeColor;
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
    await _scanView(choose: true);
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

  /// Finds the strong colors in view. The first time, keeps the one that
  /// looks most like the subject: strong, and near the middle.
  Future<void> _scanView({bool choose = false}) async {
    final px = await LiveCamera.thumb();
    if (px == null || !mounted) return;
    final lab = toLab(px);
    final peaks = huePeaks(lab, top: 8).where((p) => p.meanChroma > 0.04).toList();
    KeptColor color(HuePeak p) {
      final h = (p.from + p.to) / 2 * math.pi / 180;
      return KeptColor(l: p.meanL, a: p.meanChroma * math.cos(h), b: p.meanChroma * math.sin(h));
    }

    setState(() => _candidates = peaks.take(6).map(color).toList());
    if (!choose || _chosen || peaks.isEmpty) return;
    double score(HuePeak p) {
      final d = math.sqrt(math.pow(p.center[0] - 0.5, 2) + math.pow(p.center[1] - 0.5, 2));
      return p.share * (1 - 0.8 * (d / 0.71).clamp(0.0, 1.0)) * (0.5 + p.meanChroma * 4);
    }

    final best = peaks.reduce((a, b) => score(a) >= score(b) ? a : b);
    setState(() {
      _r.colors = [color(best)];
      _active = 1;
    });
    _look();
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
        _active = _addSlot >= 0 ? _addSlot : _r.colors.length - 1;
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
      if (_r.colors.isEmpty) _reach = false;
    });
    _look();
  }

  Future<void> _sampleLoupe() async {
    final at = _loupe;
    if (at == null || _sampling) return;
    _sampling = true;
    final c = await LiveCamera.sample(at.dx, at.dy);
    _sampling = false;
    if (!mounted || _loupe == null) return;
    setState(() => _loupeColor = c);
    // The finger moved while sampling: catch up.
    if (_loupe != at) unawaited(_sampleLoupe());
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

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemBarsLight,
      child: Scaffold(
        backgroundColor: Neutral.bg,
        body: Padding(
          padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
          child: LayoutBuilder(
            builder: (context, box) {
              // The view as wide as the screen, unless the controls would not fit.
              const controls = 14 + 52 + 10 + 66 + 84 + 8;
              final aspect = _feed?.aspect ?? 3 / 4;
              final h = math.min(box.maxWidth / aspect, box.maxHeight - controls);
              return Column(
                children: [
                  SizedBox(height: h, width: h * aspect, child: _viewfinder()),
                  const SizedBox(height: 14),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: _colors()),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 66,
                    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: _lower()),
                  ),
                  const Spacer(),
                  _bottom(),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _viewfinder() {
    final feed = _feed;
    return SizedBox.expand(
      child: LayoutBuilder(
        builder: (context, box) {
          final size = box.biggest;
          Offset norm(Offset p) => Offset((p.dx / size.width).clamp(0.0, 1.0), (p.dy / size.height).clamp(0.0, 1.0));
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: feed == null
                ? null
                : (d) async {
                    final n = norm(d.localPosition);
                    final c = await LiveCamera.sample(n.dx, n.dy);
                    if (c != null && mounted) _pick(c, at: d.localPosition);
                  },
            onLongPressStart: feed == null
                ? null
                : (d) {
                    Haptics.light();
                    setState(() => _loupe = norm(d.localPosition));
                    _sampleLoupe();
                  },
            onLongPressMoveUpdate: (d) {
              if (_loupe == null) return;
              setState(() => _loupe = norm(d.localPosition));
              _sampleLoupe();
            },
            onLongPressEnd: (d) {
              final c = _loupeColor;
              setState(() {
                _loupe = null;
                _loupeColor = null;
              });
              if (c != null) _pick(c, at: d.localPosition);
            },
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: const Color(0xFF1A1A1A),
                    child: feed == null
                        ? Center(
                            child: Text(
                              _error ?? '',
                              textAlign: TextAlign.center,
                              style: Txt.small.copyWith(color: const Color(0xFFBDBDBD)),
                            ),
                          )
                        : Texture(textureId: feed.texture, filterQuality: FilterQuality.medium),
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
                if (_loupe != null) _loupeRing(Offset(_loupe!.dx * size.width, _loupe!.dy * size.height)),
                Positioned(
                  top: 12,
                  left: 12,
                  child: GestureDetector(
                    onTap: () {
                      Haptics.light();
                      Navigator.pop(context);
                    },
                    child: const Glass(
                      radius: 20,
                      clear: true,
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: Icon(Icons.close_rounded, size: 20, color: Neutral.primary),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 14,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: feed != null && !_chosen ? 1 : 0,
                      duration: const Duration(milliseconds: 300),
                      child: Center(
                        child: Glass(
                          radius: 16,
                          clear: true,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          child: Text('Tap what you want in color', style: Txt.small.copyWith(color: Neutral.primary)),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Held over the finger: a ring filled with the color under it.
  Widget _loupeRing(Offset p) {
    const d = 66.0;
    final c = _loupeColor;
    return Positioned(
      left: p.dx - d / 2,
      top: p.dy - d / 2 - 78,
      width: d,
      height: d,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c == null ? const Color(0x33FFFFFF) : colorOf(c),
            border: Border.all(color: Neutral.surface, width: 3),
            boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 12, offset: Offset(0, 4))],
          ),
        ),
      ),
    );
  }

  Widget _colors() {
    return Row(
      children: [
        for (var i = 0; i < Recipe.maxColors; i++) Padding(padding: const EdgeInsets.only(right: 12), child: _slot(i)),
        const Spacer(),
        _Toggle(
          label: 'Reach',
          on: _reach,
          onTap: _r.colors.isEmpty
              ? null
              : () {
                  Haptics.tick();
                  setState(() {
                    _reach = !_reach;
                    if (_reach && _cur == null) _active = _r.colors.length - 1;
                  });
                },
        ),
      ],
    );
  }

  Widget _slot(int i) {
    final filled = i < _r.colors.length;
    final isAdd = i == _addSlot;
    final sel = i == _active && (filled || isAdd);
    const s = 46.0;
    return SizedBox(
      width: s + 6,
      height: s + 6,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          GestureDetector(
            onTap: filled || isAdd
                ? () {
                    Haptics.tick();
                    setState(() {
                      _active = i;
                      if (isAdd) _reach = false;
                    });
                  }
                : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Motion.settle,
              width: s,
              height: s,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: sel ? Neutral.primary : Colors.transparent, width: 1.5),
              ),
              child: filled
                  ? AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      decoration: BoxDecoration(
                        color: colorOf(_r.colors[i]),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0x14000000), width: 0.6),
                      ),
                    )
                  : CustomPaint(painter: DashedSlot(plus: isAdd, strong: sel)),
            ),
          ),
          if (filled && sel)
            Positioned(
              top: -4,
              right: -4,
              child: GestureDetector(
                onTap: () => _remove(i),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: Neutral.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Neutral.bg, width: 2),
                  ),
                  child: const Icon(Icons.close_rounded, size: 12, color: Neutral.surface),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Under the colors: how far the chosen one reaches, or the colors in view.
  Widget _lower() {
    final c = _cur;
    if (_reach && c != null) {
      return Column(
        children: [
          SliderRow(
            height: 33,
            label: 'Width',
            value: c.width,
            min: 0,
            max: 60,
            defaultValue: 16,
            onStart: () {},
            onEnd: () {},
            onChanged: (v) {
              setState(() => c.width = v);
              _look();
            },
          ),
          SliderRow(
            height: 33,
            label: 'Softness',
            value: c.softness,
            min: 0,
            max: 60,
            defaultValue: 20,
            onStart: () {},
            onEnd: () {},
            onChanged: (v) {
              setState(() => c.softness = v);
              _look();
            },
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('In view', style: Txt.mono),
        const SizedBox(height: 8),
        SizedBox(
          height: 28,
          child: Row(
            children: [
              for (final k in _candidates)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Swatch(k, size: 28, onTap: () => _pick(k.copy())),
                ),
              if (_candidates.isEmpty && _feed != null) Text('No strong colors.', style: Txt.small),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bottom() {
    final last = _last;
    return SizedBox(
      height: 84,
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.center,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Motion.settle,
                transitionBuilder: (child, a) => ScaleTransition(
                  scale: Tween(begin: 0.6, end: 1.0).animate(a),
                  child: FadeTransition(opacity: a, child: child),
                ),
                child: last == null
                    ? const SizedBox(width: 50, height: 50)
                    : GestureDetector(
                        key: ValueKey(last.key),
                        onTap: () {
                          Haptics.light();
                          Navigator.push(context, EditRoute(last));
                        },
                        child: Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Neutral.surface, width: 2),
                            boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 8, offset: Offset(0, 2))],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
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
      ),
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
        width: 74,
        height: 74,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: on ? Neutral.primary : Neutral.tertiary, width: 2.5),
        ),
        alignment: Alignment.center,
        child: AnimatedScale(
          scale: _down ? 0.86 : 1,
          duration: const Duration(milliseconds: 120),
          curve: Motion.settle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: !on
                  ? Neutral.hairline
                  : widget.busy
                  ? Neutral.secondary
                  : Neutral.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// A quiet text toggle: underlined when on.
class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 180),
          style: Txt.small.copyWith(
            color: onTap == null
                ? Neutral.hairline
                : on
                ? Neutral.primary
                : Neutral.secondary,
            fontWeight: on ? FontWeight.w500 : FontWeight.w400,
          ),
          child: Text(label),
        ),
      ),
    );
  }
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
