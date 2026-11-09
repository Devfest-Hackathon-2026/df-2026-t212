import 'package:flutter/material.dart';

import '../data/store.dart';
import 'onboarding.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/swatch_examples.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _demoTools = bool.fromEnvironment('AFTER_HUE_DEMO_TOOLS');
  final s = Store.instance;
  bool _resetting = false;
  late final Future<String> _judge = s.judgeName();

  Future<void> _resetForDemo() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset After Hue?'),
        content: const Text(
          'This clears edits, favorites, and settings and returns to onboarding. '
          'Your photo library and system permissions stay as they are.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Reset')),
        ],
      ),
    );
    if (confirmed != true || !mounted || _resetting) return;
    setState(() => _resetting = true);
    try {
      await s.resetForDemo();
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (_) {
      if (!mounted) return;
      setState(() => _resetting = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not reset After Hue.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, pad.top + 4, 20, pad.bottom + 40),
        children: [
          Row(children: [
            Transform.translate(offset: const Offset(-10, 0), child: TextAction('Back', color: Neutral.secondary, onTap: () => Navigator.pop(context))),
          ]),
          const SizedBox(height: 4),
          Text('Settings', style: Txt.display),
          const SizedBox(height: 28),
          _section('Gallery'),
          _switch('Group by month', s.groupByMonth, (v) => setState(() => s.setGroupByMonth(v))),
          _switch('Group similar photos', s.groupSimilarPhotos, (v) => setState(() => s.setGroupSimilarPhotos(v))),
          Padding(padding: const EdgeInsets.only(top: 6, bottom: 8), child: Text(
            'Group similar shots taken moments apart. Originals and edits stay separate.', style: Txt.small)),
          _row('Swatches', switch (s.swatches) { SwatchStyle.photo => 'From the photo', SwatchStyle.soft => 'Soft', SwatchStyle.flat => 'Flat' }, () {
            Haptics.tick();
            setState(() => s.setSwatches(SwatchStyle.values[(s.swatches.index + 1) % SwatchStyle.values.length]));
          }, preview: SwatchExamples(style: s.swatches)),
          const SizedBox(height: 36),
          _section('Developing'),
          _switch('Develop new photos automatically', s.autoDevelop, (v) => setState(() => s.setAutoDevelop(v))),
          _row('Photos to show', s.months >= 1200 ? 'All photos' : 'Last ${s.months} months', () async {
            final m = await showModalBottomSheet<int>(
              context: context,
              backgroundColor: Neutral.surface,
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
              builder: (_) => const RangeSheet(),
            );
            if (m != null) setState(() => s.setMonths(m));
          }),
          _switch('Skip screenshots', s.skipScreenshots, (v) => setState(() => s.setSkipScreenshots(v))),
          _row('Developed today', '${s.developedToday} of ${Store.dailyLimit}', null),
          _row('Model', s.agent.name, null),
          FutureBuilder<String>(
            future: _judge,
            builder: (_, snap) => _row('Screening', snap.data ?? '…', null),
          ),
          const SizedBox(height: 36),
          _section('Account'),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: Neutral.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: Neutral.hairline)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('After Hue account', style: Txt.label),
                const Spacer(),
                Text('Coming soon', style: Txt.mono),
              ]),
              const SizedBox(height: 14),
              for (final t in const ['Sync across your devices', 'Cloud backup of your photos and edits', 'More AI edits each month'])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Container(width: 4, height: 4, decoration: const BoxDecoration(color: Neutral.secondary, shape: BoxShape.circle)),
                    const SizedBox(width: 10),
                    Text(t, style: Txt.small.copyWith(color: Neutral.primary)),
                  ]),
                ),
            ]),
          ),
          const SizedBox(height: 36),
          _section('About'),
          _row('Version', '0.1.0', null),
          _row('Photos developed', '${s.doneCount}', null),
          _row('Agent log', '${s.agentLog.length}', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const _AgentLog()))),
          if (_demoTools) ...[
            const SizedBox(height: 36),
            _section('Development'),
            _row('Reset for demo', _resetting ? 'Resetting…' : 'Reset', _resetting ? null : _resetForDemo),
          ],
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(t.toUpperCase(), style: Txt.mono.copyWith(letterSpacing: 1.2)));

  Widget _switch(String label, bool v, ValueChanged<bool> on) => Container(
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Neutral.hairline, width: 0.6))),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(child: Text(label, style: Txt.label.copyWith(fontWeight: FontWeight.w400))),
          Switch.adaptive(value: v, onChanged: (x) {
            Haptics.tick();
            on(x);
          }),
        ]),
      );

  Widget _row(String label, String value, VoidCallback? onTap, {Widget? preview}) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Neutral.hairline, width: 0.6))),
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(label, style: Txt.label.copyWith(fontWeight: FontWeight.w400))),
              Text(value, style: Txt.small),
            ]),
            if (preview != null) ...[const SizedBox(height: 10), preview],
          ]),
        ),
      );
}

/// What the agent did, newest first: which photos it judged, skipped, or developed.
class _AgentLog extends StatelessWidget {
  const _AgentLog();

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final lines = Store.instance.agentLog.reversed.toList();
    return Scaffold(
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(10, pad.top + 4, 20, 8),
          child: TextAction('Back', color: Neutral.secondary, onTap: () => Navigator.pop(context)),
        ),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.fromLTRB(20, 0, 20, pad.bottom + 20),
            itemCount: lines.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(lines[i], style: Txt.mono.copyWith(fontSize: 11, color: Neutral.primary)),
            ),
          ),
        ),
      ]),
    );
  }
}
