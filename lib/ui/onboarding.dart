import 'package:flutter/material.dart';

import '../l10n/strings.dart';
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

  void _next() => _page.nextPage(duration: const Duration(milliseconds: 520), curve: Motion.settle);

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
                text: context.tr('After Hue finds the subject of each photo and keeps only its color. Everything else turns black and white.', 'After Hue は写真の被写体を見つけ、その色だけを残します。ほかの部分はモノクロになります。'),
                actions: [PrimaryButton(context.tr('Continue', '続ける'), onTap: _next)],
              ),
              _Page(
                image: _samples[1],
                text: context.tr('To do this automatically, After Hue needs access to your photos. You can also choose specific photos instead.', '自動で現像するには、写真へのアクセスが必要です。写真を選んで取り込むこともできます。'),
                actions: [
                  PrimaryButton(context.tr('Allow Access', 'アクセスを許可'), onTap: _allow),
                  const SizedBox(height: 10),
                  PrimaryButton(context.tr('Choose Photos', '写真を選ぶ'), onTap: _choose, secondary: true),
                ],
              ),
              _Page(
                image: _samples[2],
                text: context.tr('Photos are resized and sent to an AI model for analysis. Location and time stay on this device.', '写真は縮小して AI モデルに送信し、解析します。撮影場所と日時はこの端末内に残ります。'),
                footer: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  GestureDetector(
                    onTap: _changeRange,
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(text: Store.instance.months >= 1200 ? context.tr('All photos', 'すべての写真') : context.tr('Last ${Store.instance.months} months', '過去${Store.instance.months}か月')),
                        const TextSpan(text: '  ·  '),
                        TextSpan(text: context.tr('Change', '変更'), style: Txt.mono.copyWith(color: Neutral.primary, decoration: TextDecoration.underline)),
                      ]),
                      style: Txt.mono,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _Check(
                    label: context.tr('Develop automatically', '自動で現像'),
                    hint: context.tr('Newest ${Store.firstBatch}, then new photos. Up to ${Store.dailyLimit} a day.', '最新の${Store.firstBatch}枚と、その後の新しい写真を現像します。1日最大${Store.dailyLimit}枚。'),
                    value: Store.instance.autoDevelop,
                    onChanged: (v) => setState(() => Store.instance.autoDevelop = v),
                  ),
                  _Check(
                    label: context.tr('Skip screenshots', 'スクリーンショットを除く'),
                    value: Store.instance.skipScreenshots,
                    onChanged: (v) => setState(() => Store.instance.skipScreenshots = v),
                  ),
                ]),
                actions: [PrimaryButton(context.tr('Start', 'はじめる'), onTap: () => Store.instance.finishOnboarding())],
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
                    curve: Motion.settle,
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
    final options = {3: context.tr('Last 3 months', '過去3か月'), 12: context.tr('Last 12 months', '過去12か月'), 36: context.tr('Last 3 years', '過去3年'), 1200: context.tr('All photos', 'すべての写真')};
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.tr('Photos to show', '表示する写真'), style: Txt.title),
            const SizedBox(height: 6),
            Text(context.tr('Newest photos come first, so a longer range does not slow down the first ones.', '新しい写真から順に表示します。対象期間を長くしても、最初の表示は遅くなりません。'), style: Txt.small),
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

/// A compact labelled switch for the last onboarding page.
class _Check extends StatelessWidget {
  const _Check({required this.label, required this.value, required this.onChanged, this.hint});
  final String label;
  final String? hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Txt.small.copyWith(color: Neutral.primary, fontSize: 14)),
          if (hint != null) Text(hint!, style: Txt.mono.copyWith(fontSize: 10.5)),
        ]),
      ),
      Transform.scale(
        scale: 0.8,
        alignment: Alignment.centerRight,
        child: Switch.adaptive(
          value: value,
          onChanged: (v) {
            Haptics.tick();
            onChanged(v);
          },
        ),
      ),
    ]);
  }
}
