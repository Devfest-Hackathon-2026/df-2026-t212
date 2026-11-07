import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../agent/agent.dart';
import '../core/recipe.dart';
import '../core/renderer.dart';
import '../data/photo_source.dart';
import '../data/store.dart';
import 'edit_preview.dart';
import 'theme.dart';
import 'widgets/common.dart';

class EditRoute extends PageRouteBuilder<void> {
  EditRoute(PhotoItem item)
      : super(
          transitionDuration: const Duration(milliseconds: 380),
          pageBuilder: (_, _, _) => EditScreen(item: item),
          transitionsBuilder: (_, a, _, child) => FadeTransition(
            opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
              child: child,
            ),
          ),
        );
}

enum _Tool { accent, range, area, mono }

/// One job: override the agent's work. The tools are the agent's tools.
///
/// If the agent is still developing the photo, its work shows here live; the
/// first change the person makes stops the agent and keeps what it did.
class EditScreen extends StatefulWidget {
  const EditScreen({super.key, required this.item});
  final PhotoItem item;

  @override
  State<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends State<EditScreen> {
  PhotoItem get _it => widget.item;
  late Recipe _r = (_it.edit ?? Recipe()).copy();
  final List<Recipe> _undo = [];
  _Tool _tool = _Tool.accent;

  /// Selected slot. Equal to the number of colors: the empty "add" slot.
  int _active = 0;
  bool _advanced = false;

  Rgba? _px;
  Lab? _lab;
  List<KeptColor> _candidates = [];
  ui.Image? _preview;
  ui.Image? _original;
  PreviewWorker? _worker;
  StreamSubscription<ui.Image>? _images;

  bool _mask = false; // show where color is kept
  bool _sliding = false; // a reach slider is being dragged: show the mask
  bool _before = false; // holding "Before"

  AgentRun? _run;
  StreamSubscription<Recipe>? _runSub;
  bool _touched = false;

  Offset? _loupe; // normalized
  Offset? _areaStart, _areaEnd;
  final List<_Ping> _pings = [];
  int _pingId = 0;

  @override
  void initState() {
    super.initState();
    if (_it.state == Develop.pending) Store.instance.hold(_it);
    final run = Store.instance.runFor(_it);
    if (run != null) _attach(run);
    _load();
  }

  @override
  void dispose() {
    _images?.cancel();
    _runSub?.cancel();
    _worker?.dispose();
    _zoom.dispose();
    Store.instance.release(_it);
    super.dispose();
  }

  Future<void> _load() async {
    final px = await PhotoSource.pixels(_it.id, 900);
    if (px == null || !mounted) return;
    final workerF = PreviewWorker.start(px);
    final lab = await _labOf(px);
    final peaks = huePeaks(lab, top: 8);
    final cands = peaks.where((p) => p.meanChroma > 0.04).map((p) {
      final h = (p.from + p.to) / 2 * math.pi / 180;
      return KeptColor(l: p.meanL, a: p.meanChroma * math.cos(h), b: p.meanChroma * math.sin(h));
    }).take(6).toList();
    final orig = await _toImage(px);
    final worker = await workerF;
    if (!mounted) {
      worker.dispose();
      return;
    }
    _images = worker.images.listen((im) {
      if (!mounted) return;
      final old = _preview;
      setState(() => _preview = im);
      if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    });
    setState(() {
      _px = px;
      _lab = lab;
      _candidates = cands;
      _original = orig;
      _worker = worker;
      _active = _active.clamp(0, _addSlot);
    });
    _request();
  }

  // Static so the isolate closure captures only the photo, not this State.
  static Future<Lab> _labOf(Rgba px) => Isolate.run(() => toLab(px));

  static Future<ui.Image> _toImage(Rgba p) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(p.pixels, p.width, p.height, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  void _request() => _worker?.request(_r, view: _mask || _sliding ? PreviewView.mask : PreviewView.result);

  // ------------------------------------------------------------ agent

  void _attach(AgentRun run) {
    _run = run;
    if (run.recipe.colors.isNotEmpty) _r = run.recipe.copy();
    _runSub = run.changes.listen((r) {
      if (!mounted || _run != run) return;
      setState(() {
        _r = r;
        _active = _active.clamp(0, _addSlot);
      });
      _request();
    }, onDone: () {
      if (!mounted || _run != run) return;
      // Finished on its own: show what it settled on.
      setState(() {
        _run = null;
        if (_it.edit != null) _r = _it.edit!.copy();
        _active = 0;
      });
      Haptics.firm();
      _request();
    });
  }

  void _auto() {
    if (_it.auto != null) {
      _change(() => _r = _it.auto!.copy());
      return;
    }
    Haptics.light();
    setState(() => _attach(Store.instance.developNow(_it)));
  }

  /// The person's first change: stop the agent, keep its work so far.
  void _takeOver() {
    final run = _run;
    if (run == null && _touched) return;
    _touched = true;
    _runSub?.cancel();
    _runSub = null;
    _run = null;
    if (run != null || _it.state != Develop.done) Store.instance.takeOver(_it);
    if (run != null) Haptics.light();
  }

  // ------------------------------------------------------------ edits

  int get _addSlot => math.min(_r.colors.length, Recipe.maxColors - 1);
  bool get _adding => _active >= _r.colors.length;
  KeptColor? get _cur => _adding ? null : _r.colors[_active];

  void _change(void Function() f, {bool record = true}) {
    _takeOver();
    if (record) _undo.add(_r.copy());
    setState(f);
    _request();
  }

  /// Put [c] in the selected slot: replaces that color, or adds a new one.
  void _pick(KeptColor c) {
    Haptics.light();
    _change(() {
      if (_adding) {
        _r.colors.add(c
          ..width = 14
          ..softness = 16);
        _active = _r.colors.length - 1;
      } else {
        final old = _r.colors[_active];
        _r.colors[_active] = c
          ..width = old.width
          ..softness = old.softness
          ..chromaMin = old.chromaMin;
      }
    });
  }

  void _pickAt(Offset n, Size box) {
    final lab = _lab;
    if (lab == null) return;
    final c = sampleColor(lab, n.dx, n.dy);
    final grey = c.chroma < 0.02;
    _ping(Offset(n.dx * box.width, n.dy * box.height), grey ? null : colorOf(c));
    if (grey) {
      Haptics.tick();
      return; // grey has no color to keep
    }
    _pick(c);
  }

  void _remove(int i) {
    Haptics.light();
    _change(() {
      _r.colors.removeAt(i);
      _active = math.min(i, _addSlot);
    });
  }

  void _ping(Offset p, Color? c) {
    final id = _pingId++;
    setState(() => _pings.add(_Ping(id, p, c)));
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _pings.removeWhere((e) => e.id == id));
    });
  }

  void _slide(bool on) {
    if (_tool == _Tool.mono) return;
    setState(() => _sliding = on);
    _request();
  }

  void _setTool(_Tool t) {
    setState(() {
      _tool = t;
      if (t == _Tool.range && _adding && _r.colors.isNotEmpty) _active = _r.colors.length - 1;
    });
  }

  void _done() {
    _takeOver();
    Store.instance.setEdit(_it, _r..why = _undo.isEmpty ? _r.why : 'Edited by hand.');
    Navigator.pop(context);
  }

  // ------------------------------------------------------------ layout

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final running = _run != null;
    return Scaffold(
      backgroundColor: Neutral.bg,
      body: Column(children: [
        SizedBox(height: pad.top),
        Row(children: [
          TextAction('Cancel', color: Neutral.secondary, onTap: () => Navigator.pop(context)),
          TextAction('Undo', onTap: _undo.isEmpty ? null : () => _change(() => _r = _undo.removeLast(), record: false)),
          const Spacer(),
          if (running)
            TextAction('Stop', onTap: () => setState(_takeOver))
          else
            TextAction('Auto', onTap: _auto),
          TextAction('Done', onTap: _done),
          const SizedBox(width: 6),
        ]),
        Expanded(child: _photo()),
        _viewBar(),
        _panel(pad),
      ]),
    );
  }

  final _zoom = TransformationController();

  Widget _photo() {
    final it = _it;
    final px = _px;
    final ratio = px != null ? px.width / px.height : it.width / it.height;
    final areaMode = _tool == _Tool.area;
    return LayoutBuilder(builder: (context, outer) {
      // The photo, fitted with a margin; pinch zooms it over the whole area.
      const m = 16.0;
      final availW = outer.maxWidth - m * 2, availH = outer.maxHeight - m * 2;
      final w = math.min(availW, availH * ratio), h = w / ratio;
      final size = Size(w, h);
      Offset norm(Offset p) => Offset((p.dx / w).clamp(0, 1), (p.dy / h).clamp(0, 1));
      final photo = SizedBox(
        width: w,
        height: h,
        child: GestureDetector(
          onTapUp: areaMode ? null : (d) => _pickAt(norm(d.localPosition), size),
          onLongPressStart: areaMode ? null : (d) => setState(() => _loupe = norm(d.localPosition)),
          onLongPressMoveUpdate: areaMode
              ? null
              : (d) {
                  final n = norm(d.localPosition);
                  if (_loupe != null && (n - _loupe!).distance > 0.02) Haptics.tick();
                  setState(() => _loupe = n);
                },
          onLongPressEnd: areaMode
              ? null
              : (d) {
                  final n = _loupe;
                  setState(() => _loupe = null);
                  if (n != null) _pickAt(n, size);
                },
          onPanStart: areaMode ? (d) => setState(() => _areaStart = _areaEnd = norm(d.localPosition)) : null,
          onPanUpdate: areaMode ? (d) => setState(() => _areaEnd = norm(d.localPosition)) : null,
          onPanEnd: areaMode
              ? (_) {
                  final a = _areaStart, b = _areaEnd;
                  setState(() => _areaStart = _areaEnd = null);
                  if (a == null || b == null || (a - b).distance < 0.03) return;
                  Haptics.light();
                  _change(() {
                    final e = [(a.dx + b.dx) / 2, (a.dy + b.dy) / 2, (a.dx - b.dx).abs() / 2, (a.dy - b.dy).abs() / 2];
                    final area = _r.area?.copy() ?? Area(edge: 0.03);
                    area.ellipses = [...area.ellipses, e];
                    _r.area = area;
                  });
                }
              : null,
          child: Stack(clipBehavior: Clip.none, fit: StackFit.expand, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(fit: StackFit.expand, children: [
                if (_before && _original != null)
                  RawImage(image: _original, fit: BoxFit.fill, filterQuality: FilterQuality.medium)
                else if (_preview != null)
                  RawImage(image: _preview, fit: BoxFit.fill, filterQuality: FilterQuality.medium)
                else
                  Hero(
                    tag: 'photo-${it.key}',
                    child: it.edit == null
                        ? OriginalImage(it, size: 900)
                        : DevelopedImage(it, size: 1600, fit: BoxFit.cover, alignment: Alignment.center, placeholder: OriginalImage(it, size: 900)),
                  ),
                if (areaMode) CustomPaint(painter: _AreaPainter(_r.area, _areaStart, _areaEnd)),
              ]),
            ),
            for (final p in _pings) _PingRing(key: ValueKey(p.id), ping: p),
          ]),
        ),
      );
      // The loupe stays a fixed size whatever the zoom: place it in screen space.
      Widget? loupe;
      if (_loupe != null && _original != null) {
        final origin = Offset((outer.maxWidth - w) / 2, (outer.maxHeight - h) / 2);
        final at = MatrixUtils.transformPoint(_zoom.value, origin + Offset(_loupe!.dx * w, _loupe!.dy * h));
        loupe = _loupeWidget(at, outer);
      }
      return ClipRect(
        child: Stack(children: [
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: _zoom,
              minScale: 1,
              maxScale: 8,
              // In Area, one finger draws; zoom first in another tool.
              panEnabled: !areaMode,
              scaleEnabled: !areaMode,
              clipBehavior: Clip.none,
              child: SizedBox(
                width: outer.maxWidth,
                height: outer.maxHeight,
                child: Center(child: photo),
              ),
            ),
          ),
          ?loupe,
        ]),
      );
    });
  }

  /// One line between the photo and the tools: what is shown, and how to compare.
  Widget _viewBar() {
    final showMask = _mask || _sliding;
    final running = _run != null;
    final status = _before
        ? 'Before'
        : showMask
            ? 'Showing where color is kept'
            : running
                ? 'Agent ${_runLabel(_run!.status)} · edit to take over'
                : '';
    return SizedBox(
      height: 36,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: [
          const SizedBox(width: 10),
          if (running && !showMask && !_before) ...[const _LiveDot(), const SizedBox(width: 8)],
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: Align(
                key: ValueKey(status),
                alignment: Alignment.centerLeft,
                child: Text(status, style: Txt.small.copyWith(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
          _ViewButton(
            label: 'Mask',
            on: _mask,
            onTap: () {
              Haptics.tick();
              setState(() => _mask = !_mask);
              _request();
            },
          ),
          _ViewButton(label: 'Before', on: _before, onHold: (on) => setState(() => _before = on)),
        ]),
      ),
    );
  }

  static String _runLabel(String? s) => switch (s) {
        'probe' || 'hue_histogram' => 'looking',
        'add_color' || 'remove_color' => 'choosing colors',
        'set_width' || 'set_softness' || 'set_gate' => 'adjusting reach',
        'set_area' => 'limiting the area',
        'set_mono_tone' => 'setting tone',
        'render' => 'checking',
        'finish' => 'finishing',
        _ => 'looking',
      };

  Widget _loupeWidget(Offset p, BoxConstraints box) {
    const d = 112.0, zoom = 3.0;
    final top = p.dy - d - 36 < 0 ? p.dy + 36 : p.dy - d - 36;
    final c = _lab == null ? null : sampleColor(_lab!, _loupe!.dx, _loupe!.dy);
    final scale = _zoom.value.getMaxScaleOnAxis();
    return Positioned(
      left: (p.dx - d / 2).clamp(0, box.maxWidth - d),
      top: top,
      child: IgnorePointer(
        child: Container(
          width: d,
          height: d,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: c == null ? Neutral.surface : colorOf(c), width: 5),
            boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 14, offset: Offset(0, 4))],
          ),
          child: ClipOval(
            child: CustomPaint(painter: _LoupePainter(_original!, _loupe!, zoom * scale)),
          ),
        ),
      ),
    );
  }

  Widget _panel(EdgeInsets pad) {
    return Container(
      decoration: const BoxDecoration(
        color: Neutral.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [BoxShadow(color: Color(0x14000000), blurRadius: 24, offset: Offset(0, -4), spreadRadius: -8)],
      ),
      padding: EdgeInsets.fromLTRB(20, 16, 20, pad.bottom + 2),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: Align(
                key: ValueKey(_toolTitle),
                alignment: Alignment.centerLeft,
                child: Text(_toolTitle, style: Txt.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              Haptics.tick();
              setState(() => _advanced = !_advanced);
            },
            child: Row(children: [
              Text('Values', style: Txt.small.copyWith(color: _advanced ? Neutral.primary : Neutral.tertiary)),
              const SizedBox(width: 8),
              _MiniToggle(on: _advanced),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        SizedBox(
          height: 138,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: KeyedSubtree(key: ValueKey(_tool), child: _toolBody()),
          ),
        ),
        const SizedBox(height: 6),
        const Hairline(),
        Row(children: [
          for (final t in _Tool.values)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  Haptics.tick();
                  _setTool(t);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(children: [
                    Text(_label(t), style: Txt.label.copyWith(color: _tool == t ? Neutral.primary : Neutral.tertiary)),
                    const SizedBox(height: 5),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: _tool == t ? 16 : 0,
                      height: 2,
                      decoration: BoxDecoration(color: Neutral.primary, borderRadius: BorderRadius.circular(1)),
                    ),
                  ]),
                ),
              ),
            ),
        ]),
      ]),
    );
  }

  String _label(_Tool t) => switch (t) { _Tool.accent => 'Color', _Tool.range => 'Reach', _Tool.area => 'Area', _Tool.mono => 'Tone' };

  String get _toolTitle => switch (_tool) {
        _Tool.accent => _adding ? 'Tap the photo to add a color' : 'Tap the photo to change this color',
        _Tool.range => 'How far the color reaches',
        _Tool.area => 'Drag on the photo to keep color only there',
        _Tool.mono => 'Black and white contrast',
      };

  Widget _toolBody() {
    switch (_tool) {
      case _Tool.accent:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < Recipe.maxColors; i++) Padding(padding: const EdgeInsets.only(right: 14), child: _slot(i)),
          ]),
          const Spacer(),
          Text('From this photo', style: Txt.mono),
          const SizedBox(height: 8),
          SizedBox(
            height: 28,
            child: Row(children: [
              for (final c in _candidates)
                Padding(padding: const EdgeInsets.only(right: 10), child: Swatch(c, size: 28, onTap: () => _pick(c.copy()))),
              if (_candidates.isEmpty) Text(_lab == null ? '' : 'No strong colors.', style: Txt.small),
            ]),
          ),
        ]);
      case _Tool.range:
        final c = _cur;
        if (c == null) return Center(child: Text('Keep a color first.', style: Txt.small));
        return Column(children: [
          SizedBox(
            height: 30,
            child: Row(children: [
              for (var i = 0; i < _r.colors.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Swatch(_r.colors[i], size: 26, selected: i == _active, onTap: () {
                    Haptics.tick();
                    setState(() => _active = i);
                  }),
                ),
            ]),
          ),
          const SizedBox(height: 4),
          _SliderRow(
            label: 'Width',
            value: c.width,
            min: 0,
            max: 60,
            defaultValue: 14,
            advanced: _advanced,
            detail: '${((c.hue - c.width + 360) % 360).round()}°–${((c.hue + c.width) % 360).round()}°',
            onStart: () {
              _undo.add(_r.copy());
              _slide(true);
            },
            onEnd: () => _slide(false),
            onChanged: (v) => _change(() => c.width = v, record: false),
          ),
          _SliderRow(
            label: 'Softness',
            value: c.softness,
            min: 0,
            max: 60,
            defaultValue: 16,
            advanced: _advanced,
            detail: '+${c.softness.round()}°',
            onStart: () {
              _undo.add(_r.copy());
              _slide(true);
            },
            onEnd: () => _slide(false),
            onChanged: (v) => _change(() => c.softness = v, record: false),
          ),
        ]);
      case _Tool.area:
        return Column(children: [
          _SliderRow(
            label: 'Edge',
            value: (_r.area?.edge ?? 0.03) * 100,
            min: 0,
            max: 10,
            defaultValue: 3,
            advanced: _advanced,
            onStart: () {
              _undo.add(_r.copy());
              _slide(true);
            },
            onEnd: () => _slide(false),
            onChanged: (v) => _change(() => (_r.area ??= Area()).edge = v / 100, record: false),
          ),
          Row(children: [
            Text(_r.area == null || _r.area!.isEmpty ? 'Whole photo' : '${(_r.area!.polygons.length + _r.area!.ellipses.length)} shape(s)', style: Txt.mono),
            const Spacer(),
            TextAction('Clear', onTap: _r.area == null ? null : () => _change(() => _r.area = null)),
          ]),
        ]);
      case _Tool.mono:
        return Column(children: [
          _SliderRow(
            label: 'Contrast',
            value: _r.contrast * 100,
            min: -30,
            max: 40,
            defaultValue: 10,
            advanced: _advanced,
            onStart: () => _undo.add(_r.copy()),
            onEnd: () {},
            onChanged: (v) => _change(() => _r.contrast = v / 100, record: false),
          ),
        ]);
    }
  }

  /// One of the three color slots: a kept color, the slot to add into, or empty.
  Widget _slot(int i) {
    final filled = i < _r.colors.length;
    final isAdd = i == _r.colors.length;
    final sel = filled ? i == _active : (isAdd && _adding);
    final c = filled ? _r.colors[i] : null;
    const s = 50.0;
    return SizedBox(
      width: s + 8,
      child: Column(children: [
        SizedBox(
          width: s + 8,
          height: s + 8,
          child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
            GestureDetector(
              onTap: filled || isAdd
                  ? () {
                      Haptics.tick();
                      setState(() => _active = filled ? i : _r.colors.length);
                    }
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                width: s,
                height: s,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: sel ? Neutral.primary : Colors.transparent, width: 1.5),
                ),
                child: filled
                    ? DecoratedBox(
                        decoration: BoxDecoration(
                          color: colorOf(c!),
                          borderRadius: BorderRadius.circular(11),
                          border: Border.all(color: const Color(0x14000000), width: 0.6),
                        ),
                      )
                    : CustomPaint(painter: _DashedSlot(plus: isAdd, strong: sel)),
              ),
            ),
            if (filled && sel)
              Positioned(
                top: -2,
                right: -2,
                child: GestureDetector(
                  onTap: () => _remove(i),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: Neutral.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: Neutral.surface, width: 2),
                    ),
                    child: const Icon(Icons.close_rounded, size: 12, color: Neutral.surface),
                  ),
                ),
              ),
          ]),
        ),
        SizedBox(
          height: 16,
          child: Center(
            child: Text(
              filled ? (_advanced ? oklabToHex(c!.l, c.a, c.b).toUpperCase() : '') : (isAdd ? 'Add' : ''),
              style: Txt.mono.copyWith(fontSize: 9.5, color: sel ? Neutral.primary : Neutral.tertiary),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Ping {
  _Ping(this.id, this.at, this.color);
  final int id;
  final Offset at;
  final Color? color;
}

/// A ring where the photo was tapped, in the color that was picked.
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
          curve: Curves.easeOutCubic,
          builder: (context, t, _) => Opacity(
            opacity: (1 - t).clamp(0, 1),
            child: Transform.scale(
              scale: 0.35 + 0.65 * t,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: ping.color ?? Neutral.surface, width: ping.color == null ? 1.5 : 4),
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

class _LiveDot extends StatefulWidget {
  const _LiveDot();

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 0.25, end: 1.0).animate(_c),
        child: Container(width: 6, height: 6, decoration: const BoxDecoration(color: Neutral.primary, shape: BoxShape.circle)),
      );
}

/// A quiet text toggle under the photo; with [onHold], active while pressed.
class _ViewButton extends StatelessWidget {
  const _ViewButton({required this.label, required this.on, this.onTap, this.onHold});
  final String label;
  final bool on;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onHold;

  @override
  Widget build(BuildContext context) {
    final hold = onHold;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onTapDown: hold == null
          ? null
          : (_) {
              Haptics.tick();
              hold(true);
            },
      onTapUp: hold == null ? null : (_) => hold(false),
      onTapCancel: hold == null ? null : () => hold(false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 140),
          style: Txt.small.copyWith(fontSize: 12.5, color: on ? Neutral.primary : Neutral.secondary, fontWeight: on ? FontWeight.w600 : FontWeight.w400),
          child: Text(label),
        ),
      ),
    );
  }
}

class _DashedSlot extends CustomPainter {
  _DashedSlot({required this.plus, required this.strong});
  final bool plus, strong;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = strong ? Neutral.secondary : Neutral.hairline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(11)));
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 7) {
        canvas.drawPath(m.extractPath(d, d + 3.5), p);
      }
    }
    if (plus) {
      final c = s.center(Offset.zero);
      final q = Paint()
        ..color = strong ? Neutral.primary : Neutral.tertiary
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(c - const Offset(6, 0), c + const Offset(6, 0), q);
      canvas.drawLine(c - const Offset(0, 6), c + const Offset(0, 6), q);
    }
  }

  @override
  bool shouldRepaint(_DashedSlot o) => o.plus != plus || o.strong != strong;
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.defaultValue,
    required this.onChanged,
    required this.onStart,
    required this.onEnd,
    this.advanced = false,
    this.detail,
  });
  final String label;
  final double value, min, max, defaultValue;
  final ValueChanged<double> onChanged;
  final VoidCallback onStart, onEnd;
  final bool advanced;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Row(children: [
        SizedBox(width: 72, child: Text(label, style: Txt.small.copyWith(color: Neutral.primary))),
        Expanded(
          child: _ThinSlider(value: value, min: min, max: max, defaultValue: defaultValue, onChanged: onChanged, onStart: onStart, onEnd: onEnd),
        ),
        if (advanced)
          SizedBox(
            width: 92,
            child: Text(
              detail == null ? value.toStringAsFixed(1) : '${value.round()}  $detail',
              textAlign: TextAlign.right,
              style: Txt.mono.copyWith(fontSize: 10),
            ),
          ),
      ]),
    );
  }
}

/// A quiet slider: hairline track, small thumb, a tick when passing default.
class _ThinSlider extends StatefulWidget {
  const _ThinSlider({required this.value, required this.min, required this.max, required this.defaultValue, required this.onChanged, required this.onStart, required this.onEnd});
  final double value, min, max, defaultValue;
  final ValueChanged<double> onChanged;
  final VoidCallback onStart, onEnd;

  @override
  State<_ThinSlider> createState() => _ThinSliderState();
}

class _ThinSliderState extends State<_ThinSlider> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      double t(double v) => ((v - widget.min) / (widget.max - widget.min)).clamp(0, 1);
      void set(double dx) {
        final v = widget.min + (dx / w).clamp(0.0, 1.0) * (widget.max - widget.min);
        final before = widget.value, d = widget.defaultValue;
        if ((before - d).sign != (v - d).sign) Haptics.tick();
        widget.onChanged(v);
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) {
          widget.onStart();
          setState(() => _down = true);
        },
        onHorizontalDragUpdate: (d) => set(d.localPosition.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _down = false);
          widget.onEnd();
        },
        onHorizontalDragCancel: () {
          setState(() => _down = false);
          widget.onEnd();
        },
        onTapUp: (d) {
          widget.onStart();
          set(d.localPosition.dx);
          Future.delayed(const Duration(milliseconds: 500), widget.onEnd);
        },
        child: CustomPaint(
          size: Size(w, 44),
          painter: _SliderPainter(t(widget.value), t(widget.defaultValue), _down),
        ),
      );
    });
  }
}

class _SliderPainter extends CustomPainter {
  _SliderPainter(this.t, this.def, this.down);
  final double t, def;
  final bool down;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final track = Paint()
      ..color = Neutral.hairline
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), track);
    canvas.drawLine(Offset(0, y), Offset(size.width * t, y), track..color = Neutral.primary);
    canvas.drawCircle(Offset(size.width * def, y), 1.6, Paint()..color = Neutral.tertiary);
    final r = down ? 9.0 : 7.0;
    canvas.drawCircle(Offset(size.width * t, y + 1), r + 0.5, Paint()..color = const Color(0x22000000));
    canvas.drawCircle(Offset(size.width * t, y), r, Paint()..color = Neutral.surface);
    canvas.drawCircle(
        Offset(size.width * t, y),
        r,
        Paint()
          ..color = Neutral.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4);
  }

  @override
  bool shouldRepaint(_SliderPainter o) => o.t != t || o.down != down;
}

class _MiniToggle extends StatelessWidget {
  const _MiniToggle({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 30,
      height: 18,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: on ? Neutral.primary : Neutral.hairline, borderRadius: BorderRadius.circular(9)),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutBack,
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(width: 14, height: 14, decoration: const BoxDecoration(color: Neutral.surface, shape: BoxShape.circle)),
      ),
    );
  }
}

class _AreaPainter extends CustomPainter {
  _AreaPainter(this.area, this.a, this.b);
  final Area? area;
  final Offset? a, b;

  @override
  void paint(Canvas canvas, Size s) {
    final line = Paint()
      ..color = const Color(0xE6FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final shadow = Paint()
      ..color = const Color(0x55000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    void draw(Path p) {
      canvas.drawPath(p, shadow);
      canvas.drawPath(p, line);
    }

    for (final poly in area?.polygons ?? const <List<List<double>>>[]) {
      if (poly.length < 3) continue;
      final p = Path()..moveTo(poly[0][0] * s.width, poly[0][1] * s.height);
      for (final q in poly.skip(1)) {
        p.lineTo(q[0] * s.width, q[1] * s.height);
      }
      draw(p..close());
    }
    for (final e in area?.ellipses ?? const <List<double>>[]) {
      draw(Path()
        ..addOval(Rect.fromCenter(center: Offset(e[0] * s.width, e[1] * s.height), width: e[2] * 2 * s.width, height: e[3] * 2 * s.height)));
    }
    if (a != null && b != null) {
      draw(Path()..addOval(Rect.fromPoints(Offset(a!.dx * s.width, a!.dy * s.height), Offset(b!.dx * s.width, b!.dy * s.height))));
    }
  }

  @override
  bool shouldRepaint(_AreaPainter o) => true;
}

class _LoupePainter extends CustomPainter {
  _LoupePainter(this.image, this.at, this.zoom);
  final ui.Image image;
  final Offset at;
  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = at.dx * image.width, cy = at.dy * image.height;
    final half = size.width / zoom / 2 * (image.width / 390);
    final src = Rect.fromLTRB(cx - half, cy - half, cx + half, cy + half);
    canvas.drawImageRect(image, src, Offset.zero & size, Paint()..filterQuality = FilterQuality.medium);
    final c = size.center(Offset.zero);
    final p = Paint()
      ..color = const Color(0xCCFFFFFF)
      ..strokeWidth = 1;
    canvas.drawLine(c - const Offset(6, 0), c + const Offset(6, 0), p);
    canvas.drawLine(c - const Offset(0, 6), c + const Offset(0, 6), p);
  }

  @override
  bool shouldRepaint(_LoupePainter o) => o.at != at;
}
