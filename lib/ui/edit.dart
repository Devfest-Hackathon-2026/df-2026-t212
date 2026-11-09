import 'widgets/agent_work_status.dart';
import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../agent/agent.dart';
import '../core/recipe.dart';
import '../core/renderer.dart';
import '../data/photo_source.dart';
import '../data/store.dart';
import '../data/subject.dart';
import 'edit_preview.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/controls.dart';
import 'widgets/photo_zoom.dart';

class EditRoute extends PageRouteBuilder<void> {
  EditRoute(PhotoItem item)
    : super(
        transitionDuration: const Duration(milliseconds: 380),
        pageBuilder: (_, _, _) => EditScreen(item: item),
        transitionsBuilder: (_, a, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.04),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: a, curve: Motion.settle)),
            child: child,
          ),
        ),
      );
}

enum _Tool { accent, area, mono }

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
  final List<Recipe> _undo = [], _redo = [];

  /// Records the state before a change. A new change ends any redo.
  void _push(Recipe r) {
    _undo.add(r);
    _redo.clear();
  }

  _Tool _tool = _Tool.accent;

  /// Selected slot. Equal to the number of colors: the empty "add" slot.
  int _keptActive = 0, _excludedActive = 0;
  bool _excluding = false;
  int get _active => _excluding ? _excludedActive : _keptActive;
  set _active(int value) {
    if (_excluding) {
      _excludedActive = value;
    } else {
      _keptActive = value;
    }
  }
  List<KeptColor> get _colors => _excluding ? _r.excludedColors : _r.colors;
  bool get _showColorModes => _tool == _Tool.accent && (_advanced || _excluding || _r.excludedColors.isNotEmpty);

  void _setExcluding(bool value) {
    Haptics.tick();
    setState(() {
      _excluding = value;
      _active = _active.clamp(0, _addSlot);
      _from = null;
      _offer = null;
    });
  }

  /// The color selected before the add slot was: a new color starts from
  /// its Width and Edge, as in the camera.
  int? _from;
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
  bool _vignetting = false; // the vignette is being slid: show its edge

  AgentRun? _run;
  StreamSubscription<Recipe>? _runSub;
  bool _touched = false;

  Offset? _loupe; // normalized
  // Area: tap a thing, then paint to add or erase; two fingers zoom.
  bool _erase = false;
  double _brush = 0.05; // tip radius on screen, as a fraction of the photo's short side at 1×
  bool _sizing = false; // the Brush slider is held: show the tip
  bool _finding = false; // looking for the outline under a tap
  Stroke? _live; // the stroke being laid down
  Recipe? _beforeStroke;
  final Set<int> _photoPointers = {};
  // Remains true until the next touch sequence, even after one finger lifts.
  bool _multiTouch = false;
  Offset? _tip; // normalized, while painting
  Matrix4? _pinchFrom;
  Offset? _pinchAt;
  final _viewKey = GlobalKey();
  ui.Image? _veil;
  bool _veiling = false, _veilAgain = false;
  final List<_Ping> _pings = [];
  int _pingId = 0;

  // Asking the agent: words, marks on the photo, or a pick it should fit.
  bool _asking = false;
  final List<Mark> _marks = [];
  final _askText = TextEditingController();
  final _askFocus = FocusNode();
  String? _note; // what the agent changed, until the next change
  ({Offset at, KeptColor color})? _offer; // a pick that landed outside the area
  bool _byHand = false;

  @override
  void initState() {
    super.initState();
    if (_it.state == Develop.pending) Store.instance.hold(_it);
    final run = Store.instance.runFor(_it);
    if (run != null) _attach(run);
    _askFocus.addListener(_askFocusChanged);
    _load();
  }

  @override
  void dispose() {
    _images?.cancel();
    _runSub?.cancel();
    _worker?.dispose();
    _zoom.dispose();
    _askText.dispose();
    _askFocus.dispose();
    Store.instance.release(_it);
    super.dispose();
  }

  Future<void> _load() async {
    final px = await PhotoSource.pixels(_it.id, 900);
    if (px == null || !mounted) return;
    final workerF = PreviewWorker.start(px);
    final lab = await _labOf(px);
    final peaks = huePeaks(lab, top: 8);
    final cands = peaks
        .where((p) => p.meanChroma > 0.04)
        .map((p) {
          final h = (p.from + p.to) / 2 * math.pi / 180;
          return KeptColor(l: p.meanL, a: p.meanChroma * math.cos(h), b: p.meanChroma * math.sin(h));
        })
        .take(6)
        .toList();
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

  void _request() {
    _worker?.request(_r, view: _mask || _sliding ? PreviewView.mask : PreviewView.result);
    _refreshVeil();
  }

  /// A white veil over what lies outside the area, so painting shows where
  /// color stays.
  Future<void> _refreshVeil() async {
    if (_veiling) {
      _veilAgain = true;
      return;
    }
    final a = _r.area, px = _px;
    if (a == null || a.isEmpty || px == null) {
      if (_veil != null) setState(() => _veil = null);
      return;
    }
    _veiling = true;
    const w = 320;
    final h = math.max(1, (w * px.height / px.width).round());
    final m = areaMask(w, h, a);
    final bytes = Uint8List(w * h * 4);
    for (var i = 0; i < m.length; i++) {
      // Premultiplied: white at this strength.
      final v = ((1 - m[i]) * 150).round();
      bytes[i * 4] = bytes[i * 4 + 1] = bytes[i * 4 + 2] = bytes[i * 4 + 3] = v;
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(bytes, w, h, ui.PixelFormat.rgba8888, done.complete);
    final img = await done.future;
    _veiling = false;
    if (!mounted) return img.dispose();
    final old = _veil;
    setState(() => _veil = img);
    if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    if (_veilAgain) {
      _veilAgain = false;
      _refreshVeil();
    }
  }

  double get _zoomScale => _zoom.value.getMaxScaleOnAxis();

  void _strokeStart(Offset n) {
    _beforeStroke = _r.copy();
    final st = Stroke(points: [[n.dx, n.dy]], radius: _brush / _zoomScale, erase: _erase);
    _live = st;
    _tip = n;
    _change(() {
      final a = _r.area?.copy() ?? Area(edge: Area.defaultEdgeFor(_sourceShort));
      a.strokes = [...a.strokes, st];
      _r.area = a;
    }, record: false);
  }

  void _strokeMove(Offset n, Size box) {
    final st = _live;
    if (st == null) return;
    final last = st.points.last;
    _tip = n;
    // Points a few pixels apart are enough; the line between them is filled.
    if (Offset((n.dx - last[0]) * box.width, (n.dy - last[1]) * box.height).distance < 3) {
      setState(() {});
      return;
    }
    _change(() => st.points.add([n.dx, n.dy]), record: false);
  }

  void _strokeEnd({bool drop = false}) {
    if (_live == null) return;
    _live = null;
    if (drop) {
      // A second finger came down: it was the start of a pinch, not paint.
      _change(() {
        _r.area = _beforeStroke?.area;
      }, record: false);
    } else {
      if (_beforeStroke != null) _push(_beforeStroke!);
      Haptics.tick();
    }
    _beforeStroke = null;
    setState(() => _tip = null);
  }

  void _photoDown(PointerDownEvent event) {
    if (_photoPointers.isEmpty) _multiTouch = false;
    _photoPointers.add(event.pointer);
    if (_photoPointers.length > 1) {
      _multiTouch = true;
      _strokeEnd(drop: true);
    }
  }

  void _photoUp(PointerEvent event) => _photoPointers.remove(event.pointer);

  void _photoCancel(PointerCancelEvent event) {
    _multiTouch = true;
    _photoUp(event);
    _strokeEnd(drop: true);
  }

  Offset _inView(Offset global) => (_viewKey.currentContext!.findRenderObject() as RenderBox).globalToLocal(global);

  void _pinchStart(Offset focal) {
    _pinchFrom = _zoom.value.clone();
    _pinchAt = _inView(focal);
  }

  void _pinchMove(Offset focal, double scale) {
    final from = _pinchFrom, f0 = _pinchAt;
    final box = _viewKey.currentContext?.size;
    if (from == null || f0 == null || box == null) return;
    final s0 = from.getMaxScaleOnAxis();
    final k = (s0 * scale).clamp(1.0, PhotoZoomController.maxScale) / s0;
    final f = _inView(focal);
    final m = Matrix4.translationValues(f.dx, f.dy, 0)
      ..multiply(Matrix4.diagonal3Values(k, k, 1))
      ..multiply(Matrix4.translationValues(-f0.dx, -f0.dy, 0))
      ..multiply(from);
    final s = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    m.setTranslationRaw(
      t.x.clamp(box.width - box.width * s, 0.0),
      t.y.clamp(box.height - box.height * s, 0.0),
      0,
    );
    _zoom.value = m;
  }

  /// Tap in Area: pick out the thing there, or with Erase, take a shape away.
  Future<void> _areaTap(Offset n, Size box) async {
    final a = _r.area;
    if (_erase) {
      final i = a == null ? -1 : a.polygons.lastIndexWhere((p) => _inside(p, n));
      final j = a == null ? -1 : a.ellipses.lastIndexWhere((e) {
        final dx = (n.dx - e[0]) / math.max(e[2], 1e-6), dy = (n.dy - e[1]) / math.max(e[3], 1e-6);
        return dx * dx + dy * dy <= 1;
      });
      if (i < 0 && j < 0) return Haptics.tick();
      Haptics.light();
      _change(() {
        final b = a!.copy();
        if (i >= 0) {
          b.polygons = [...b.polygons]..removeAt(i);
        } else {
          b.ellipses = [...b.ellipses]..removeAt(j);
        }
        _r.area = b.isEmpty ? null : b;
      });
      return;
    }
    final px = _px;
    if (px == null || _finding) return;
    Haptics.tick();
    _ping(Offset(n.dx * box.width, n.dy * box.height), null);
    setState(() => _finding = true);
    final polys = await Subject.outline(px, n);
    if (!mounted) return;
    setState(() => _finding = false);
    if (polys == null || polys.isEmpty) {
      Haptics.warning();
      setState(() => _note = polys == null ? 'This phone cannot pick things out. Paint instead' : 'Nothing stands out there. Paint it instead');
      return;
    }
    Haptics.light();
    _change(() {
      final b = _r.area?.copy() ?? Area(edge: Area.defaultEdgeFor(_sourceShort));
      b.polygons = [...b.polygons, ...polys];
      _r.area = b;
    });
  }

  static bool _inside(List<List<double>> poly, Offset n) {
    var c = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final yi = poly[i][1], yj = poly[j][1];
      if ((yi > n.dy) != (yj > n.dy) && n.dx < (poly[j][0] - poly[i][0]) * (n.dy - yi) / (yj - yi) + poly[i][0]) c = !c;
    }
    return c;
  }

  // ------------------------------------------------------------ agent

  void _attach(AgentRun run) {
    _run = run;
    if (run.recipe.colors.isNotEmpty) _r = run.recipe.copy();
    _runSub = run.changes.listen(
      (r) {
        if (!mounted || _run != run) return;
        setState(() {
          _r = r;
          _active = _active.clamp(0, _addSlot);
        });
        _request();
      },
      onDone: () {
        if (!mounted || _run != run) return;
        // Finished on its own: show what it settled on.
        setState(() {
          _run = null;
          if (_it.edit != null) _r = _it.edit!.copy();
          _active = 0;
        });
        Haptics.firm();
        _request();
      },
    );
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

  int get _addSlot => math.min(_colors.length, Recipe.maxColors - 1);
  bool get _adding => _active >= _colors.length;
  KeptColor? get _cur => _adding ? null : _colors[_active];

  void _change(void Function() f, {bool record = true}) {
    _takeOver();
    if (record) _push(_r.copy());
    _byHand = true;
    setState(() {
      _offer = null;
      _note = null;
      f();
    });
    _request();
  }

  /// Put [c] in the selected slot: replaces that color, or adds a new one.
  void _pick(KeptColor c) {
    Haptics.light();
    _change(() {
      if (_adding) {
        final like = _colors.isEmpty ? null : _colors[math.min(_from ?? _colors.length - 1, _colors.length - 1)];
        _colors.add(
          c
            ..width = like?.width ?? (_excluding ? Recipe.defaultExcludeWidth : 16)
            ..softness = like?.softness ?? (_excluding ? Recipe.defaultExcludeSoftness : 20),
        );
        _active = _colors.length - 1;
        _from = null;
      } else {
        final old = _colors[_active];
        _colors[_active] = c
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
    // Color only stays inside the area: a pick outside it changes nothing.
    if (!_excluding && _outsideArea(n)) setState(() => _offer = (at: n, color: c));
  }

  bool _outsideArea(Offset n) {
    final a = _r.area, px = _px;
    if (a == null || a.isEmpty || px == null) return false;
    const w = 96;
    final h = math.max(1, (w * px.height / px.width).round());
    final m = areaMask(w, h, a);
    return m[(n.dy * (h - 1)).round() * w + (n.dx * (w - 1)).round()] < 0.5;
  }

  // ------------------------------------------------------------ asking the agent

  /// A tap while asking marks the object there: keep, then no color, then gone.
  void _mark(Offset n, Size box) {
    Haptics.light();
    final near = _marks.indexWhere((m) => Offset((m.x - n.dx) * box.width, (m.y - n.dy) * box.height).distance < 22);
    setState(() {
      if (near < 0) {
        _marks.add(Mark(n.dx, n.dy, MarkIntent.keep));
      } else if (_marks[near].intent == MarkIntent.keep) {
        _marks[near] = Mark(_marks[near].x, _marks[near].y, MarkIntent.remove);
      } else {
        _marks.removeAt(near);
      }
    });
  }

  void _send(String? text) {
    final t = text?.trim();
    if ((t == null || t.isEmpty) && _marks.isEmpty) return;
    FocusScope.of(context).unfocus();
    _ask(Revision(text: t, marks: List.of(_marks)));
    setState(() {
      _asking = false;
      _askText.clear();
    });
  }

  void _fit() {
    final o = _offer;
    if (o == null) return;
    final m = Mark(o.at.dx, o.at.dy, MarkIntent.picked, color: o.color);
    setState(
      () => _marks
        ..clear()
        ..add(m),
    );
    _ask(Revision(marks: [m]));
  }

  /// The agent changes the current edit as asked. Its work shows live; one
  /// Undo takes the whole change back.
  void _ask(Revision req) {
    if (_run != null) return;
    _takeOver();
    final before = _r.copy();
    _push(before.copy());
    final run = Store.instance.reviseNow(_it, _r, req);
    Haptics.light();
    setState(() {
      _run = run;
      _offer = null;
      _note = null;
    });
    _runSub?.cancel();
    _runSub = run.changes.listen(
      (r) {
        if (!mounted || _run != run) return;
        setState(() {
          _r = r;
          _active = _active.clamp(0, _addSlot);
        });
        _request();
      },
      onDone: () {
        if (!mounted || _run != run) return;
        final ok = run.result != null;
        setState(() {
          _run = null;
          _r = ok ? run.result!.copy() : before;
          if (!ok && _undo.isNotEmpty) _undo.removeLast();
          _note = ok ? (run.note ?? 'Done') : 'The agent could not do that. Nothing changed';
          _marks.clear();
          _active = _active.clamp(0, _addSlot);
        });
        ok ? Haptics.success() : Haptics.warning();
        _request();
      },
    );
  }

  void _remove(int i) {
    Haptics.light();
    _change(() {
      _colors.removeAt(i);
      _active = math.min(i, _addSlot);
      _from = null;
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
      if (t != _Tool.accent) _excluding = false;
      _from = null;
    });
  }

  void _done() {
    final run = _run;
    if (run != null && !run.cancelled) {
      Store.instance.continueEditing(_it, run);
      Navigator.pop(context);
      return;
    }
    _takeOver();
    Store.instance.setEdit(_it, _r..why = _byHand ? 'Edited by hand.' : _r.why);
    Navigator.pop(context);
  }

  // ------------------------------------------------------------ layout

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final running = _run != null;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      backgroundColor: Neutral.bg,
      // Keep the whole photo above the composer and keyboard.
      resizeToAvoidBottomInset: true,
      body: Column(
        children: [
          SizedBox(height: pad.top),
          Row(
            children: [
              TextAction('Cancel', color: Neutral.secondary, onTap: () => Navigator.pop(context)),
              _HistoryButton(redo: false, onTap: _undo.isEmpty ? null : _stepBack),
              _HistoryButton(redo: true, onTap: _redo.isEmpty ? null : _stepForward),
              const Spacer(),
              if (running) ...[
                const CupertinoActivityIndicator(radius: 8, color: Neutral.primary),
                TextAction('Stop', onTap: () => setState(_takeOver)),
              ] else
                TextAction('Auto', onTap: _auto),
              TextAction('Done', onTap: _done),
              const SizedBox(width: 6),
            ],
          ),
          Expanded(child: _photo()),
          if (_asking) ...[
            if (keyboard == 0 && !_askFocus.hasFocus) _askPhotoTools(),
            Padding(
              padding: EdgeInsets.fromLTRB(12, 4, 12, keyboard > 0 ? 8 : pad.bottom + 12),
              child: _askPanel(),
            ),
          ] else ...[
            _viewBar(),
            _panel(pad),
          ],
        ],
      ),
    );
  }

  void _askFocusChanged() {
    if (mounted) setState(() {});
  }

  void _stepBack() => _change(() {
    _redo.add(_r.copy());
    _r = _undo.removeLast();
  }, record: false);

  void _stepForward() => _change(() {
    _undo.add(_r.copy());
    _r = _redo.removeLast();
  }, record: false);

  final _zoom = PhotoZoomController();

  Widget _photo() {
    final it = _it;
    final px = _px;
    final ratio = px != null ? px.width / px.height : it.width / it.height;
    final areaMode = _tool == _Tool.area && !_asking;
    final asking = _asking;
    return LayoutBuilder(
      builder: (context, outer) {
        // The photo, fitted with a margin; pinch zooms it over the whole area.
        const m = 16.0;
        final availW = outer.maxWidth - m * 2, availH = outer.maxHeight - m * 2;
        final w = math.min(availW, availH * ratio), h = w / ratio;
        final size = Size(w, h);
        final viewport = Size(outer.maxWidth, outer.maxHeight);
        final frame = Rect.fromCenter(center: viewport.center(Offset.zero), width: w, height: h);
        _zoom.setGeometry(viewport, frame);
        WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _zoom.settle(); });
        Offset norm(Offset p) => Offset((p.dx / w).clamp(0, 1), (p.dy / h).clamp(0, 1));
        final photo = SizedBox(
          width: w,
          height: h,
          child: GestureDetector(
            onTapUp: areaMode
                ? (d) { if (!_multiTouch) _areaTap(norm(d.localPosition), size); }
                : (d) {
                    if (!asking) return _pickAt(norm(d.localPosition), size);
                    // With the keyboard up, the first tap only puts it away so the whole photo shows.
                    if (MediaQuery.viewInsetsOf(context).bottom > 0) return FocusScope.of(context).unfocus();
                    _mark(norm(d.localPosition), size);
                  },
            onLongPressStart: areaMode || asking ? null : (d) => setState(() => _loupe = norm(d.localPosition)),
            onLongPressMoveUpdate: areaMode || asking
                ? null
                : (d) {
                    final n = norm(d.localPosition);
                    if (_loupe != null && (n - _loupe!).distance > 0.02) Haptics.tick();
                    setState(() => _loupe = n);
                  },
            onLongPressEnd: areaMode || asking
                ? null
                : (d) {
                    final n = _loupe;
                    setState(() => _loupe = null);
                    if (n != null) _pickAt(n, size);
                  },
            onScaleStart: areaMode
                ? (d) {
                    if (d.pointerCount >= 2) {
                      _pinchStart(d.focalPoint);
                    } else if (!_multiTouch) {
                      _strokeStart(norm(d.localFocalPoint));
                    }
                  }
                : null,
            onScaleUpdate: areaMode
                ? (d) {
                    if (d.pointerCount >= 2) {
                      if (_live != null) _strokeEnd(drop: true);
                      if (_pinchFrom == null) _pinchStart(d.focalPoint);
                      _pinchMove(d.focalPoint, d.scale);
                    } else if (!_multiTouch) {
                      _strokeMove(norm(d.localFocalPoint), size);
                    }
                  }
                : null,
            onScaleEnd: areaMode
                ? (d) {
                    _pinchFrom = _pinchAt = null;
                    _strokeEnd(drop: _multiTouch || d.pointerCount > 0);
                  }
                : null,
            child: Stack(
              clipBehavior: Clip.none,
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_before && _original != null)
                        RawImage(image: _original, fit: BoxFit.fill, filterQuality: FilterQuality.medium)
                      else if (_preview != null)
                        RawImage(image: _preview, fit: BoxFit.fill, filterQuality: FilterQuality.medium)
                      else
                        Hero(
                          createRectTween: straightRect,
                          tag: 'photo-${it.key}',
                          child: it.edit == null
                              ? OriginalImage(it, size: 900)
                              : DevelopedImage(
                                  it,
                                  size: 1600,
                                  fit: BoxFit.cover,
                                  alignment: Alignment.center,
                                  placeholder: OriginalImage(it, size: 900),
                                ),
                        ),
                      if (areaMode && _veil != null && !_before)
                        IgnorePointer(
                          child: RawImage(image: _veil, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                        ),
                      if (areaMode)
                        IgnorePointer(
                          child: CustomPaint(
                            painter: _AreaPainter(
                              _r.area,
                              tip: _tip ?? (_sizing ? const Offset(0.5, 0.5) : null),
                              radius: _brush / _zoomScale * math.min(w, h),
                              erase: _erase,
                            ),
                          ),
                        ),
                      // Where the vignette starts, while it is slid.
                      IgnorePointer(
                        child: AnimatedOpacity(
                          opacity: _vignetting && _r.vignette > 0 ? 1 : 0,
                          duration: const Duration(milliseconds: 220),
                          curve: Motion.settle,
                          child: CustomPaint(painter: _VignetteRing(_r.vignetteRadius)),
                        ),
                      ),
                    ],
                  ),
                ),
                for (final p in _pings) _PingRing(key: ValueKey(p.id), ping: p),
                for (var k = 0; k < _marks.length; k++)
                  Positioned(
                    left: _marks[k].x * w - 11,
                    top: _marks[k].y * h - 11,
                    child: IgnorePointer(child: _MarkDot(_marks[k], k + 1)),
                  ),
              ],
            ),
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
          child: Stack(
            children: [
              Positioned.fill(
                key: _viewKey,
                child: Listener(
                  onPointerDown: _photoDown,
                  onPointerUp: _photoUp,
                  onPointerCancel: _photoCancel,
                  child: InteractiveViewer(
                  transformationController: _zoom,
                  minScale: 1,
                  maxScale: PhotoZoomController.maxScale,
                  // Area owns one-finger paint and two-finger zoom.
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
              ),
              ?loupe,
            ],
          ),
        );
      },
    );
  }

  /// One line between the photo and the tools: what is shown, and how to compare.
  Widget _viewBar() {
    final showMask = _mask || _sliding;
    final running = _run != null;
    final offer = _offer != null && !running && !_before && !showMask;
    final status = _finding
        ? 'Looking for the thing there…'
        : _before
        ? 'Before'
        : showMask
        ? 'Showing where color is kept'
        : running
        ? 'Agent is ${agentWorkLabel(_run!.status)}… Edit anything to take over'
        : offer
        ? 'This spot is outside the area'
        : _note != null
        ? _note!
        : _it.state == Develop.manual && _it.note != null && _r.colors.isEmpty
        ? 'Agent skipped · ${_it.note}'
        : '';
    return SizedBox(
      height: 36,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            const SizedBox(width: 10),
            if ((running && !showMask && !_before) || _finding) ...[
              const CupertinoActivityIndicator(radius: 7, color: Neutral.secondary),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                switchInCurve: Motion.settle,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: softSwitch,
                child: Align(
                  key: ValueKey(status),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    status,
                    style: Txt.small.copyWith(fontSize: 12, height: 1.2),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            if (offer) ...[
              _ViewButton(label: 'Let the agent fit it', on: true, onTap: _fit),
              _ViewButton(label: 'Ignore', on: false, onTap: () => setState(() => _offer = null)),
            ] else ...[
              _ViewButton(
                label: 'Ask',
                on: _asking,
                onTap: running
                    ? null
                    : () {
                        Haptics.tick();
                        setState(() {
                          _asking = !_asking;
                          if (!_asking) _marks.clear();
                        });
                      },
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
            ],
          ],
        ),
      ),
    );
  }


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
          child: ClipOval(child: CustomPaint(painter: _LoupePainter(_original!, _loupe!, zoom * scale))),
        ),
      ),
    );
  }

  static const _suggestions = ['Only the subject', 'Less color', 'More mood'];

  Widget _askPhotoTools() {
    final keeps = _marks.where((m) => m.intent == MarkIntent.keep).length;
    final removes = _marks.length - keeps;
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 10, bottom: 4),
      child: Row(children: [
        Expanded(child: Text(
          _marks.isEmpty
              ? 'Tap the photo to mark things'
              : '${[if (keeps > 0) '$keeps keep color', if (removes > 0) '$removes no color'].join(' · ')} · tap to switch',
          style: Txt.small.copyWith(fontSize: 12, color: const Color(0xA6000000)),
        )),
        _ViewButton(label: 'Mask', on: _mask, onTap: () {
          Haptics.tick();
          setState(() => _mask = !_mask);
          _request();
        }),
        _ViewButton(label: 'Before', on: _before, onHold: (on) => setState(() => _before = on)),
      ]),
    );
  }

  /// A quiet composer; typing gets the space, with suggestions only at rest.
  Widget _askPanel() {
    final canSend = _askText.text.trim().isNotEmpty || _marks.isNotEmpty;
    final typing = _askFocus.hasFocus || MediaQuery.viewInsetsOf(context).bottom > 0;
    return Glass(
      dock: true,
      radius: 22,
      padding: const EdgeInsets.fromLTRB(16, 0, 6, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text('Ask the agent', style: Txt.small.copyWith(
              color: const Color(0xA6000000), fontWeight: FontWeight.w500,
            ))),
            IconButton(
              tooltip: 'Close',
              onPressed: () {
                Haptics.tick();
                _askFocus.unfocus();
                setState(() {
                  _asking = false;
                  _marks.clear();
                });
              },
              constraints: const BoxConstraints.tightFor(width: 44, height: 44),
              padding: EdgeInsets.zero,
              icon: const Glyph(G.close, size: 16, color: Color(0xA6000000)),
            ),
          ]),
          AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.only(left: 12, right: 2),
            decoration: BoxDecoration(
              color: const Color(0x80FFFFFF),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _askFocus.hasFocus ? const Color(0x66000000) : const Color(0x24000000), width: .8),
            ),
            child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _askText,
                  focusNode: _askFocus,
                  minLines: 1,
                  maxLines: 3,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: _send,
                  textInputAction: TextInputAction.send,
                  style: Txt.body.copyWith(height: 1.35),
                  cursorColor: Neutral.primary,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'What should change?',
                    hintStyle: Txt.body.copyWith(height: 1.35, color: const Color(0xA6000000)),
                    contentPadding: const EdgeInsets.only(top: 8, bottom: 12, right: 8),
                  ),
                ),
              ),
              Semantics(
                label: 'Send request', button: true, enabled: canSend,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: canSend ? () => _send(_askText.text) : null,
                  child: SizedBox(
                    width: 44, height: 44,
                    child: Center(child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      curve: Motion.settle,
                      width: 34, height: 34,
                      decoration: BoxDecoration(
                        color: canSend ? Neutral.primary : const Color(0x14000000),
                        shape: BoxShape.circle,
                      ),
                      child: Center(child: Glyph(G.up, size: 18,
                        color: canSend ? Neutral.surface : const Color(0x66000000), weight: 1.8)),
                    )),
                  ),
                ),
              ),
            ],
          ),
          ),
          if (!typing && _askText.text.trim().isEmpty) ...[
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final text in _suggestions)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Semantics(
                      button: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () { Haptics.tick(); _send(text); },
                        child: SizedBox(height: 44, child: Center(
                          child: Text(text, style: Txt.small.copyWith(color: const Color(0xB3000000))),
                        )),
                      ),
                    ),
                  ),
              ]),
            ),
          ],
        ],
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  switchInCurve: Motion.settle,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: softSwitch,
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
                  setState(() {
                    _advanced = !_advanced;
                    if (!_advanced && _r.excludedColors.isEmpty) _excluding = false;
                  });
                },
                child: Row(
                  children: [
                    Text(_tool == _Tool.accent ? 'Advanced' : 'Values', style: Txt.small.copyWith(color: _advanced ? Neutral.primary : Neutral.tertiary)),
                    const SizedBox(width: 8),
                    _MiniToggle(on: _advanced),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            curve: Motion.settle,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Motion.settle,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: softSwitch,
              child: SizedBox(
                key: ValueKey(_tool),
                height: _tool == _Tool.area ? 182 : _showColorModes ? 174 : 138,
                child: _toolBody(),
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Hairline(),
          Row(
            children: [
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
                      child: Column(
                        children: [
                          Text(
                            _label(t),
                            style: Txt.label.copyWith(color: _tool == t ? Neutral.primary : Neutral.tertiary),
                          ),
                          const SizedBox(height: 5),
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Motion.settle,
                            width: _tool == t ? 16 : 0,
                            height: 2,
                            decoration: BoxDecoration(color: Neutral.primary, borderRadius: BorderRadius.circular(1)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _label(_Tool t) => switch (t) {
    _Tool.accent => 'Color',
    _Tool.area => 'Area',
    _Tool.mono => 'Tone',
  };

  String get _toolTitle => switch (_tool) {
    _Tool.accent => _excluding
        ? (_adding ? 'Tap a color to exclude' : 'Adjust the color to exclude')
        : (_adding ? 'Tap the photo to add a color' : 'Tap the photo to change this color'),
    _Tool.area => _erase ? 'Paint to take color away' : 'Tap a thing, or paint over it',
    _Tool.mono => 'The black and white part',
  };

  Widget _colorMode(String label, int count, bool exclude) {
    final selected = _excluding == exclude;
    return Semantics(
      button: true, selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _setExcluding(exclude),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('$label · $count', style: Txt.small.copyWith(
            color: selected ? Neutral.primary : Neutral.secondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          )),
        ),
      ),
    );
  }

  Widget _toolBody() {
    switch (_tool) {
      case _Tool.accent:
        final c = _cur;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_showColorModes)
              SizedBox(
                height: 36,
                child: Row(children: [
                  _colorMode('Keep', _r.colors.length, false),
                  const SizedBox(width: 22),
                  _colorMode('Exclude', _r.excludedColors.length, true),
                ]),
              ),
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  for (var i = 0; i <= _addSlot; i++) Padding(padding: const EdgeInsets.only(right: 8), child: _slot(i)),
                  const Spacer(),
                  if (_advanced && c != null) Text(oklabToHex(c.l, c.a, c.b).toUpperCase(), style: Txt.mono),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Motion.settle,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: softSwitch,
                layoutBuilder: (cur, prev) => Stack(alignment: Alignment.topLeft, children: [...prev, ?cur]),
                child: c == null ? KeyedSubtree(key: const ValueKey('add'), child: _fromPhoto()) : _reach(c),
              ),
            ),
          ],
        );
      case _Tool.area:
        return Column(
          children: [
            SizedBox(
              height: 40,
              child: Row(
                children: [
                  _modeChip('Add', !_erase, () => setState(() => _erase = false)),
                  const SizedBox(width: 4),
                  _modeChip('Erase', _erase, () => setState(() => _erase = true)),
                  const Spacer(),
                  TextAction('Clear', onTap: _r.area == null ? null : () => _change(() => _r.area = null)),
                ],
              ),
            ),
            SliderRow(
              height: 44,
              label: 'Brush',
              value: _brush * 100,
              min: 1,
              max: 15,
              defaultValue: 5,
              advanced: _advanced,
              onStart: () => setState(() => _sizing = true),
              onEnd: () => setState(() => _sizing = false),
              onChanged: (v) => setState(() => _brush = v / 100),
            ),
            _areaSlider(feather: false),
            _areaSlider(feather: true),
          ],
        );
      case _Tool.mono:
        return Column(
          children: [
            SliderRow(
              height: 34,
              label: 'Contrast',
              value: _r.contrast * 100,
              min: -30,
              max: 40,
              defaultValue: 10,
              advanced: _advanced,
              onStart: () => _push(_r.copy()),
              onEnd: () {},
              onChanged: (v) => _change(() => _r.contrast = v / 100, record: false),
            ),
            SliderRow(
              height: 34,
              label: 'Mood',
              value: _r.ambience * 100,
              min: 0,
              max: 100,
              defaultValue: Recipe.defaultAmbience * 100,
              advanced: _advanced,
              onStart: () => _push(_r.copy()),
              onEnd: () {},
              onChanged: (v) => _change(() => _r.ambience = v / 100, record: false),
            ),
            SliderRow(
              height: 34,
              label: 'Vignette',
              value: _r.vignette * 100,
              min: 0,
              max: 100,
              defaultValue: 0,
              advanced: _advanced,
              onStart: () {
                _push(_r.copy());
                setState(() => _vignetting = true);
              },
              onEnd: () => setState(() => _vignetting = false),
              onChanged: (v) => _change(() => _r.vignette = v / 100, record: false),
            ),
            // The vignette's own size: there only while there is a vignette.
            AnimatedSize(
              duration: const Duration(milliseconds: 260),
              curve: Motion.settle,
              alignment: Alignment.topCenter,
              child: _r.vignette <= 0
                  ? const SizedBox(width: double.infinity)
                  : SliderRow(
                      height: 34,
                      label: 'Radius',
                      value: _r.vignetteRadius * 100,
                      min: 30,
                      max: 130,
                      defaultValue: Recipe.defaultVignetteRadius * 100,
                      advanced: _advanced,
                      onStart: () {
                        _push(_r.copy());
                        setState(() => _vignetting = true);
                      },
                      onEnd: () => setState(() => _vignetting = false),
                      onChanged: (v) => _change(() => _r.vignetteRadius = v / 100, record: false),
                    ),
            ),
          ],
        );
    }
  }

  /// One side of Add / Erase: the chosen one filled.
  Widget _modeChip(String label, bool on, VoidCallback onTap) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: on
        ? null
        : () {
            Haptics.tick();
            onTap();
          },
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Motion.settle,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(color: on ? Neutral.primary : Colors.transparent, borderRadius: BorderRadius.circular(16)),
      child: Text(label, style: Txt.label.copyWith(color: on ? Neutral.surface : Neutral.secondary)),
    ),
  );

  /// What the photo offers, while the add slot is selected.
  Widget _fromPhoto() => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('From this photo', style: Txt.mono),
        const SizedBox(height: 10),
        SizedBox(
          height: 28,
          child: Row(
            children: [
              for (final c in _candidates)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Swatch(c, size: 28, from: _it, onTap: () => _pick(c.copy())),
                ),
              if (_candidates.isEmpty) Text(_lab == null ? '' : 'No strong colors.', style: Txt.small),
            ],
          ),
        ),
      ],
    ),
  );

  double get _sourceShort => math.max(1, math.min(_it.width, _it.height)).toDouble();

  void _setAreaValue(double pixels, {required bool feather, bool record = true}) {
    _change(() {
      final area = _r.area ??= Area(edge: Area.defaultEdgeFor(_sourceShort));
      if (feather) { area.edge = pixels / _sourceShort; }
      else { area.boundary = pixels / _sourceShort; }
    }, record: record);
  }

  Future<void> _enterAreaValue({required bool feather}) async {
    final value = (feather ? _r.area?.edge ?? Area.defaultEdgeFor(_sourceShort) : _r.area?.boundary ?? 0) * _sourceShort;
    final result = await showCupertinoDialog<double>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _AreaValueDialog(value: value, shortSide: _sourceShort, feather: feather),
    );
    if (result != null && mounted) _setAreaValue(result, feather: feather);
  }

  Widget _areaSlider({required bool feather}) {
    final value = (feather ? _r.area?.edge ?? Area.defaultEdgeFor(_sourceShort) : _r.area?.boundary ?? 0) * _sourceShort;
    final span = math.max(_sourceShort * 0.1, value.abs());
    return SliderRow(
      height: 44,
      label: feather ? 'Feather' : 'Boundary',
      value: value,
      min: feather ? 0 : -span,
      max: span,
      defaultValue: feather ? Area.defaultFeatherPixels : 0,
      advanced: true,
      valueLabel: '${!feather && value > 0 ? '+' : ''}${value.toStringAsFixed(1)} px',
      onValueTap: () => _enterAreaValue(feather: feather),
      onStart: () { _push(_r.copy()); _slide(true); },
      onEnd: () => _slide(false),
      onChanged: (v) => _setAreaValue(v.roundToDouble(), feather: feather, record: false),
    );
  }

  /// How far the selected color reaches: the same Width and Edge as the camera.
  Widget _reach(KeptColor c) => Column(
    key: const ValueKey('reach'),
    children: [
      SliderRow(
        height: 44,
        label: 'Width',
        value: c.width,
        min: 0,
        max: 60,
        defaultValue: _excluding ? Recipe.defaultExcludeWidth : 16,
        advanced: _advanced,
        detail: '${((c.hue - c.width + 360) % 360).round()}°–${((c.hue + c.width) % 360).round()}°',
        onStart: () {
          _push(_r.copy());
          _slide(true);
        },
        onEnd: () => _slide(false),
        onChanged: (v) => _change(() => c.width = v, record: false),
      ),
      SliderRow(
        height: 44,
        label: 'Edge',
        value: c.softness,
        min: 0,
        max: 60,
        defaultValue: _excluding ? Recipe.defaultExcludeSoftness : 20,
        advanced: _advanced,
        detail: '+${c.softness.round()}°',
        onStart: () {
          _push(_r.copy());
          _slide(true);
        },
        onEnd: () => _slide(false),
        onChanged: (v) => _change(() => c.softness = v, record: false),
      ),
    ],
  );

  /// A kept color, or the slot to add one into. The selected one is ringed
  /// and carries the cross that takes it away, as in the camera.
  Widget _slot(int i) {
    final filled = i < _colors.length;
    final sel = filled ? i == _active : _adding;
    final c = filled ? _colors[i] : null;
    const s = 38.0;
    return SizedBox(
      width: s + 6,
      height: s + 6,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          GestureDetector(
            onTap: () {
              if (sel) return;
              Haptics.tick();
              setState(() {
                if (!filled && !_adding) _from = _active;
                _active = i;
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Motion.settle,
              width: s,
              height: s,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: sel ? Neutral.primary : Colors.transparent, width: 1.5),
              ),
              child: filled
                  ? DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: const Color(0x14000000), width: 0.6),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(9),
                        child: ColoredBox(color: colorOf(c!), child: PhotoPatch(_it, c)),
                      ),
                    )
                  : CustomPaint(painter: DashedSlot(plus: true, strong: sel, radius: 9)),
            ),
          ),
          if (filled && sel)
            Positioned(
              top: -3,
              right: -3,
              child: GestureDetector(
                onTap: () => _remove(i),
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: Neutral.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Neutral.surface, width: 2),
                  ),
                  child: const Center(child: Glyph(G.close, size: 10, color: Neutral.surface, weight: 1.5)),
                ),
              ),
            ),
        ],
      ),
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
          curve: Motion.settle,
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
    child: Container(
      width: 6,
      height: 6,
      decoration: const BoxDecoration(color: Neutral.primary, shape: BoxShape.circle),
    ),
  );
}

/// A quiet text toggle under the photo; with [onHold], active while pressed.
/// A mark on the photo while asking: white keeps color, black takes it away,
/// a picked color shows itself.
class _MarkDot extends StatelessWidget {
  const _MarkDot(this.mark, this.n);
  final Mark mark;
  final int n;

  @override
  Widget build(BuildContext context) {
    final (fill, ink) = switch (mark.intent) {
      MarkIntent.keep => (Colors.white, Neutral.primary),
      MarkIntent.remove => (Neutral.primary, Colors.white),
      MarkIntent.picked => (mark.color == null ? Colors.white : colorOf(mark.color!), Colors.white),
    };
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.5),
        boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 4, offset: Offset(0, 1))],
      ),
      child: mark.intent == MarkIntent.picked
          ? null
          : Text(
              '$n',
              style: Txt.mono.copyWith(fontSize: 11, color: ink, fontWeight: FontWeight.w600, height: 1),
            ),
    );
  }
}

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
          curve: Motion.settle,
          style: Txt.small.copyWith(
            fontSize: 12.5,
            color: on ? Neutral.primary : Neutral.secondary,
            fontWeight: on ? FontWeight.w600 : FontWeight.w400,
          ),
          child: Text(label),
        ),
      ),
    );
  }
}

class _MiniToggle extends StatelessWidget {
  const _MiniToggle({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Motion.settle,
      width: 30,
      height: 18,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: on ? Neutral.primary : Neutral.hairline, borderRadius: BorderRadius.circular(9)),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 200),
        curve: Motion.settle,
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 14,
          height: 14,
          decoration: const BoxDecoration(color: Neutral.surface, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _AreaPainter extends CustomPainter {
  _AreaPainter(this.area, {this.tip, required this.radius, required this.erase});
  final Area? area;
  final Offset? tip;
  final double radius;
  final bool erase;

  @override
  void paint(Canvas canvas, Size s) {
    final line = Paint()
      ..color = const Color(0x99FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final shadow = Paint()
      ..color = const Color(0x33000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    void draw(Path p) {
      canvas.drawPath(p, shadow);
      canvas.drawPath(p, line);
    }

    // The shapes a tap made: with Erase, a tap inside one takes it away.
    for (final poly in area?.polygons ?? const <List<List<double>>>[]) {
      if (poly.length < 3) continue;
      final p = Path()..moveTo(poly[0][0] * s.width, poly[0][1] * s.height);
      for (final q in poly.skip(1)) {
        p.lineTo(q[0] * s.width, q[1] * s.height);
      }
      draw(p..close());
    }
    for (final e in area?.ellipses ?? const <List<double>>[]) {
      draw(
        Path()..addOval(
          Rect.fromCenter(
            center: Offset(e[0] * s.width, e[1] * s.height),
            width: e[2] * 2 * s.width,
            height: e[3] * 2 * s.height,
          ),
        ),
      );
    }
    final t = tip;
    if (t != null) {
      final c = Offset(t.dx * s.width, t.dy * s.height);
      canvas.drawCircle(c, radius, Paint()..color = erase ? const Color(0x33000000) : const Color(0x33FFFFFF));
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..color = const Color(0x66000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
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

/// Undo or Redo: a hairline hooked arrow, drawn to match the type's weight.
class _HistoryButton extends StatelessWidget {
  const _HistoryButton({required this.redo, this.onTap});
  final bool redo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: redo ? 'Redo' : 'Undo',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap == null
            ? null
            : () {
                Haptics.tick();
                onTap!();
              },
        child: SizedBox(
          width: 36,
          height: 44,
          child: CustomPaint(painter: _HookPainter(redo, onTap == null ? Neutral.tertiary : Neutral.primary)),
        ),
      ),
    );
  }
}

class _HookPainter extends CustomPainter {
  _HookPainter(this.redo, this.color);
  final bool redo;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    canvas.save();
    if (redo) {
      canvas.translate(s.width, 0);
      canvas.scale(-1, 1);
    }
    final c = s.center(Offset.zero);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // From the arrow tip at left, over and around to the right, back below.
    final tip = c + const Offset(-7, -3);
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(c.dx + 1.5, tip.dy)
      ..arcToPoint(Offset(c.dx + 1.5, c.dy + 7), radius: const Radius.circular(5))
      ..lineTo(c.dx - 3, c.dy + 7);
    canvas.drawPath(path, p);
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx + 3.5, tip.dy - 3.5)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(tip.dx + 3.5, tip.dy + 3.5),
      p,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HookPainter o) => o.color != color || o.redo != redo;
}

/// The middle of the vignette's falloff: a circle about the center, its
/// radius in half-diagonals as the renderer measures it.
class _VignetteRing extends CustomPainter {
  _VignetteRing(this.radius);
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = radius * math.sqrt(size.width * size.width + size.height * size.height) / 2;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = const Color(0x59000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = const Color(0xE6FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_VignetteRing old) => old.radius != radius;
}


class _AreaValueDialog extends StatefulWidget {
  const _AreaValueDialog({required this.value, required this.shortSide, required this.feather});
  final double value, shortSide;
  final bool feather;

  @override
  State<_AreaValueDialog> createState() => _AreaValueDialogState();
}

class _AreaValueDialogState extends State<_AreaValueDialog> {
  late final _controller = TextEditingController(text: widget.value.toStringAsFixed(1));
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoAlertDialog(
    title: Text(widget.feather ? 'Feather' : 'Boundary'),
    content: Column(children: [
      Text(widget.feather ? 'Fade width outside the full-opacity boundary, in original-photo pixels.'
          : '0 px keeps the drawn area fully opaque. Positive expands; negative contracts. Values use original-photo pixels.'),
      const SizedBox(height: 12),
      CupertinoTextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.numberWithOptions(signed: !widget.feather, decimal: true),
        suffix: const Padding(padding: EdgeInsets.only(right: 8), child: Text('px')),
      ),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!)),
    ]),
    actions: [
      CupertinoDialogAction(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      CupertinoDialogAction(onPressed: () => Navigator.pop(context, widget.feather ? Area.defaultFeatherPixels : 0.0), child: const Text('Reset')),
      CupertinoDialogAction(isDefaultAction: true, onPressed: () {
        final n = double.tryParse(_controller.text.trim());
        if (n == null || !n.isFinite || n < (widget.feather ? 0 : -widget.shortSide) || n > widget.shortSide) {
          setState(() => _error = 'Enter a value from ${widget.feather ? 0 : -widget.shortSide.round()} to ${widget.shortSide.round()} px.');
          return;
        }
        Navigator.pop(context, n);
      }, child: const Text('Apply')),
    ],
  );
}
