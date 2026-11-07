import 'package:flutter/material.dart';

import '../data/photo_source.dart';
import '../data/store.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Three plain screens. Words say what happens; motion shows it.
class Onboarding extends StatefulWidget {
  const Onboarding({super.key});

  @override
  State<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends State<Onboarding> {
  final _page = PageController();
  int _index = 0;

  static const _samples = ['assets/samples/lantern.jpg', 'assets/samples/hydrangea.jpg', 'assets/samples/taxi.jpg'];

  void _next() => _page.nextPage(duration: const Duration(milliseconds: 520), curve: Curves.easeOutCubic);

  Future<void> _allow() async {
    final a = await Store.instance.requestAccess();
    if (a == Access.limited) await PhotoSource.presentLimitedPicker();
    _next();
  }

  Future<void> _choose() async {
    final a = await Store.instance.requestAccess();
    if (a == Access.full || a == Access.limited) await PhotoSource.presentLimitedPicker();
    _next();
  }

  Future<void> _changeRange() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Neutral.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => const RangeSheet(),
    );
    if (picked != null) setState(() => Store.instance.months = picked);
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return Scaffold(
      body: Stack(
        children: [
          PageView(
            controller: _page,
            physics: const NeverScrollableScrollPhysics(),
            onPageChanged: (i) => setState(() => _index = i),
            children: [
              _Page(
                image: _samples[0],
                text: 'After Hue finds the subject of each photo and keeps only its color. '
                    'Everything else turns black and white.',
                actions: [PrimaryButton('Continue', onTap: _next)],
              ),
              _Page(
                image: _samples[1],
                text: 'To do this automatically, After Hue needs access to your photos. '
                    'You can also choose specific photos instead.',
                actions: [
                  PrimaryButton('Allow Access', onTap: _allow),
                  const SizedBox(height: 10),
                  PrimaryButton('Choose Photos', onTap: _choose, secondary: true),
                ],
              ),
              _Page(
                image: _samples[2],
                text: 'Photos are resized and sent to an AI model for analysis. '
                    'Location and time stay on this device.',
                footer: GestureDetector(
                  onTap: _changeRange,
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: Store.instance.months >= 1200 ? 'All photos' : 'Last ${Store.instance.months} months'),
                      const TextSpan(text: '  ·  '),
                      TextSpan(text: 'Change', style: Txt.mono.copyWith(color: Neutral.primary, decoration: TextDecoration.underline)),
                    ]),
                    style: Txt.mono,
                  ),
                ),
                actions: [PrimaryButton('Start', onTap: () => Store.instance.finishOnboarding())],
              ),
            ],
          ),
          Positioned(
            top: pad.top + 18,
            left: 24,
            child: Row(
              children: [
                for (var i = 0; i < 3; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.only(right: 6),
                    width: i == _index ? 18 : 6,
                    height: 3,
                    decoration: BoxDecoration(
                      color: i <= _index ? Neutral.primary : Neutral.hairline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.image, required this.text, required this.actions, this.footer});
  final String image;
  final String text;
  final List<Widget> actions;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(24, pad.top + 48, 24, pad.bottom + 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: ColorReturnOnce(
                delay: const Duration(milliseconds: 700),
                duration: const Duration(milliseconds: 1800),
                child: Image.asset(image, fit: BoxFit.cover, width: double.infinity, height: double.infinity),
              ),
            ),
          ),
          const SizedBox(height: 28),
          Text(text, style: Txt.body.copyWith(fontSize: 19, height: 1.42, letterSpacing: -0.2)),
          if (footer != null) ...[const SizedBox(height: 14), footer!],
          const SizedBox(height: 28),
          ...actions,
        ],
      ),
    );
  }
}

/// How far back to look. Shared by onboarding and Settings.
class RangeSheet extends StatelessWidget {
  const RangeSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final options = {3: 'Last 3 months', 12: 'Last 12 months', 36: 'Last 3 years', 1200: 'All photos'};
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Photos to develop', style: Txt.title),
            const SizedBox(height: 6),
            Text('Newest photos come first, so a longer range does not slow down the first ones.', style: Txt.small),
            const SizedBox(height: 12),
            for (final e in options.entries)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  Haptics.tick();
                  Navigator.pop(context, e.key);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(children: [
                    Expanded(child: Text(e.value, style: Txt.label)),
                    if (Store.instance.months == e.key) Container(width: 6, height: 6, decoration: const BoxDecoration(color: Neutral.primary, shape: BoxShape.circle)),
                  ]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
