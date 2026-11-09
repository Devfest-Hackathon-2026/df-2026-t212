import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../data/store.dart';
import 'camera.dart';
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

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) Store.instance.scheduleSourceCheck();
  }
  int _tab = 0;
  bool _selecting = false;

  void _camera() {
    Haptics.light();
    Navigator.push(context, CameraRoute());
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
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _tab != 0,
              child: TickerMode(
                enabled: _tab == 0,
                child: AnimatedOpacity(
                  opacity: _tab == 0 ? 1 : 0,
                  duration: const Duration(milliseconds: 260),
                  curve: Motion.settle,
                  child: PhotosScreen(onSelectionChanged: (value) => setState(() => _selecting = value)),
                ),
              ),
            ),
          ),
          // MapLibre is a native view. Remove it from composition when hidden
          // so UIKit cannot leave its last frame over the Photos tab.
          Positioned.fill(
            child: Offstage(
              offstage: _tab != 1,
              // Fades in on arrival; leaves at once, while Photos fades in over it.
              child: TickerMode(
                enabled: _tab == 1,
                child: AnimatedOpacity(
                  opacity: _tab == 1 ? 1 : 0,
                  duration: Duration(milliseconds: _tab == 1 ? 260 : 0),
                  curve: Motion.settle,
                  child: const MapScreen(),
                ),
              ),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: Shell.barHidden,
            builder: (context, hidden, _) => AnimatedPositioned(
              duration: const Duration(milliseconds: 420),
              curve: hidden ? Curves.easeInCubic : Motion.settle,
              left: 20,
              right: 20,
              bottom: hidden || _selecting ? -100 : pad.bottom + 10,
              child: Row(
                children: [
                  Glass(
                    dock: true,
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
                    dock: true,
                    radius: 28,
                    child: Row(children: [
                      _RoundAction(onTap: () {
                        Haptics.light();
                        ImportSheet.show(context);
                      }, child: const Glyph(G.plus, size: 22, color: Neutral.primary)),
                      Container(width: 0.6, height: 22, color: const Color(0x1F000000)),
                      _RoundAction(onTap: _camera, child: const Glyph(G.camera, size: 26, color: Neutral.primary)),
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
      behavior: HitTestBehavior.opaque,
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
        curve: Motion.settle,
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

