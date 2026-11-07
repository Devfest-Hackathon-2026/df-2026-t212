import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/store.dart';
import 'import_sheet.dart';
import 'map_screen.dart';
import 'photos.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Photos and Map are two views of the same photos. The camera is an act,
/// not a place, so it sits apart as a round button.
class Shell extends StatefulWidget {
  const Shell({super.key});

  static final barHidden = ValueNotifier(false);

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  Future<void> _camera() async {
    Haptics.firm();
    try {
      final shot = await ImagePicker().pickImage(source: ImageSource.camera, requestFullMetadata: true);
      if (shot == null) return;
      // The original goes to the photo library; After Hue keeps only the edit.
      await PhotoManager.editor.saveImageWithPath(shot.path, title: shot.name);
      await Store.instance.refresh();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Neutral.primary,
          content: Text('Camera is not available on this device.', style: Txt.small.copyWith(color: Neutral.surface)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: Neutral.bg,
      body: Stack(
        children: [
          // A faint fall of light, so glass has something to sit on.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFF7F7F6), Color(0xFFF1F1EF), Color(0xFFE8E8E6)],
                  stops: [0, 0.55, 1],
                ),
              ),
            ),
          ),
          // Both screens stay alive; switching is a short cross-fade with a
          // touch of depth, not a cut.
          for (final (i, screen) in const [PhotosScreen(), MapScreen()].indexed)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: _tab != i,
                child: TickerMode(
                  enabled: _tab == i,
                  child: AnimatedOpacity(
                    opacity: _tab == i ? 1 : 0,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    child: AnimatedScale(
                      scale: _tab == i ? 1 : 0.985,
                      duration: const Duration(milliseconds: 360),
                      curve: Curves.easeOutCubic,
                      child: screen,
                    ),
                  ),
                ),
              ),
            ),
          ValueListenableBuilder<bool>(
            valueListenable: Shell.barHidden,
            builder: (context, hidden, _) => AnimatedPositioned(
              duration: const Duration(milliseconds: 420),
              curve: hidden ? Curves.easeInCubic : Curves.easeOutBack,
              left: 20,
              right: 20,
              bottom: hidden ? -100 : pad.bottom + 10,
              child: Row(
                children: [
                  Glass(
                    radius: 28,
                    padding: const EdgeInsets.all(5),
                    child: _TabSwitch(
                      labels: const ['Photos', 'Map'],
                      index: _tab,
                      onChanged: (i) => setState(() => _tab = i),
                    ),
                  ),
                  const Spacer(),
                  // Import and Camera bring photos in; they are acts, not places.
                  Glass(
                    radius: 28,
                    child: Row(children: [
                      _RoundAction(onTap: () {
                        Haptics.light();
                        ImportSheet.show(context);
                      }, child: const _PlusGlyph()),
                      Container(width: 0.6, height: 22, color: const Color(0x1F000000)),
                      _RoundAction(onTap: _camera, child: const _CameraGlyph()),
                    ]),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Two tabs and one black pill that travels between them on a spring. The
/// pill stretches a little in flight and the labels change color as it passes.
class _TabSwitch extends StatefulWidget {
  const _TabSwitch({required this.labels, required this.index, required this.onChanged});
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  State<_TabSwitch> createState() => _TabSwitchState();
}

class _TabSwitchState extends State<_TabSwitch> with SingleTickerProviderStateMixin {
  static const _widths = [94.0, 78.0];
  static const _h = 46.0;
  late final AnimationController _c = AnimationController.unbounded(vsync: this, value: widget.index.toDouble());
  bool _down = false;

  @override
  void didUpdateWidget(_TabSwitch old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      _c.animateWith(SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 420, damping: 30),
        _c.value,
        widget.index.toDouble(),
        _c.velocity,
      ));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _left(double t) {
    // Position of the pill for a fractional index (may overshoot a little).
    final i = t.floor().clamp(0, _widths.length - 2);
    final f = t - i;
    var x = 0.0;
    for (var k = 0; k < i; k++) {
      x += _widths[k];
    }
    return x + _widths[i] * f;
  }

  double _width(double t) {
    final i = t.floor().clamp(0, _widths.length - 2);
    final f = (t - i).clamp(0.0, 1.0);
    final base = _widths[i] + (_widths[i + 1] - _widths[i]) * f;
    return base + math.sin(f * math.pi) * 16; // stretch in flight
  }

  @override
  Widget build(BuildContext context) {
    final total = _widths.reduce((a, b) => a + b);
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (d) {
        setState(() => _down = false);
        var x = d.localPosition.dx, i = 0;
        while (i < _widths.length - 1 && x > _widths[i]) {
          x -= _widths[i];
          i++;
        }
        if (i != widget.index) {
          Haptics.tick();
          widget.onChanged(i);
        }
      },
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        child: SizedBox(
          width: total,
          height: _h,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = _c.value;
              final w = _width(t);
              // Stretch grows from the middle, so the pill stays centered on its path.
              final left = _left(t) - math.sin((t - t.floorToDouble()).clamp(0.0, 1.0) * math.pi) * 8;
              return Stack(
                children: [
                  Positioned(
                    left: left.clamp(-6.0, total - w + 6),
                    top: 0,
                    width: w,
                    height: _h,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Neutral.primary,
                        borderRadius: BorderRadius.circular(_h / 2),
                        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 3))],
                      ),
                    ),
                  ),
                  Row(children: [
                    for (var i = 0; i < widget.labels.length; i++)
                      SizedBox(
                        width: _widths[i],
                        height: _h,
                        child: Center(
                          child: Text(
                            widget.labels[i],
                            style: Txt.label.copyWith(
                              fontSize: 14.5,
                              color: Color.lerp(Neutral.surface, Neutral.secondary, (t - i).abs().clamp(0.0, 1.0)),
                            ),
                          ),
                        ),
                      ),
                  ]),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(width: 56, height: 56, child: Center(child: child)),
      );
}

class _PlusGlyph extends StatelessWidget {
  const _PlusGlyph();

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 20,
        height: 20,
        child: Stack(alignment: Alignment.center, children: [
          Container(width: 18, height: 1.6, decoration: BoxDecoration(color: Neutral.primary, borderRadius: BorderRadius.circular(1))),
          Container(width: 1.6, height: 18, decoration: BoxDecoration(color: Neutral.primary, borderRadius: BorderRadius.circular(1))),
        ]),
      );
}

class _CameraGlyph extends StatelessWidget {
  const _CameraGlyph();

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(24, 20), painter: _CameraPainter());
}

class _CameraPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Neutral.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeJoin = StrokeJoin.round;
    final w = size.width, h = size.height;
    // Body with the viewfinder hump, drawn as one outline.
    final body = Path()
      ..moveTo(3, 5)
      ..lineTo(7.5, 5)
      ..lineTo(9.2, 2.2)
      ..lineTo(w - 9.2, 2.2)
      ..lineTo(w - 7.5, 5)
      ..lineTo(w - 3, 5)
      ..arcToPoint(Offset(w - 1, 7), radius: const Radius.circular(2))
      ..lineTo(w - 1, h - 3)
      ..arcToPoint(Offset(w - 3, h - 1), radius: const Radius.circular(2))
      ..lineTo(3, h - 1)
      ..arcToPoint(Offset(1, h - 3), radius: const Radius.circular(2))
      ..lineTo(1, 7)
      ..arcToPoint(const Offset(3, 5), radius: const Radius.circular(2))
      ..close();
    canvas.drawPath(body, p);
    canvas.drawCircle(Offset(w / 2, (5 + h - 1) / 2 + 0.3), 4.2, p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
